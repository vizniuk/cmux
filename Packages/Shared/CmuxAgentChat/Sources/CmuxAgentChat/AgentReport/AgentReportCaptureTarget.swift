import Foundation

/// App-authoritative identity snapshot for one exact accessible agent surface.
///
/// The app constructs this value from current topology plus the hook lifecycle
/// store. Its opaque process-local lifecycle token is synchronously replaced on
/// prompt, close, resume, or rebind. Capture re-resolves and compares that token
/// after transcript I/O, so queued actor cleanup is not the commit authority.
public struct AgentReportCaptureTarget: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Current process-local workspace containing the surface.
    public let workspaceID: UUID

    /// Current process-local surface identifier.
    public let runtimeSurfaceID: UUID

    /// Restart-stable identifier carried by the live panel.
    public let stableSurfaceID: UUID?

    /// Provider session currently bound to the surface.
    public let agentSessionID: String

    /// Authoritative latest accepted turn from the provider hook store.
    public let turnID: String

    /// Opaque process-local lifecycle authority for this exact surface binding.
    public let lifecycleToken: UUID

    /// Optional hook-recorded transcript lookup hint.
    ///
    /// This value has no read or report authority. It may be absent, stale, or
    /// rejected by the resolver before exact-session fallback succeeds.
    public let recordedTranscriptPathHint: String?

    /// Opaque process-local identity of the exact active hook-entry snapshot.
    public let authorityRevision: UUID

    /// A content-free diagnostic description that omits all private metadata.
    public var description: String {
        "AgentReportCaptureTarget"
    }

    /// A content-free diagnostic description.
    public var debugDescription: String { description }

    /// Creates an app-authoritative capture target.
    ///
    /// - Parameters:
    ///   - workspaceID: Current process-local workspace identity.
    ///   - runtimeSurfaceID: Current process-local terminal surface identity.
    ///   - stableSurfaceID: Restart-stable panel identity, when available.
    ///   - agentSessionID: Provider session currently bound to the surface.
    ///   - turnID: Latest primary turn authorized by the hook lifecycle store.
    ///   - lifecycleToken: Current process-local surface lifecycle authority.
    ///   - recordedTranscriptPathHint: Optional hook-recorded lookup hint.
    ///   - authorityRevision: Exact active hook-entry mutation identity.
    public init(
        workspaceID: UUID,
        runtimeSurfaceID: UUID,
        stableSurfaceID: UUID?,
        agentSessionID: String,
        turnID: String,
        lifecycleToken: UUID,
        recordedTranscriptPathHint: String?,
        authorityRevision: UUID
    ) {
        self.workspaceID = workspaceID
        self.runtimeSurfaceID = runtimeSurfaceID
        self.stableSurfaceID = stableSurfaceID
        self.agentSessionID = agentSessionID
        self.turnID = turnID
        self.lifecycleToken = lifecycleToken
        self.recordedTranscriptPathHint = recordedTranscriptPathHint
        self.authorityRevision = authorityRevision
    }
}
