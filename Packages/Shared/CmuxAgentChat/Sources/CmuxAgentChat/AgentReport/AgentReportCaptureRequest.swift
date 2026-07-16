import Foundation

/// Private, strongly typed capture request decoded from the local socket.
///
/// The request is accepted only for an exact live workspace/surface/session/
/// turn tuple. It is never eligible for focused, default, or sole-surface
/// fallback. `rawFinalReply` and transcript-derived content must remain on the
/// dedicated private capture path and must not enter diagnostics or fanout.
public struct AgentReportCaptureRequest: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Provider that emitted the completion.
    public let provider: AgentReportProvider

    /// Exact workspace claimed by the accepted hook route.
    public let workspaceID: UUID

    /// Exact live runtime surface claimed by the accepted hook route.
    public let runtimeSurfaceID: UUID

    /// Provider-owned session identifier.
    public let agentSessionID: String

    /// Provider-owned turn or run identifier.
    public let turnID: String

    /// Accepted completion boundary.
    public let completionKind: AgentReportCompletionKind

    /// Hook-recorded transcript path, when supplied. The app validates this
    /// against the exact session binding before any transcript read.
    public let transcriptPath: String?

    /// Unmodified raw completion field, when supplied. Never log this value.
    public let rawFinalReply: String?

    /// When the completion reached the CLI's accepted Stop boundary.
    public let completionTimestamp: Date

    /// Provider prompt timestamp when authoritatively supplied.
    public let promptTimestamp: Date?

    /// Content-free identity for idempotency.
    public var duplicateIdentity: AgentReportDuplicateIdentity {
        AgentReportDuplicateIdentity(
            provider: provider,
            agentSessionID: agentSessionID,
            turnID: turnID,
            completionKind: completionKind
        )
    }

    /// A content-free diagnostic description.
    public var description: String {
        "AgentReportCaptureRequest(provider: \(provider.rawValue), "
            + "session: \(agentSessionID.prefix(8)), turn: \(turnID.prefix(8)), "
            + "hasRawReply: \(rawFinalReply != nil))"
    }

    /// A content-free diagnostic description.
    public var debugDescription: String { description }

    /// Creates a private capture request from an accepted provider completion.
    ///
    /// - Parameters:
    ///   - provider: Provider that emitted the completion.
    ///   - workspaceID: Exact workspace claimed by the accepted route.
    ///   - runtimeSurfaceID: Exact live process-local surface claimed by the route.
    ///   - agentSessionID: Provider-owned session identity.
    ///   - turnID: Provider-owned completed turn identity.
    ///   - completionKind: Accepted provider lifecycle boundary.
    ///   - transcriptPath: Hook-recorded transcript path, when supplied.
    ///   - rawFinalReply: Unmodified raw final assistant field, when supplied.
    ///   - completionTimestamp: Time the completion reached the CLI boundary.
    ///   - promptTimestamp: Authoritative provider prompt time, when supplied.
    public init(
        provider: AgentReportProvider,
        workspaceID: UUID,
        runtimeSurfaceID: UUID,
        agentSessionID: String,
        turnID: String,
        completionKind: AgentReportCompletionKind,
        transcriptPath: String?,
        rawFinalReply: String?,
        completionTimestamp: Date,
        promptTimestamp: Date? = nil
    ) {
        self.provider = provider
        self.workspaceID = workspaceID
        self.runtimeSurfaceID = runtimeSurfaceID
        self.agentSessionID = agentSessionID
        self.turnID = turnID
        self.completionKind = completionKind
        self.transcriptPath = transcriptPath
        self.rawFinalReply = rawFinalReply
        self.completionTimestamp = completionTimestamp
        self.promptTimestamp = promptTimestamp
    }
}
