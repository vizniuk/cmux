/// Content-free result of a private exact-report capture attempt.
public enum AgentReportCaptureResult: Sendable, Equatable {
    /// A new report was committed.
    case captured

    /// Capture is disabled; no validation, transcript read, or retention ran.
    case disabled

    /// The same completion was already committed and was left unchanged.
    case duplicate

    /// Capture was rejected without retaining report content.
    case rejected(Rejection)

    /// Content-free rejection categories safe for internal control flow.
    public enum Rejection: String, Sendable, Equatable {
        /// No exact accessible live target was supplied.
        case inaccessibleSurface

        /// Workspace, surface, session, or turn identity did not match.
        case identityMismatch

        /// Only primary Codex Stop is implemented in Slice A.
        case unsupportedCompletion

        /// Structured session metadata identifies a nested/subagent session.
        case nonPrimarySession

        /// The completion is older than the report already accepted.
        case staleCompletion

        /// Monotonic capture ordering can no longer issue a unique token.
        case captureOrderingUnavailable

        /// No exact final response could be proven.
        case exactReplyUnavailable
    }
}
