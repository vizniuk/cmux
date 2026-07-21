import Foundation

/// Renders the supported user-visible records from one exact completed Codex turn.
///
/// System and developer messages, reasoning, opaque identifiers, raw events, and
/// unsupported payloads are excluded. Rendering is bounded incrementally and never
/// truncates or returns a partial body.
public struct CodexFullRunExporter: Sendable {
    private static let userNoisePrefixes = [
        "<user_instructions",
        "<environment_context",
        "<permissions",
        "<collaboration_mode",
        "<turn_aborted",
        "# AGENTS.md instructions",
    ]
    private static let privateToolArgumentKeys: Set<String> = [
        "activeentryrevision",
        "attemptid",
        "authorityrevision",
        "availabilityrevision",
        "callid",
        "capturepolicyrevision",
        "lifecycletoken",
        "policygeneration",
        "policyrevision",
        "recordedtranscriptpathhint",
        "reportid",
        "sessionid",
        "surfaceid",
        "transcriptbinding",
        "transcriptpath",
        "turnid",
        "workspaceid",
    ]

    /// Creates an exact-turn exporter.
    public init() {}

    /// Renders one exact completed turn from complete JSONL lines.
    public func export(
        lines: some Sequence<String>,
        sessionID: String,
        turnID: String
    ) -> String? {
        export(
            records: lines.lazy.map(CodexTranscriptRecord.jsonLine),
            sessionID: sessionID,
            turnID: turnID,
            maximumUTF8Bytes: AgentReportResourceLimits.maximumFullRunExportBytes
        )
    }

    /// Internal resource-boundary seam for focused package tests.
    func export(
        lines: some Sequence<String>,
        sessionID: String,
        turnID: String,
        maximumUTF8Bytes: Int
    ) -> String? {
        export(
            records: lines.lazy.map(CodexTranscriptRecord.jsonLine),
            sessionID: sessionID,
            turnID: turnID,
            maximumUTF8Bytes: maximumUTF8Bytes
        )
    }

    /// Renders one exact completed turn from descriptor-backed records.
    @_spi(AgentReportTranscript)
    public func export(
        records: some Sequence<CodexTranscriptRecord>,
        sessionID: String,
        turnID: String
    ) -> String? {
        export(
            records: records,
            sessionID: sessionID,
            turnID: turnID,
            maximumUTF8Bytes: AgentReportResourceLimits.maximumFullRunExportBytes
        )
    }

    private func export(
        records: some Sequence<CodexTranscriptRecord>,
        sessionID: String,
        turnID: String,
        maximumUTF8Bytes: Int
    ) -> String? {
        guard maximumUTF8Bytes >= 0 else { return nil }
        var renderer = BoundedRenderer(maximumUTF8Bytes: maximumUTF8Bytes)
        var sawMatchingSession = false
        var currentTurnID: String?
        var isInsideRequestedTurn = false
        var requestedTurnCompleted = false
        var lastAssistantText: String?

        for record in records {
            guard !requestedTurnCompleted else { break }
            let line: String
            switch record {
            case let .jsonLine(value):
                guard value.utf8.count <= AgentReportResourceLimits.sliceA.maximumJSONLRecordBytes else {
                    return nil
                }
                line = value
            case .malformedCompleteRecord:
                return nil
            }
            guard let root = TranscriptJSONValue(jsonLine: line), root.object != nil else {
                return nil
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
                guard let boundaryTurnID = Self.turnID(from: payload) else { return nil }
                if isInsideRequestedTurn, boundaryTurnID != turnID { return nil }
                currentTurnID = boundaryTurnID
                isInsideRequestedTurn = sawMatchingSession && boundaryTurnID == turnID

            case "response_item":
                guard isInsideRequestedTurn, sawMatchingSession, let payload else { continue }
                let itemTurnID = Self.responseItemTurnID(from: payload) ?? currentTurnID
                guard itemTurnID == turnID else { continue }
                switch payload["type"]?.string {
                case "message":
                    guard let role = payload["role"]?.string else { continue }
                    let texts = Self.visibleMessageTexts(payload, role: role)
                    for text in texts {
                        switch role {
                        case "user":
                            guard renderer.append(heading: "USER", body: text) else { return nil }
                        case "assistant":
                            guard renderer.append(heading: "ASSISTANT", body: text) else { return nil }
                            lastAssistantText = text
                        default:
                            continue
                        }
                    }
                case "function_call":
                    guard let name = payload["name"]?.string,
                          let arguments = payload["arguments"]?.string,
                          renderer.append(
                              heading: "TOOL",
                              body: Self.toolInvocationBody(name: name, arguments: arguments)
                          ) else { return nil }
                case "custom_tool_call":
                    guard let name = payload["name"]?.string,
                          let input = payload["input"]?.string,
                          renderer.append(heading: "TOOL", body: "\(name)\n\(input)") else {
                        return nil
                    }
                case "function_call_output", "custom_tool_call_output":
                    guard let output = Self.visibleToolOutput(payload["output"]),
                          renderer.append(heading: "TOOL RESULT", body: output) else {
                        return nil
                    }
                case "web_search_call":
                    guard let query = payload["action"]?["query"]?.string,
                          renderer.append(heading: "TOOL", body: "web_search\n\(query)") else {
                        return nil
                    }
                default:
                    continue
                }

            case "event_msg":
                guard let eventType = payload?["type"]?.string else { continue }
                switch eventType {
                case "task_started":
                    guard let boundaryTurnID = Self.turnID(from: payload) else { return nil }
                    if isInsideRequestedTurn, boundaryTurnID != turnID { return nil }
                    currentTurnID = boundaryTurnID
                    isInsideRequestedTurn = sawMatchingSession && boundaryTurnID == turnID
                case "task_complete", "turn_complete":
                    let completedTurnID = Self.turnID(from: payload) ?? currentTurnID
                    guard isInsideRequestedTurn, completedTurnID == turnID else { continue }
                    if let final = payload?["last_agent_message"]?.string,
                       !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       final != lastAssistantText {
                        guard renderer.append(heading: "ASSISTANT", body: final) else { return nil }
                        lastAssistantText = final
                    }
                    requestedTurnCompleted = true
                default:
                    continue
                }
            default:
                continue
            }
        }

        guard sawMatchingSession, requestedTurnCompleted, lastAssistantText != nil else { return nil }
        return renderer.renderedBody
    }

