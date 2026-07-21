import Foundation

/// Content-free authority tuple used before revealing a private Agent Report.
///
/// This value intentionally omits the report body, capture source, and capture
/// timestamp. Its diagnostic descriptions also omit every identity field so
/// accidental interpolation cannot disclose session or topology metadata.
public struct AgentReportCopyAuthorizationContext: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    /// Opaque identity of the exact actor-owned retained report.
    public let reportIdentity: UUID

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

    /// Immutable opaque capture-time transcript identity.
    public let transcriptBinding: AgentReportTranscriptBinding?

    /// Report-actor policy generation observed before authorization suspended.
    public let captureStorePolicyGeneration: UInt64

    /// Main-actor capture-policy revision observed before authorization.
    public let capturePolicyRevision: UInt64

    /// Host-accepted availability revision observed before authorization.
    public let availabilityRevision: AgentReportAvailabilityRevision

    let finalWriteCapability: AgentReportFinalWriteCapability

    /// A diagnostic description containing no private identities or body text.
    public var description: String { "AgentReportCopyAuthorizationContext" }

    /// A diagnostic description containing no private identities or body text.
    public var debugDescription: String { description }

    init(
        report: AgentReport,
        captureStorePolicyGeneration: UInt64,
        capturePolicyRevision: UInt64,
        availabilityRevision: AgentReportAvailabilityRevision,
        finalWriteCapability: AgentReportFinalWriteCapability
    ) {
        reportIdentity = report.reportIdentity
        provider = report.provider
        workspaceID = report.workspaceID
        runtimeSurfaceID = report.runtimeSurfaceID
        stableSurfaceID = report.stableSurfaceID
        agentSessionID = report.agentSessionID
        turnID = report.turnID
        completionKind = report.completionKind
        lifecycleToken = report.lifecycleToken
        transcriptBinding = report.transcriptBinding
        self.captureStorePolicyGeneration = captureStorePolicyGeneration
        self.capturePolicyRevision = capturePolicyRevision
        self.availabilityRevision = availabilityRevision
        self.finalWriteCapability = finalWriteCapability
    }

    /// Creates a body-free final-write receipt after app authority succeeds.
    ///
    /// - Parameter panelInstanceID: Exact live panel object identity revalidated
    ///   after the asynchronous registry lookup.
    /// - Returns: A receipt bound to this exact report authorization context.
    public func writeAuthorizationReceipt(
        panelInstanceID: ObjectIdentifier
    ) -> AgentReportWriteAuthorizationReceipt {
        AgentReportWriteAuthorizationReceipt(
            context: self,
            panelInstanceID: panelInstanceID
        )
    }

    public static func == (
        lhs: AgentReportCopyAuthorizationContext,
        rhs: AgentReportCopyAuthorizationContext
    ) -> Bool {
        lhs.reportIdentity == rhs.reportIdentity
            && lhs.provider == rhs.provider
            && lhs.workspaceID == rhs.workspaceID
            && lhs.runtimeSurfaceID == rhs.runtimeSurfaceID
            && lhs.stableSurfaceID == rhs.stableSurfaceID
            && lhs.agentSessionID == rhs.agentSessionID
            && lhs.turnID == rhs.turnID
            && lhs.completionKind == rhs.completionKind
            && lhs.lifecycleToken == rhs.lifecycleToken
            && lhs.transcriptBinding == rhs.transcriptBinding
            && lhs.captureStorePolicyGeneration == rhs.captureStorePolicyGeneration
            && lhs.capturePolicyRevision == rhs.capturePolicyRevision
            && lhs.availabilityRevision == rhs.availabilityRevision
            && lhs.finalWriteCapability === rhs.finalWriteCapability
    }
}
