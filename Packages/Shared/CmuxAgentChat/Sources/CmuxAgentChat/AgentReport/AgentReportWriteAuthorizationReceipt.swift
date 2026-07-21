import Foundation

/// Body-free authority carried from asynchronous validation to clipboard write.
///
/// The receipt is process-local and transient. Diagnostic output omits every
/// identity, revision, and transcript binding it carries.
public struct AgentReportWriteAuthorizationReceipt: Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    /// Opaque identity of the exact retained report.
    public let reportIdentity: UUID

    /// Agent runtime whose lifecycle authorized the report.
    public let provider: AgentReportProvider

    /// Exact process-local report surface.
    public let runtimeSurfaceID: UUID

    /// Capture-time restart-stable surface identity.
    public let stableSurfaceID: UUID?

    /// Capture-time process-local surface lifecycle authority.
    public let lifecycleToken: UUID

    /// Exact live panel object identity observed after asynchronous validation.
    public let panelInstanceID: ObjectIdentifier

    /// Provider session identity represented by the authorization.
    public let agentSessionID: String

    /// Provider turn identity represented by the authorization.
    public let turnID: String

    /// Accepted provider completion boundary.
    public let completionKind: AgentReportCompletionKind

    /// Immutable opaque capture-time transcript identity.
    public let transcriptBinding: AgentReportTranscriptBinding

    /// Exact active hook-entry revision proven during authorization.
    public let authorityRevision: UUID

    /// Report-actor policy generation observed during authorization.
    public let captureStorePolicyGeneration: UInt64

    /// Main-actor capture-policy revision observed during authorization.
    public let capturePolicyRevision: UInt64

    /// Exact host-accepted availability revision observed during authorization.
    public let availabilityRevision: AgentReportAvailabilityRevision

    private let finalWriteCapability: AgentReportFinalWriteCapability

    /// Whether the actor still recognizes this exact report as copy-authorized.
    public var isCurrentReport: Bool { finalWriteCapability.isValid }

    /// A diagnostic description containing no private authorization material.
    public var description: String { "AgentReportWriteAuthorizationReceipt" }

    /// A diagnostic description containing no private authorization material.
    public var debugDescription: String { description }

    init(
        context: AgentReportCopyAuthorizationContext,
        panelInstanceID: ObjectIdentifier
    ) {
        reportIdentity = context.reportIdentity
        provider = context.provider
        runtimeSurfaceID = context.runtimeSurfaceID
        stableSurfaceID = context.stableSurfaceID
        lifecycleToken = context.lifecycleToken
        self.panelInstanceID = panelInstanceID
        agentSessionID = context.agentSessionID
        turnID = context.turnID
        completionKind = context.completionKind
        transcriptBinding = context.transcriptBinding
        authorityRevision = context.authorityRevision
        captureStorePolicyGeneration = context.captureStorePolicyGeneration
        capturePolicyRevision = context.capturePolicyRevision
        availabilityRevision = context.availabilityRevision
        finalWriteCapability = context.finalWriteCapability
    }

    func matches(_ context: AgentReportCopyAuthorizationContext) -> Bool {
        reportIdentity == context.reportIdentity
            && provider == context.provider
            && runtimeSurfaceID == context.runtimeSurfaceID
            && stableSurfaceID == context.stableSurfaceID
            && lifecycleToken == context.lifecycleToken
            && agentSessionID == context.agentSessionID
            && turnID == context.turnID
            && completionKind == context.completionKind
            && transcriptBinding == context.transcriptBinding
            && authorityRevision == context.authorityRevision
            && captureStorePolicyGeneration == context.captureStorePolicyGeneration
            && capturePolicyRevision == context.capturePolicyRevision
            && availabilityRevision == context.availabilityRevision
            && finalWriteCapability === context.finalWriteCapability
    }
}