    private static func visibleMessageTexts(
        _ payload: TranscriptJSONValue,
        role: String
    ) -> [String] {
        guard role == "user" || role == "assistant" else { return [] }
        return (payload["content"]?.array ?? []).compactMap { block in
            let expectedType = role == "user" ? "input_text" : "output_text"
            guard block["type"]?.string == expectedType,
                  let text = block["text"]?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            if role == "user",
               userNoisePrefixes.contains(where: {
                   text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix($0)
               }) {
                return nil
            }
            return text
        }
    }

    private static func toolInvocationBody(name: String, arguments: String) -> String {
        guard let value = TranscriptJSONValue(jsonLine: arguments) else {
            return "\(name)\n\(arguments)"
        }
        guard let exportableValue = exportableToolArguments(value) else { return name }
        let rendered = exportableValue.compactJSONString()
        return rendered.isEmpty ? name : "\(name)\n\(rendered)"
    }

    /// Removes authority and opaque resolver fields that are never part of the
    /// user-visible tool contract, while preserving ordinary visible arguments.
    private static func exportableToolArguments(
        _ value: TranscriptJSONValue
    ) -> TranscriptJSONValue? {
        switch value {
        case .object(let object):
            let filtered = object.reduce(into: [String: TranscriptJSONValue]()) { result, entry in
                let normalizedKey = entry.key
                    .lowercased()
                    .filter { $0.isLetter || $0.isNumber }
                guard !privateToolArgumentKeys.contains(normalizedKey),
                      let child = exportableToolArguments(entry.value) else {
                    return
                }
                result[entry.key] = child
            }
            return filtered.isEmpty ? nil : .object(filtered)
        case .array(let values):
            let filtered = values.compactMap(exportableToolArguments)
            return filtered.isEmpty ? nil : .array(filtered)
        case .string, .number, .bool:
            return value
        case .null:
            return nil
        }
    }

    private static func visibleToolOutput(_ value: TranscriptJSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.lowercased().hasPrefix("data:") else { return nil }
            if let nested = TranscriptJSONValue(jsonLine: text),
               let nestedText = visibleToolOutput(nested["output"] ?? nested["content"]) {
                return nestedText
            }
            return text
        case .array(let blocks):
            let texts = blocks.compactMap { block -> String? in
                guard block["type"]?.string != "image",
                      block["image_url"] == nil else {
                    return nil
                }
                return block["text"]?.string
            }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        case .object:
            return visibleToolOutput(value["output"])
                ?? visibleToolOutput(value["content"])
                ?? visibleToolOutput(value["text"])
        case .number, .bool, .null:
            return nil
        }
    }

    private static func turnID(from payload: TranscriptJSONValue?) -> String? {
        payload?["turn_id"]?.string ?? payload?["turnId"]?.string
    }

    private static func responseItemTurnID(from payload: TranscriptJSONValue?) -> String? {
        turnID(from: payload?["internal_chat_message_metadata_passthrough"])
    }

    private static func isSubagentSession(_ payload: TranscriptJSONValue?) -> Bool {
        if (payload?["thread_source"]?.string ?? payload?["threadSource"]?.string)?
            .lowercased() == "subagent" {
            return true
        }
        return payload?["source"]?["subagent"] != nil
    }
}

private struct BoundedRenderer {
    private let maximumUTF8Bytes: Int
    private var parts: [String] = []
    private var byteCount = 0

    init(maximumUTF8Bytes: Int) {
        self.maximumUTF8Bytes = maximumUTF8Bytes
    }

    mutating func append(heading: String, body: String) -> Bool {
        let separator = parts.isEmpty ? "" : "\n\n"
        let separatorBytes = separator.utf8.count
        let headingBytes = heading.utf8.count
        let bodyBytes = body.utf8.count
        let (afterSeparator, overflow1) = byteCount.addingReportingOverflow(separatorBytes)
        let (afterHeading, overflow2) = afterSeparator.addingReportingOverflow(headingBytes)
        let (afterBreak, overflow3) = afterHeading.addingReportingOverflow(2)
        let (total, overflow4) = afterBreak.addingReportingOverflow(bodyBytes)
        guard !overflow1, !overflow2, !overflow3, !overflow4,
              total <= maximumUTF8Bytes else {
            return false
        }
        if !separator.isEmpty { parts.append(separator) }
        parts.append(heading)
        parts.append("\n\n")
        parts.append(body)
        byteCount = total
        return true
    }

    var renderedBody: String { parts.joined() }
}
