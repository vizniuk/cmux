/// Exact structured final reply and the transcript authority that proved it.
public struct AgentReportRecoveryResult: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    /// Exact unmodified final assistant reply.
    public let body: String

    /// Opaque identity of the descriptor-pinned transcript used for recovery.
    public let transcriptBinding: AgentReportTranscriptBinding

    /// A diagnostic description containing no body or authority material.
    public var description: String { "AgentReportRecoveryResult" }

    /// A diagnostic description containing no body or authority material.
    public var debugDescription: String { description }

    /// Creates one inseparable structured-recovery result.
    ///
    /// - Parameters:
    ///   - body: Exact unmodified final assistant reply.
    ///   - transcriptBinding: Exact resolver-proven transcript identity.
    public init(body: String, transcriptBinding: AgentReportTranscriptBinding) {
        self.body = body
        self.transcriptBinding = transcriptBinding
    }
}
