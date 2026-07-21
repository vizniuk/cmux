import Foundation

/// An exact, bounded Full Run body paired with descriptor-pinned transcript authority.
public struct AgentReportFullRunExport: Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    /// Rendered user-visible transcript span. This value is transient and clipboard-only.
    public let body: String

    /// Exact transcript descriptor identity used to render ``body``.
    public let transcriptBinding: AgentReportTranscriptBinding

    /// Content-free diagnostic description.
    public var description: String { "AgentReportFullRunExport" }

    /// Content-free diagnostic description.
    public var debugDescription: String { description }

    /// Creates an exact transient export.
    public init(body: String, transcriptBinding: AgentReportTranscriptBinding) {
        self.body = body
        self.transcriptBinding = transcriptBinding
    }
}
