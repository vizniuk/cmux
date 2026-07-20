import Foundation

/// Concurrency-safe, process-local storage for the latest exact report per
/// live runtime surface.
///
/// The actor owns both enablement and retention so disabling is an atomic
/// purge. It serializes validation, receipt ordering, and commit so duplicate
/// or late completions cannot race. Transcript recovery may suspend for
/// off-main file I/O; policy, actor-owned cleanup generations, and an
/// app-authoritative opaque lifecycle token force fresh validation after that
/// suspension. It performs no persistence. Its observation surface exposes
/// content-free topology availability only.
///
/// Exact reply text exists only in this actor's process memory. It must never
/// be forwarded to Feed, notifications, logs, analytics, crash reporting,
/// filenames, temporary files, or persistent hook/session stores.
public actor AgentReportCaptureStore {
    private var policy: AgentReportCapturePolicy
    private var latestByRuntimeSurfaceID: [UUID: AgentReport] = [:]
    private var latestReceiptOrdinalByRuntimeSurfaceID: [UUID: UInt64] = [:]
    private var lifecycleGenerationByRuntimeSurfaceID: [UUID: UInt64] = [:]
    private var capturedLifecycleGenerationByRuntimeSurfaceID: [UUID: UInt64] = [:]
    private var availabilityContinuations: [
        UUID: AsyncStream<AgentReportAvailabilitySnapshot>.Continuation
    ] = [:]
    private var policyGeneration: UInt64 = 0
    private var nextReceiptOrdinal: UInt64 = 0
    private let transcriptRecovery: any AgentReportTranscriptRecovering
    private let now: @Sendable () -> Date

    /// Creates an in-memory report store.
    ///
    /// - Parameters:
    ///   - policy: Initial policy. Defaults to disabled.
    ///   - transcriptRecovery: Exact structured-transcript recovery service.
    ///   - now: Injectable capture clock.
    public init(
        policy: AgentReportCapturePolicy = .disabled,
        transcriptRecovery: any AgentReportTranscriptRecovering,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.policy = policy
        self.transcriptRecovery = transcriptRecovery
        self.now = now
    }

    /// Whether capture is currently enabled.
    public var isCaptureEnabled: Bool { policy.isEnabled }

    /// Applies a new policy and enforces default-off retention semantics.
    ///
    /// Disabling atomically invalidates in-flight work and immediately clears
    /// every feature-owned report. Reapplying the disabled policy also purges
    /// state so callers cannot accidentally leave retained content hidden.
    ///
    /// - Parameter newPolicy: Replacement process-local capture policy.
    public func setPolicy(_ newPolicy: AgentReportCapturePolicy) {
        guard policy != newPolicy else {
            if !newPolicy.isEnabled {
                latestByRuntimeSurfaceID.removeAll(keepingCapacity: false)
                latestReceiptOrdinalByRuntimeSurfaceID.removeAll(keepingCapacity: false)
                lifecycleGenerationByRuntimeSurfaceID.removeAll(keepingCapacity: false)
                capturedLifecycleGenerationByRuntimeSurfaceID.removeAll(keepingCapacity: false)
            }
            publishAvailability()
            return
        }
        policy = newPolicy
        policyGeneration &+= 1
        if !newPolicy.isEnabled {
            latestByRuntimeSurfaceID.removeAll(keepingCapacity: false)
            latestReceiptOrdinalByRuntimeSurfaceID.removeAll(keepingCapacity: false)
            lifecycleGenerationByRuntimeSurfaceID.removeAll(keepingCapacity: false)
            capturedLifecycleGenerationByRuntimeSurfaceID.removeAll(keepingCapacity: false)
        }
        publishAvailability()
    }

    /// Returns the current report for one exact live runtime surface.
    ///
    /// - Parameter runtimeSurfaceID: Exact process-local surface identifier.
    /// - Returns: Latest committed report for that exact surface, or `nil`.
    public func latestReport(runtimeSurfaceID: UUID) -> AgentReport? {
        latestByRuntimeSurfaceID[runtimeSurfaceID]
    }

    /// Returns an exact report body only after fresh caller-supplied authority.
    ///
    /// This is the sole report-body reveal seam. It never performs transcript
    /// recovery or terminal/scrollback reads. Policy, lifecycle generation, and
    /// actor-owned latest identity are rechecked after authorization suspends so
    /// disable, purge, rebind, replacement, or prompt invalidation fails closed.
    ///
    /// - Parameters:
    ///   - runtimeSurfaceID: Exact process-local surface requested by the user.
    ///   - authorize: Fresh app authority check using body-free metadata.
    /// - Returns: The unmodified body, or `nil` when unavailable or unauthorized.
    public func authorizedReportBody(
        runtimeSurfaceID: UUID,
        authorize: @escaping @Sendable (AgentReportCopyAuthorizationContext) async -> Bool
    ) async -> String? {
        guard policy.isEnabled,
              let report = latestByRuntimeSurfaceID[runtimeSurfaceID],
              capturedLifecycleGenerationByRuntimeSurfaceID[runtimeSurfaceID]
                == lifecycleGenerationByRuntimeSurfaceID[runtimeSurfaceID, default: 0],
              await authorize(AgentReportCopyAuthorizationContext(report: report)),
              policy.isEnabled,
              latestByRuntimeSurfaceID[runtimeSurfaceID] == report,
              capturedLifecycleGenerationByRuntimeSurfaceID[runtimeSurfaceID]
                == lifecycleGenerationByRuntimeSurfaceID[runtimeSurfaceID, default: 0] else {
            return nil
        }
        return report.finalReply
    }

    /// Observes content-free report availability without polling.
    ///
    /// Each subscriber immediately receives the current snapshot. Later
    /// capture, replacement, lifecycle invalidation, purge, and policy changes
    /// yield new snapshots. No report-derived text or provider metadata is
    /// included.
    ///
    /// - Returns: A newest-value stream of content-free availability.
    public func availabilitySnapshots() -> AsyncStream<AgentReportAvailabilitySnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AgentReportAvailabilitySnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        availabilityContinuations[id] = continuation
        continuation.yield(availabilitySnapshot())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeAvailabilityContinuation(id: id) }
        }
        return stream
    }

    /// Purges report state owned by a closed or replaced runtime surface.
    ///
    /// - Parameter runtimeSurfaceID: Exact process-local surface identifier.
    public func purge(runtimeSurfaceID: UUID) {
        invalidatePendingCapture(runtimeSurfaceID: runtimeSurfaceID)
        latestByRuntimeSurfaceID.removeValue(forKey: runtimeSurfaceID)
        latestReceiptOrdinalByRuntimeSurfaceID.removeValue(forKey: runtimeSurfaceID)
        capturedLifecycleGenerationByRuntimeSurfaceID.removeValue(forKey: runtimeSurfaceID)
        publishAvailability()
    }

    /// Invalidates capture work already in flight for a surface while keeping
    /// its last completed report. Prompt and resume lifecycle changes use this
    /// seam; only actual surface closure purges completed state.
    ///
    /// - Parameter runtimeSurfaceID: Surface whose in-flight generation changes.
    public func invalidatePendingCapture(runtimeSurfaceID: UUID) {
        lifecycleGenerationByRuntimeSurfaceID[runtimeSurfaceID, default: 0] &+= 1
        publishAvailability()
    }

    /// Validates and captures one exact final report.
    ///
    /// Transcript recovery is entered only after the enabled policy and exact
    /// target tuple pass. Policy and actor generations provide atomic cleanup;
    /// the synchronously advanced target lifecycle token is the correctness
    /// barrier for prompt, close, resume, and rebind ordering. A production
    /// caller supplies `revalidateTarget` so topology, hook-store identity, and
    /// that token are proven again immediately before commit.
    ///
    /// - Parameters:
    ///   - request: Private capture request from the accepted hook boundary.
    ///   - target: App-authoritative live target, or `nil` when inaccessible.
    ///   - revalidateTarget: Fresh authoritative target resolver required of
    ///     every caller outside this package.
    /// - Returns: A content-free capture result.
    public func capture(
        _ request: AgentReportCaptureRequest,
        target: AgentReportCaptureTarget?,
        revalidateTarget: @escaping @Sendable () async -> AgentReportCaptureTarget?
    ) async -> AgentReportCaptureResult {
        guard policy.isEnabled else { return .disabled }
        guard request.provider == .codex, request.completionKind == .primaryStop else {
            return .rejected(.unsupportedCompletion)
        }
        guard let target else { return .rejected(.inaccessibleSurface) }
        guard Self.identitiesMatch(request: request, target: target) else {
            return .rejected(.identityMismatch)
        }
        if let rawFinalReply = request.rawFinalReply,
           !AgentReportResourceLimits.sliceA.permitsReportBody(rawFinalReply) {
            return .rejected(.exactReplyUnavailable)
        }

        let identity = request.duplicateIdentity
        if let existing = latestByRuntimeSurfaceID[request.runtimeSurfaceID] {
            if existing.duplicateIdentity == identity {
                return .duplicate
            }
        }

        nextReceiptOrdinal &+= 1
        let receiptOrdinal = nextReceiptOrdinal
        let generation = policyGeneration
        let lifecycleGeneration = lifecycleGenerationByRuntimeSurfaceID[request.runtimeSurfaceID, default: 0]
        let exactReply: String
        let source: AgentReportCaptureSource
        if let raw = Self.usableExactReply(request.rawFinalReply) {
            // Raw Stop text is already exact, but session metadata is still
            // required to prove this is the primary rollout rather than a
            // sidechain or managed subagent completion.
            guard await transcriptRecovery.isPrimaryCodexSession(
                recordedPath: target.transcriptPath,
                sessionID: request.agentSessionID
            ) else {
                return .rejected(.nonPrimarySession)
            }
            exactReply = raw
            source = .rawHook
        } else {
            // Recovery is the only fallback in Slice A. It remains tied to the
            // exact session and turn; terminal/scrollback guessing is forbidden.
            guard let recovered = await transcriptRecovery.recoverCodexFinalReply(
                recordedPath: target.transcriptPath,
                sessionID: request.agentSessionID,
                turnID: request.turnID
            ) else {
                return .rejected(.exactReplyUnavailable)
            }
            guard AgentReportResourceLimits.sliceA.permitsReportBody(recovered) else {
                return .rejected(.exactReplyUnavailable)
            }
            guard let usable = Self.usableExactReply(recovered) else {
                return .rejected(.exactReplyUnavailable)
            }
            exactReply = usable
            source = .structuredTranscript
        }

        // Recovery suspends actor execution. Recheck both policy and lifecycle
        // before and after fresh topology resolution so disable, close, prompt,
        // resume, or rebind cannot commit stale private content.
        guard policy.isEnabled, generation == policyGeneration else { return .disabled }
        guard lifecycleGeneration
                == lifecycleGenerationByRuntimeSurfaceID[request.runtimeSurfaceID, default: 0] else {
            return .rejected(.inaccessibleSurface)
        }
        guard let currentTarget = await revalidateTarget() else {
            return .rejected(.inaccessibleSurface)
        }
        guard policy.isEnabled, generation == policyGeneration else { return .disabled }
        guard lifecycleGeneration
                == lifecycleGenerationByRuntimeSurfaceID[request.runtimeSurfaceID, default: 0] else {
            return .rejected(.inaccessibleSurface)
        }
        guard Self.identitiesMatch(request: request, target: currentTarget) else {
            return .rejected(.identityMismatch)
        }
        guard currentTarget.lifecycleToken == target.lifecycleToken else {
            return .rejected(.inaccessibleSurface)
        }
        if let existing = latestByRuntimeSurfaceID[request.runtimeSurfaceID] {
            if existing.duplicateIdentity == identity {
                return .duplicate
            }
        }
        if let latestReceiptOrdinal = latestReceiptOrdinalByRuntimeSurfaceID[request.runtimeSurfaceID],
           receiptOrdinal <= latestReceiptOrdinal {
            return .rejected(.staleCompletion)
        }
        guard AgentReportResourceLimits.sliceA.permitsReportBody(exactReply) else {
            return .rejected(.exactReplyUnavailable)
        }

        latestByRuntimeSurfaceID[request.runtimeSurfaceID] = AgentReport(
            provider: request.provider,
            runtimeSurfaceID: request.runtimeSurfaceID,
            stableSurfaceID: currentTarget.stableSurfaceID,
            workspaceID: request.workspaceID,
            agentSessionID: request.agentSessionID,
            turnID: request.turnID,
            completionKind: request.completionKind,
            lifecycleToken: currentTarget.lifecycleToken,
            finalReply: exactReply,
            captureSource: source,
            capturedAt: now(),
            promptTimestamp: request.promptTimestamp,
            completionTimestamp: request.completionTimestamp,
            duplicateIdentity: identity
        )
        latestReceiptOrdinalByRuntimeSurfaceID[request.runtimeSurfaceID] = receiptOrdinal
        capturedLifecycleGenerationByRuntimeSurfaceID[request.runtimeSurfaceID] = lifecycleGeneration
        publishAvailability()
        return .captured
    }

    /// Fixed-target convenience for package-internal tests that do not model
    /// live app topology. Production callers outside this package must supply
    /// the required authoritative revalidator above.
    ///
    /// - Parameters:
    ///   - request: Synthetic private capture request.
    ///   - target: Fixed synthetic topology snapshot.
    /// - Returns: A content-free capture result.
    func capture(
        _ request: AgentReportCaptureRequest,
        target: AgentReportCaptureTarget?
    ) async -> AgentReportCaptureResult {
        await capture(request, target: target, revalidateTarget: { target })
    }

    /// Compares every identity component required for cross-surface isolation.
    ///
    /// - Parameters:
    ///   - request: Untrusted socket-derived identity tuple.
    ///   - target: App-authoritative current identity tuple.
    /// - Returns: `true` only when workspace, surface, session, and turn match.
    private static func identitiesMatch(
        request: AgentReportCaptureRequest,
        target: AgentReportCaptureTarget
    ) -> Bool {
        request.workspaceID == target.workspaceID
            && request.runtimeSurfaceID == target.runtimeSurfaceID
            && request.agentSessionID == target.agentSessionID
            && request.turnID == target.turnID
    }

    /// Rejects missing or whitespace-only output without altering usable text.
    ///
    /// The trimming operation is validation-only; the original string is
    /// returned so meaningful leading/trailing whitespace remains exact.
    ///
    /// - Parameter value: Candidate exact reply.
    /// - Returns: Original string when usable, otherwise `nil`.
    private static func usableExactReply(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    /// Builds the narrow content-free projection used by visible controls.
    private func availabilitySnapshot() -> AgentReportAvailabilitySnapshot {
        guard policy.isEnabled else {
            return AgentReportAvailabilitySnapshot(
                isCaptureEnabled: false,
                workspaceIDByRuntimeSurfaceID: [:]
            )
        }
        let available = latestByRuntimeSurfaceID.reduce(into: [UUID: UUID]()) { result, element in
            let (surfaceID, report) = element
            guard capturedLifecycleGenerationByRuntimeSurfaceID[surfaceID]
                    == lifecycleGenerationByRuntimeSurfaceID[surfaceID, default: 0] else {
                return
            }
            result[surfaceID] = report.workspaceID
        }
        return AgentReportAvailabilitySnapshot(
            isCaptureEnabled: true,
            workspaceIDByRuntimeSurfaceID: available
        )
    }

    /// Publishes a content-free newest-value snapshot to every subscriber.
    private func publishAvailability() {
        let snapshot = availabilitySnapshot()
        for continuation in availabilityContinuations.values {
            continuation.yield(snapshot)
        }
    }

    /// Removes a terminated availability subscriber.
    private func removeAvailabilityContinuation(id: UUID) {
        availabilityContinuations.removeValue(forKey: id)
    }
}
