/// Content-free identity used to make repeated completion delivery idempotent.
///
/// Report text is deliberately excluded so deduplication never hashes, logs,
/// or otherwise derives an identifier from private content.
public struct AgentReportDuplicateIdentity: Sendable, Codable, Equatable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The provider that emitted the completion.
    public let provider: AgentReportProvider

    /// The provider-owned session identifier.
    public let agentSessionID: String

    /// The provider-owned turn or run identifier.
    public let turnID: String

    /// The completion boundary represented by the event.
    public let completionKind: AgentReportCompletionKind

    /// A content-free diagnostic description with no opaque identifiers.
    public var description: String {
        "AgentReportDuplicateIdentity(provider: \(provider.rawValue), "
            + "completion: \(completionKind.rawValue))"
    }

    /// A content-free diagnostic description.
    public var debugDescription: String { description }

    /// Creates a content-free duplicate identity.
    ///
    /// - Parameters:
    ///   - provider: Provider that emitted the completion.
    ///   - agentSessionID: Provider-owned session identity.
    ///   - turnID: Provider-owned completed turn identity.
    ///   - completionKind: Accepted lifecycle boundary.
    public init(
        provider: AgentReportProvider,
        agentSessionID: String,
        turnID: String,
        completionKind: AgentReportCompletionKind
    ) {
        self.provider = provider
        self.agentSessionID = agentSessionID
        self.turnID = turnID
        self.completionKind = completionKind
    }
}
