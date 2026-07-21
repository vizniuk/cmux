import Foundation

/// Body-free identity atomically shared by a retained report and its authority.
///
/// The capture actor creates this value only after selecting a winning commit
/// candidate. It contains no report body, transcript path, or diagnostic-safe
/// opaque identifier representation.
public struct AgentReportResolvedAuthorityCommit: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    /// Actor-issued monotonic ordering identity for the capture attempt.
    public let captureAttemptToken: AgentReportCaptureAttemptToken

    /// Opaque identity of the exact report associated with this authority.
    public let reportIdentity: UUID

    /// Agent runtime that produced the report.
    public let provider: AgentReportProvider

    /// Immutable workspace recorded at capture.
    public let captureWorkspaceID: UUID

    /// Exact process-local runtime surface.
    public let runtimeSurfaceID: UUID

    /// Capture-time restart-stable surface identity, when available.
    public let stableSurfaceID: UUID?

    /// Provider-owned session represented by the capture.
    public let agentSessionID: String

    /// Provider-owned turn represented by the capture.
    public let turnID: String

    /// Accepted provider completion boundary.
    public let completionKind: AgentReportCompletionKind

    /// Capture-time process-local lifecycle authority.
    public let lifecycleToken: UUID

    /// Resolver-proven transcript identity for the exact captured report.
    public let transcriptBinding: AgentReportTranscriptBinding

    /// Exact active hook-entry revision proven for the capture.
    public let authorityRevision: UUID

    /// A diagnostic description containing no authority identities or ordering.
    public var description: String { "AgentReportResolvedAuthorityCommit" }

    /// A diagnostic description containing no authority identities or ordering.
    public var debugDescription: String { description }

    /// Creates a body-free candidate for winner-ordered authority publication.
    ///
    /// - Parameters:
    ///   - captureAttemptToken: Actor-issued monotonic capture ordering token.
    ///   - reportIdentity: Opaque identity of the exact associated report.
    ///   - provider: Agent runtime that produced the report.
    ///   - captureWorkspaceID: Immutable workspace recorded at capture.
    ///   - runtimeSurfaceID: Exact process-local runtime surface.
    ///   - stableSurfaceID: Restart-stable surface identity, when available.
    ///   - agentSessionID: Provider-owned session identity.
    ///   - turnID: Provider-owned completed turn identity.
    ///   - completionKind: Accepted provider lifecycle boundary.
    ///   - lifecycleToken: Capture-time process-local lifecycle authority.
    ///   - transcriptBinding: Resolver-proven transcript identity.
    ///   - authorityRevision: Exact active hook-entry revision.
    public init(
        captureAttemptToken: AgentReportCaptureAttemptToken,
        reportIdentity: UUID,
        provider: AgentReportProvider,
        captureWorkspaceID: UUID,
        runtimeSurfaceID: UUID,
        stableSurfaceID: UUID?,
        agentSessionID: String,
        turnID: String,
        completionKind: AgentReportCompletionKind,
        lifecycleToken: UUID,
        transcriptBinding: AgentReportTranscriptBinding,
        authorityRevision: UUID
    ) {
        self.captureAttemptToken = captureAttemptToken
        self.reportIdentity = reportIdentity
        self.provider = provider
        self.captureWorkspaceID = captureWorkspaceID
        self.runtimeSurfaceID = runtimeSurfaceID
        self.stableSurfaceID = stableSurfaceID
        self.agentSessionID = agentSessionID
        self.turnID = turnID
        self.completionKind = completionKind
        self.lifecycleToken = lifecycleToken
        self.transcriptBinding = transcriptBinding
        self.authorityRevision = authorityRevision
    }
}
