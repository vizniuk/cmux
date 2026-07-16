/// An agent runtime capable of producing an exact final report.
public enum AgentReportProvider: String, Sendable, Codable, Equatable {
    /// OpenAI Codex.
    case codex

    /// Anthropic Claude. The provider-neutral model reserves this value, but
    /// live Claude capture is intentionally outside Slice A.
    case claude
}
