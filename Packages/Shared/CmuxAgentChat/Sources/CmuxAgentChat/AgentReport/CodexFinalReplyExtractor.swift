import Foundation

/// Extracts an exact final assistant reply from Codex rollout JSONL without
/// applying preview normalization or ``TranscriptTextBudget``.
///
/// Extraction fails closed unless the rollout proves the exact primary
/// session, requested turn, and terminal completion. Reasoning, tool, user,
/// sidechain, and subagent records are never candidates. Structured assistant
/// fallback is accepted only when Codex marks it `phase == "final_answer"`.
public struct CodexFinalReplyExtractor: Sendable {
    /// Creates an exact Codex final-reply extractor.
    public init() {}

    /// Validates exact primary-session metadata without inspecting report text.
    ///
    /// - Parameters:
    ///   - lines: Complete structured rollout records.
    ///   - sessionID: Exact provider session expected in `session_meta`.
    /// - Returns: `true` only for a matching non-subagent primary rollout.
    public func isPrimarySession(
        lines: some Sequence<String>,
        sessionID: String
    ) -> Bool {
        for line in lines {
            guard let root = TranscriptJSONValue(jsonLine: line),
                  root["type"]?.string == "session_meta" else {
                continue
            }
            let payload = root["payload"]
            let transcriptSessionID = payload?["id"]?.string
                ?? payload?["session_id"]?.string
            return transcriptSessionID == sessionID && !Self.isSubagentSession(payload)
        }
        return false
    }

    /// Extracts the final assistant text for one exact session and turn.
    ///
    /// Reasoning, user, tool, and other-turn records are ignored. A matching
    /// terminal turn event is required so a prior or partially-written turn is
    /// never guessed as the result.
    ///
    /// - Parameters:
    ///   - lines: Complete JSONL lines. Callers must omit an incomplete trailing
    ///     fragment from an actively appended file.
    ///   - sessionID: Exact Codex session identifier expected in `session_meta`.
    ///   - turnID: Exact accepted Codex turn identifier.
    /// - Returns: Exact final reply text, or `nil` when identity or completion
    ///   cannot be proven.
    public func extract(
        lines: some Sequence<String>,
        sessionID: String,
        turnID: String
    ) -> String? {
        var sawMatchingSession = false
        var currentTurnID: String?
        var responseItemCandidate: String?
        var responseItemCandidateCount = 0
        var terminalCandidate: String?
        var sawTerminalTurn = false

        for line in lines {
            guard let root = TranscriptJSONValue(jsonLine: line), root.object != nil else {
                continue
            }
            let payload = root["payload"]
            switch root["type"]?.string {
            case "session_meta":
                let transcriptSessionID = payload?["id"]?.string
                    ?? payload?["session_id"]?.string
                guard transcriptSessionID == sessionID,
                      !Self.isSubagentSession(payload) else {
                    return nil
                }
                sawMatchingSession = true

            case "turn_context":
                currentTurnID = Self.turnID(from: payload)
                if currentTurnID == turnID {
                    responseItemCandidate = nil
                    responseItemCandidateCount = 0
                    terminalCandidate = nil
                    sawTerminalTurn = false
                }

            case "response_item":
                guard sawMatchingSession,
                      payload?["type"]?.string == "message",
                      payload?["role"]?.string == "assistant",
                      payload?["phase"]?.string == "final_answer" else {
                    continue
                }
                let itemTurnID = Self.responseItemTurnID(from: payload) ?? currentTurnID
                guard itemTurnID == turnID else { continue }
                let texts = (payload?["content"]?.array ?? []).compactMap { block -> String? in
                    guard block["type"]?.string == "output_text" else { return nil }
                    return block["text"]?.string
                }
                // A single output_text block has an exact string value. When
                // multiple blocks exist and no terminal last_agent_message is
                // available, joining would invent separators, so fail closed.
                guard texts.count == 1, let candidate = texts.first else { continue }
                if !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    responseItemCandidateCount += 1
                    responseItemCandidate = candidate
                }

            case "event_msg":
                guard let eventType = payload?["type"]?.string else { continue }
                switch eventType {
                case "task_started":
                    currentTurnID = Self.turnID(from: payload)
                case "task_complete", "turn_complete":
                    let completedTurnID = Self.turnID(from: payload) ?? currentTurnID
                    guard completedTurnID == turnID else { continue }
                    sawTerminalTurn = true
                    if let final = payload?["last_agent_message"]?.string,
                       !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        terminalCandidate = final
                    }
                default:
                    continue
                }

            default:
                continue
            }
        }

        guard sawMatchingSession, sawTerminalTurn else { return nil }
        if let terminalCandidate {
            return terminalCandidate
        }
        guard responseItemCandidateCount == 1 else { return nil }
        return responseItemCandidate
    }

    /// Reads provider turn identity across supported rollout field spellings.
    private static func turnID(from payload: TranscriptJSONValue?) -> String? {
        payload?["turn_id"]?.string ?? payload?["turnId"]?.string
    }

    /// Reads the turn identity attached to an assistant response item.
    private static func responseItemTurnID(from payload: TranscriptJSONValue?) -> String? {
        let metadata = payload?["internal_chat_message_metadata_passthrough"]
        return turnID(from: metadata)
    }

    /// Rejects both explicit subagent thread sources and nested source metadata.
    private static func isSubagentSession(_ payload: TranscriptJSONValue?) -> Bool {
        if (payload?["thread_source"]?.string ?? payload?["threadSource"]?.string)?.lowercased() == "subagent" {
            return true
        }
        return payload?["source"]?["subagent"] != nil
    }
}
