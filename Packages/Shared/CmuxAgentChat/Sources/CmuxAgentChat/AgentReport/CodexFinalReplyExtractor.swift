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
        var result: Bool?
        for line in lines {
            guard line.utf8.count <= AgentReportResourceLimits.sliceA.maximumJSONLRecordBytes else {
                return false
            }
            guard let root = TranscriptJSONValue(jsonLine: line),
                  root["type"]?.string == "session_meta" else {
                continue
            }
            guard result == nil else { continue }
            let payload = root["payload"]
            let transcriptSessionID = payload?["id"]?.string
                ?? payload?["session_id"]?.string
            result = transcriptSessionID == sessionID && !Self.isSubagentSession(payload)
        }
        return result ?? false
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
        var requiresExplicitTurnBoundary = false
        var requestedTurnCompleted = false
        var completedResult: String?

        for line in lines {
            guard line.utf8.count <= AgentReportResourceLimits.sliceA.maximumJSONLRecordBytes else {
                return nil
            }
            if requestedTurnCompleted {
                continue
            }
            guard let root = TranscriptJSONValue(jsonLine: line), root.object != nil else {
                currentTurnID = nil
                responseItemCandidate = nil
                responseItemCandidateCount = 0
                terminalCandidate = nil
                requiresExplicitTurnBoundary = true
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
                guard let authoritativeTurnID = Self.turnID(from: payload) else {
                    currentTurnID = nil
                    continue
                }
                currentTurnID = authoritativeTurnID
                requiresExplicitTurnBoundary = false
                if currentTurnID == turnID {
                    responseItemCandidate = nil
                    responseItemCandidateCount = 0
                    terminalCandidate = nil
                }

            case "response_item":
                guard !requiresExplicitTurnBoundary,
                      sawMatchingSession,
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
                guard AgentReportResourceLimits.sliceA.permitsReportBody(candidate) else {
                    return nil
                }
                if !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    responseItemCandidateCount += 1
                    responseItemCandidate = candidate
                }

            case "event_msg":
                guard let eventType = payload?["type"]?.string else { continue }
                switch eventType {
                case "task_started":
                    guard let authoritativeTurnID = Self.turnID(from: payload) else {
                        currentTurnID = nil
                        continue
                    }
                    currentTurnID = authoritativeTurnID
                    requiresExplicitTurnBoundary = false
                    if authoritativeTurnID == turnID {
                        responseItemCandidate = nil
                        responseItemCandidateCount = 0
                        terminalCandidate = nil
                    }
                case "task_complete", "turn_complete":
                    guard !requiresExplicitTurnBoundary else { continue }
                    let completedTurnID = Self.turnID(from: payload) ?? currentTurnID
                    guard completedTurnID == turnID else { continue }
                    if let final = payload?["last_agent_message"]?.string {
                        guard AgentReportResourceLimits.sliceA.permitsReportBody(final) else {
                            return nil
                        }
                        if !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            terminalCandidate = final
                        }
                    }
                    requestedTurnCompleted = true
                    if let terminalCandidate {
                        completedResult = terminalCandidate
                    } else if responseItemCandidateCount == 1 {
                        completedResult = responseItemCandidate
                    }
                default:
                    continue
                }

            default:
                continue
            }
        }

        guard sawMatchingSession, requestedTurnCompleted else { return nil }
        return completedResult
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
