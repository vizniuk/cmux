/// Recovers an exact final reply from a provider-owned structured transcript.
///
/// Implementations perform file I/O away from the main actor and fail closed
/// unless session, turn, primary-agent, and terminal boundaries are proven.
/// They return only assistant output; reasoning, tool, user, sidechain, and
/// subagent records are excluded.
public protocol AgentReportTranscriptRecovering: Sendable {
    /// Proves that a Codex transcript belongs to the requested primary session.
    ///
    /// Raw Stop text is exact content, but it does not itself prove that the
    /// emitting session is the primary agent. Capture therefore fails closed
    /// unless the structured rollout supplies matching, non-subagent session
    /// metadata.
    func isPrimaryCodexSession(
        recordedPath: String?,
        sessionID: String
    ) async -> Bool

    /// Recovers one exact Codex final reply.
    ///
    /// - Parameters:
    ///   - recordedPath: Hook-recorded path validated for the live session, or
    ///     `nil` when the conventional session resolver must be used.
    ///   - sessionID: Exact Codex session identifier.
    ///   - turnID: Exact accepted Codex turn identifier.
    /// - Returns: Exact final reply text, or `nil` when correspondence cannot
    ///   be proven.
    func recoverCodexFinalReply(
        recordedPath: String?,
        sessionID: String,
        turnID: String
    ) async -> String?
}
