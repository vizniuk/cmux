/// Resolver proof for one exact primary Codex transcript.
public struct ValidatedCodexTranscriptAuthority: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    /// Opaque identity of the descriptor-pinned transcript that was validated.
    public let transcriptBinding: AgentReportTranscriptBinding

    /// A diagnostic description containing no transcript authority material.
    public var description: String { "ValidatedCodexTranscriptAuthority" }

    /// A diagnostic description containing no transcript authority material.
    public var debugDescription: String { description }

    /// Creates resolver proof for a descriptor-pinned transcript.
    ///
    /// - Parameter transcriptBinding: Exact resolver-proven transcript identity.
    public init(transcriptBinding: AgentReportTranscriptBinding) {
        self.transcriptBinding = transcriptBinding
    }
}
