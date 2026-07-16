/// The provider lifecycle boundary that completed an agent report.
public enum AgentReportCompletionKind: String, Sendable, Codable, Equatable {
    /// A primary-agent Stop event accepted by cmux's hook lifecycle tracker.
    case primaryStop
}
