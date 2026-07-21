import Foundation
import Testing
@testable import CmuxAgentChat

@Suite("Exact Codex Full Run export")
struct CodexFullRunExporterTests {
    private let exporter = CodexFullRunExporter()

    @Test("renders only the exact completed turn in transcript order")
    func exactCompletedTurnOrdering() throws {
        let lines = [
            jsonLine(type: "session_meta", payload: ["id": "session-secret"]),
            jsonLine(type: "turn_context", payload: ["turn_id": "old-turn"]),
            message(role: "assistant", text: "old answer", turnID: "old-turn"),
            completion(turnID: "old-turn", final: "old answer"),
            jsonLine(type: "turn_context", payload: ["turn_id": "turn-secret"]),
            message(role: "user", text: "Unicode prompt\n第二行 🌍", turnID: "turn-secret"),
            jsonLine(type: "response_item", payload: [
                "type": "function_call",
                "name": "exec_command",
                "call_id": "opaque-call-id",
                "arguments": #"{"cmd":"printf hello"}"#,
            ]),
            jsonLine(type: "response_item", payload: [
                "type": "function_call_output",
                "call_id": "opaque-call-id",
                "output": "hello\nworld",
            ]),
            message(role: "assistant", text: "Visible final ✅", turnID: "turn-secret"),
            completion(turnID: "turn-secret", final: "Visible final ✅"),
        ]

        let body = try #require(exporter.export(
            lines: lines,
            sessionID: "session-secret",
            turnID: "turn-secret"
        ))

        #expect(body == """
        USER

        Unicode prompt
        第二行 🌍

        TOOL

        exec_command
        {"cmd":"printf hello"}

        TOOL RESULT

        hello
        world

        ASSISTANT

        Visible final ✅
        """)
        #expect(!body.contains("old answer"))
        #expect(!body.contains("session-secret"))
        #expect(!body.contains("turn-secret"))
        #expect(!body.contains("opaque-call-id"))
        #expect(!body.hasSuffix("\n"))
    }

    @Test("excludes reasoning and injected system or developer content")
    func hiddenAndInternalRecordsAreExcluded() throws {
        let lines = [
            jsonLine(type: "session_meta", payload: ["id": "s"]),
            jsonLine(type: "turn_context", payload: ["turn_id": "t"]),
            message(role: "developer", text: "private developer prompt", turnID: "t"),
            message(role: "user", text: "<environment_context>private context</environment_context>", turnID: "t"),
            jsonLine(type: "response_item", payload: [
                "type": "reasoning",
                "summary": [["type": "summary_text", "text": "hidden chain of thought"]],
                "encrypted_content": "opaque-payload",
            ]),
            message(role: "user", text: "visible user", turnID: "t"),
            message(role: "assistant", text: "visible assistant", turnID: "t"),
            completion(turnID: "t", final: "visible assistant"),
        ]

        let body = try #require(exporter.export(lines: lines, sessionID: "s", turnID: "t"))

        #expect(body.contains("visible user"))
        #expect(body.contains("visible assistant"))
        #expect(!body.contains("private developer"))
        #expect(!body.contains("private context"))
        #expect(!body.contains("hidden chain"))
        #expect(!body.contains("opaque-payload"))
        #expect(!body.contains("{\"type\""))
    }

    @Test("malformed and incomplete requested turns fail closed")
    func malformedAndIncompleteAreRejected() {
        let prefix = [
            jsonLine(type: "session_meta", payload: ["id": "s"]),
            jsonLine(type: "turn_context", payload: ["turn_id": "t"]),
            message(role: "assistant", text: "must not export", turnID: "t"),
        ]
        #expect(exporter.export(lines: prefix, sessionID: "s", turnID: "t") == nil)
        #expect(exporter.export(
            lines: prefix + [#"{"type":"response_item""#] + [completion(turnID: "t", final: "must not export")],
            sessionID: "s",
            turnID: "t"
        ) == nil)
        #expect(exporter.export(
            lines: prefix + [jsonLine(type: "turn_context", payload: ["turn_id": "new"])],
            sessionID: "s",
            turnID: "t"
        ) == nil)
    }

    @Test("binary tool payloads and output metadata are excluded")
    func binaryToolPayloadsAreExcluded() throws {
        let nestedOutput = jsonLine(type: "unused", payload: [:])
        let lines = [
            jsonLine(type: "session_meta", payload: ["id": "s"]),
            jsonLine(type: "turn_context", payload: ["turn_id": "t"]),
            jsonLine(type: "response_item", payload: [
                "type": "function_call_output",
                "output": [
                    ["type": "image", "image_url": "data:image/png;base64,PRIVATE-BINARY"],
                    ["type": "output_text", "text": "visible output"],
                ],
            ]),
            jsonLine(type: "response_item", payload: [
                "type": "function_call_output",
                "output": #"{"output":"nested visible","metadata":{"opaque":"PRIVATE-METADATA"}}"#,
            ]),
            jsonLine(type: "response_item", payload: [
                "type": "web_search_call",
                "action": ["query": "visible query", "opaque_id": "PRIVATE-ID"],
            ]),
            jsonLine(type: "response_item", payload: [
                "type": "function_call",
                "name": "visible_tool",
                "arguments": #"{"query":"visible argument","session_id":"PRIVATE-SESSION","lifecycleToken":"PRIVATE-LIFECYCLE","nested":{"surfaceID":"PRIVATE-SURFACE"}}"#,
            ]),
            message(role: "assistant", text: "done", turnID: "t"),
            completion(turnID: "t", final: "done"),
        ]

        let body = try #require(exporter.export(lines: lines, sessionID: "s", turnID: "t"))

        #expect(body.contains("visible output"))
        #expect(body.contains("nested visible"))
        #expect(body.contains("visible query"))
        #expect(body.contains("visible argument"))
        #expect(!body.contains("PRIVATE-BINARY"))
        #expect(!body.contains("PRIVATE-METADATA"))
        #expect(!body.contains("PRIVATE-ID"))
        #expect(!body.contains("PRIVATE-SESSION"))
        #expect(!body.contains("PRIVATE-LIFECYCLE"))
        #expect(!body.contains("PRIVATE-SURFACE"))
        #expect(!body.contains(nestedOutput))
    }

    @Test("the 8 MiB ceiling is incremental and never truncates")
    func renderedByteBoundary() throws {
        let baseLines = [
            jsonLine(type: "session_meta", payload: ["id": "s"]),
            jsonLine(type: "turn_context", payload: ["turn_id": "t"]),
        ]
        let suffix = [completion(turnID: "t", final: "final")]
        let small = baseLines + [message(role: "assistant", text: "1234", turnID: "t")] + suffix
        let exact = try #require(exporter.export(
            lines: small,
            sessionID: "s",
            turnID: "t",
            maximumUTF8Bytes: "ASSISTANT\n\n1234\n\nASSISTANT\n\nfinal".utf8.count
        ))
        #expect(exact == "ASSISTANT\n\n1234\n\nASSISTANT\n\nfinal")
        #expect(exporter.export(
            lines: small,
            sessionID: "s",
            turnID: "t",
            maximumUTF8Bytes: exact.utf8.count - 1
        ) == nil)
        #expect(AgentReportResourceLimits.maximumFullRunExportBytes == 8 * 1024 * 1024)
    }

    @Test("the production 8 MiB boundary accepts exact output and rejects one byte above")
    func productionRenderedByteBoundary() throws {
        let maximum = AgentReportResourceLimits.maximumFullRunExportBytes
        let firstText = String(repeating: "x", count: 4 * 1024 * 1024)
        let renderedSectionOverhead = "ASSISTANT\n\n\n\nASSISTANT\n\n".utf8.count
        let secondText = String(
            repeating: "y",
            count: maximum - renderedSectionOverhead - firstText.utf8.count
        )
        let prefix = [
            jsonLine(type: "session_meta", payload: ["id": "s"]),
            jsonLine(type: "turn_context", payload: ["turn_id": "t"]),
            message(role: "assistant", text: firstText, turnID: "t"),
        ]
        let exactLines = prefix + [
            message(role: "assistant", text: secondText, turnID: "t"),
            completion(turnID: "t", final: secondText),
        ]

        let exact = try #require(exporter.export(
            lines: exactLines,
            sessionID: "s",
            turnID: "t"
        ))
        #expect(exact.utf8.count == maximum)

        let oversizedSecondText = secondText + "y"
        #expect(exporter.export(
            lines: prefix + [
                message(role: "assistant", text: oversizedSecondText, turnID: "t"),
                completion(turnID: "t", final: oversizedSecondText),
            ],
            sessionID: "s",
            turnID: "t"
        ) == nil)
    }

    private func message(role: String, text: String, turnID: String) -> String {
        jsonLine(type: "response_item", payload: [
            "type": "message",
            "role": role,
            "phase": role == "assistant" ? "final_answer" : "",
            "content": [[
                "type": role == "assistant" ? "output_text" : "input_text",
                "text": text,
            ]],
            "internal_chat_message_metadata_passthrough": ["turn_id": turnID],
        ])
    }

    private func completion(turnID: String, final: String) -> String {
        jsonLine(type: "event_msg", payload: [
            "type": "task_complete",
            "turn_id": turnID,
            "last_agent_message": final,
        ])
    }

    private func jsonLine(type: String, payload: [String: Any]) -> String {
        let object: [String: Any] = ["type": type, "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
