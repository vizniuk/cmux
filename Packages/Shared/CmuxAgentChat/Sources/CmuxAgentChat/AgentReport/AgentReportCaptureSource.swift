/// The authoritative source used to capture an exact agent report.
public enum AgentReportCaptureSource: String, Sendable, Codable, Equatable {
    /// The provider's raw completion hook field.
    case rawHook

    /// A structured provider transcript scoped to the exact session and turn.
    case structuredTranscript
}
