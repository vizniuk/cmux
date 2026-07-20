import Foundation

/// Content-free authority tuple used before revealing a private Agent Report.
///
/// This value intentionally omits the report body, capture source, and capture
/// timestamp. Its diagnostic descriptions also omit every identity field so
/// accidental interpolation cannot disclose session or topology metadata.
public struct AgentReportCopyAuthorizationContext: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    /// Agent runtime whose live primary-session binding must still match.
    public let provider: AgentReportProvider

    /// Capture-time workspace used only to validate the provider lifecycle
    /// record. Current ownership is independently proven from live topology.
    public let workspaceID: UUID

    /// Exact process-local surface requested by the explicit copy action.
    public let runtimeSurfaceID: UUID

    /// Capture-time restart-stable surface identity, when available.
    public let stableSurfaceID: UUID?

    /// Provider session identity used only for live authority validation.
    public let agentSessionID: String

    /// Provider turn identity used only for live authority validation.
    public let turnID: String

    /// Accepted provider completion boundary.
    public let completionKind: AgentReportCompletionKind

    /// Capture-time process-local lifecycle token that must remain current.
    public let lifecycleToken: UUID

    /// A diagnostic description containing no private identities or body text.
    public var description: String { "AgentReportCopyAuthorizationContext" }

    /// A diagnostic description containing no private identities or body text.
    public var debugDescription: String { description }

    init(report: AgentReport) {
        provider = report.provider
        workspaceID = report.workspaceID
        runtimeSurfaceID = report.runtimeSurfaceID
        stableSurfaceID = report.stableSurfaceID
        agentSessionID = report.agentSessionID
        turnID = report.turnID
        completionKind = report.completionKind
        lifecycleToken = report.lifecycleToken
    }
}
