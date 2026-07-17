import Foundation

/// The exact latest final reply captured for one live cmux terminal surface.
///
/// This process-local value is owned by ``AgentReportCaptureStore`` and is
/// discarded on surface closure, capture disablement, or process exit. Its
/// ``finalReply`` is private content: callers must never send it through Feed,
/// notifications, logs, analytics, crash reporting, filenames, temporary
/// files, or persistent hook/session stores.
public struct AgentReport: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The agent runtime that produced the report.
    public let provider: AgentReportProvider

    /// The current process-local cmux surface identifier used for lookup.
    public let runtimeSurfaceID: UUID

    /// The restart-stable surface identifier available from the live panel.
    public let stableSurfaceID: UUID?

    /// The current process-local workspace containing the surface.
    public let workspaceID: UUID

    /// The provider-owned session identifier.
    public let agentSessionID: String

    /// The provider-owned turn or run identifier.
    public let turnID: String

    /// The accepted completion boundary.
    public let completionKind: AgentReportCompletionKind

    /// Exact final reply text. This value is never suitable for diagnostics.
    public let finalReply: String

    /// The authoritative source used to obtain ``finalReply``.
    public let captureSource: AgentReportCaptureSource

    /// When cmux committed the report to its process-local store.
    public let capturedAt: Date

    /// Provider prompt time when authoritatively supplied; otherwise `nil`.
    public let promptTimestamp: Date?

    /// When the accepted completion reached the cmux hook boundary.
    public let completionTimestamp: Date

    /// Content-free identity used for idempotent delivery.
    public let duplicateIdentity: AgentReportDuplicateIdentity

    /// A content-free diagnostic description.
    public var description: String {
        "AgentReport(provider: \(provider.rawValue), "
            + "source: \(captureSource.rawValue), completion: \(completionKind.rawValue))"
    }

    /// A content-free diagnostic description.
    public var debugDescription: String { description }

    /// Creates an exact agent report record after identity and lifecycle validation.
    ///
    /// - Parameters:
    ///   - provider: Agent runtime that produced the completion.
    ///   - runtimeSurfaceID: Exact live process-local surface used for lookup.
    ///   - stableSurfaceID: Authoritative restart-stable surface identity, when available.
    ///   - workspaceID: Exact live workspace containing the surface.
    ///   - agentSessionID: Provider-owned session identity.
    ///   - turnID: Provider-owned completed turn identity.
    ///   - completionKind: Accepted provider lifecycle boundary.
    ///   - finalReply: Unmodified private final reply text.
    ///   - captureSource: Authoritative source of `finalReply`.
    ///   - capturedAt: Time the actor committed the record.
    ///   - promptTimestamp: Authoritative provider prompt time, when available.
    ///   - completionTimestamp: Time the accepted completion reached cmux.
    ///   - duplicateIdentity: Content-free idempotency identity.
    public init(
        provider: AgentReportProvider,
        runtimeSurfaceID: UUID,
        stableSurfaceID: UUID?,
        workspaceID: UUID,
        agentSessionID: String,
        turnID: String,
        completionKind: AgentReportCompletionKind,
        finalReply: String,
        captureSource: AgentReportCaptureSource,
        capturedAt: Date,
        promptTimestamp: Date?,
        completionTimestamp: Date,
        duplicateIdentity: AgentReportDuplicateIdentity
    ) {
        self.provider = provider
        self.runtimeSurfaceID = runtimeSurfaceID
        self.stableSurfaceID = stableSurfaceID
        self.workspaceID = workspaceID
        self.agentSessionID = agentSessionID
        self.turnID = turnID
        self.completionKind = completionKind
        self.finalReply = finalReply
        self.captureSource = captureSource
        self.capturedAt = capturedAt
        self.promptTimestamp = promptTimestamp
        self.completionTimestamp = completionTimestamp
        self.duplicateIdentity = duplicateIdentity
    }
}
