/// Fixed resource ceilings for private Slice A agent-report capture.
///
/// These limits are measured in UTF-8 or raw file bytes as appropriate. They
/// are process-internal product policy, not user-configurable settings.
struct AgentReportResourceLimits: Sendable, Equatable {
    /// The fixed Slice A policy used by production capture paths.
    static let sliceA = AgentReportResourceLimits(
        maximumReportBodyBytes: 2 * 1024 * 1024,
        maximumJSONLRecordBytes: 8 * 1024 * 1024,
        maximumTranscriptBytes: 128 * 1024 * 1024,
        maximumAuthorizedSocketFrameBytes: 16 * 1024 * 1024
    )

    /// Maximum UTF-8 bytes retained as one exact final report.
    let maximumReportBodyBytes: Int

    /// Maximum bytes accepted in one complete Codex JSONL record.
    let maximumJSONLRecordBytes: Int

    /// Maximum bytes read from one Codex transcript.
    let maximumTranscriptBytes: Int

    /// Maximum bytes accepted in one authorized control-socket request frame.
    let maximumAuthorizedSocketFrameBytes: Int

    /// Creates one immutable agent-report resource policy.
    ///
    /// - Parameters:
    ///   - maximumReportBodyBytes: Maximum UTF-8 bytes in a report body.
    ///   - maximumJSONLRecordBytes: Maximum bytes in one complete JSONL record.
    ///   - maximumTranscriptBytes: Maximum bytes read from one transcript.
    ///   - maximumAuthorizedSocketFrameBytes: Maximum bytes in one authorized socket frame.
    init(
        maximumReportBodyBytes: Int,
        maximumJSONLRecordBytes: Int,
        maximumTranscriptBytes: Int,
        maximumAuthorizedSocketFrameBytes: Int
    ) {
        self.maximumReportBodyBytes = maximumReportBodyBytes
        self.maximumJSONLRecordBytes = maximumJSONLRecordBytes
        self.maximumTranscriptBytes = maximumTranscriptBytes
        self.maximumAuthorizedSocketFrameBytes = maximumAuthorizedSocketFrameBytes
    }

    /// Checks whether an exact report body fits without truncation.
    ///
    /// - Parameter value: Candidate report body.
    /// - Returns: `true` when its UTF-8 byte count is within policy.
    func permitsReportBody(_ value: String) -> Bool {
        value.utf8.count <= maximumReportBodyBytes
    }
}
