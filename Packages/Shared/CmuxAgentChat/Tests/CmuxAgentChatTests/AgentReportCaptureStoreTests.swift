import Foundation
import Testing
@testable import CmuxAgentChat

@Suite("Private agent report capture store")
struct AgentReportCaptureStoreTests {
    private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let surfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let stableSurfaceID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let lifecycleToken = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    @Test("production policy defaults disabled and starts no recovery")
    func defaultPolicyIsDisabled() async {
        let recovery = StubAgentReportTranscriptRecovery(reply: "transcript reply")
        let store = AgentReportCaptureStore(transcriptRecovery: recovery)

        let result = await store.capture(request(raw: nil), target: target())

        #expect(result == .disabled)
        #expect(await recovery.callCount == 0)
        #expect(await recovery.primaryValidationCallCount == 0)
        #expect(await store.latestReport(runtimeSurfaceID: surfaceID) == nil)
    }

    @Test("test-controlled enablement captures raw text exactly and bypasses preview limits")
    func rawCaptureIsExact() async throws {
        let recovery = StubAgentReportTranscriptRecovery(reply: nil)
        let capturedAt = Date(timeIntervalSince1970: 500)
        let store = AgentReportCaptureStore(
            policy: .enabled,
            transcriptRecovery: recovery,
            now: { capturedAt }
        )
        let exact = "  # Result\n\n- 日本語 ✅\n" + String(repeating: "long-markdown-", count: 1_400) + "  \n"
        #expect(exact.count > 16_384)

        let result = await store.capture(request(raw: exact), target: target())
        let report = try #require(await store.latestReport(runtimeSurfaceID: surfaceID))

        #expect(result == .captured)
        #expect(report.finalReply == exact)
        #expect(report.captureSource == .rawHook)
        #expect(report.capturedAt == capturedAt)
        #expect(report.stableSurfaceID == stableSurfaceID)
        #expect(!report.description.contains("Synthetic report"))
        #expect(!request(raw: exact).description.contains("Synthetic report"))
        #expect(await recovery.callCount == 0)
        #expect(await recovery.primaryValidationCallCount == 1)
    }

    @Test("compact preview text is never substituted for the raw report")
    func compactPreviewIsNotTheExactSource() async throws {
        let store = AgentReportCaptureStore(
            policy: .enabled,
            transcriptRecovery: StubAgentReportTranscriptRecovery(reply: nil)
        )
        let exact = String(repeating: "x", count: 400) + "private-tail-sentinel"

        #expect(await store.capture(request(raw: exact), target: target()) == .captured)
        let report = try #require(await store.latestReport(runtimeSurfaceID: surfaceID))
        #expect(report.finalReply == exact)
        #expect(report.finalReply != String(exact.prefix(240)))
    }

    @Test("null raw field uses exact structured transcript recovery")
    func transcriptFallback() async throws {
        let exact = "Transcript **final**\n\nUnicode: こんにちは"
        let recovery = StubAgentReportTranscriptRecovery(reply: exact)
        let store = AgentReportCaptureStore(policy: .enabled, transcriptRecovery: recovery)

        #expect(await store.capture(request(raw: nil), target: target()) == .captured)
        let report = try #require(await store.latestReport(runtimeSurfaceID: surfaceID))

        #expect(report.finalReply == exact)
        #expect(report.captureSource == .structuredTranscript)
        #expect(await recovery.callCount == 1)
        #expect(await recovery.lastSessionID == "session-1")
        #expect(await recovery.lastTurnID == "turn-1")
    }

    @Test("disabling after capture atomically clears all feature-owned reports")
    func disableClearsReports() async {
        let store = AgentReportCaptureStore(
            policy: .enabled,
            transcriptRecovery: StubAgentReportTranscriptRecovery(reply: nil)
        )
        #expect(await store.capture(request(raw: "exact"), target: target()) == .captured)

        await store.setPolicy(.disabled)

        #expect(await store.isCaptureEnabled == false)
        #expect(await store.latestReport(runtimeSurfaceID: surfaceID) == nil)
    }

    @Test("missing or mismatched authoritative target rejects without retention")
    func identityMismatchRejects() async {
        let store = AgentReportCaptureStore(
            policy: .enabled,
            transcriptRecovery: StubAgentReportTranscriptRecovery(reply: nil)
        )
        #expect(
            await store.capture(request(raw: "private body"), target: nil)
                == .rejected(.inaccessibleSurface)
        )
        #expect(
            await store.capture(
                request(raw: "private body"),
                target: target(workspaceID: UUID())
            ) == .rejected(.identityMismatch)
        )
        #expect(
            await store.capture(
                request(raw: "private body"),
                target: target(surfaceID: UUID())
            ) == .rejected(.identityMismatch)
        )
        #expect(
            await store.capture(
                request(raw: "private body"),
                target: target(sessionID: "other-session")
            ) == .rejected(.identityMismatch)
        )
        #expect(
            await store.capture(
                request(raw: "private body"),
                target: target(turnID: "other-turn")
            ) == .rejected(.identityMismatch)
        )
        #expect(await store.latestReport(runtimeSurfaceID: surfaceID) == nil)
    }

    @Test("duplicate delivery is idempotent and a revalidated stale turn cannot replace newer")
    func duplicateAndStaleOrdering() async throws {
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        let store = AgentReportCaptureStore(
            policy: .enabled,
            transcriptRecovery: StubAgentReportTranscriptRecovery(reply: nil),
            now: { capturedAt }
        )
        let first = request(raw: "newest", turnID: "turn-2", completionTimestamp: 200)

        #expect(await store.capture(first, target: target(turnID: "turn-2")) == .captured)
        let originalCapturedAt = try #require(await store.latestReport(runtimeSurfaceID: surfaceID)?.capturedAt)
        #expect(await store.capture(first, target: target(turnID: "turn-2")) == .duplicate)
        #expect(await store.latestReport(runtimeSurfaceID: surfaceID)?.capturedAt == originalCapturedAt)

        let older = request(raw: "older private body", turnID: "turn-1", completionTimestamp: 300)
        #expect(
            await store.capture(
                older,
                target: target(turnID: "turn-1"),
                revalidateTarget: { target(turnID: "turn-2") }
            ) == .rejected(.identityMismatch)
        )
        #expect(await store.latestReport(runtimeSurfaceID: surfaceID)?.finalReply == "newest")
    }

    @Test("surface purge invalidates transcript recovery already in flight")
    func surfacePurgeInvalidatesInFlightRecovery() async {
        let recovery = SuspendedAgentReportTranscriptRecovery(reply: "late exact reply")
        let store = AgentReportCaptureStore(policy: .enabled, transcriptRecovery: recovery)
        let capture = Task {
            await store.capture(
                request(raw: nil),
                target: target(),
                revalidateTarget: { target() }
            )
        }
        await recovery.waitUntilRecoveryStarted()

        await store.purge(runtimeSurfaceID: surfaceID)
        await recovery.resumeRecovery()

        #expect(await capture.value == .rejected(.inaccessibleSurface))
        #expect(await store.latestReport(runtimeSurfaceID: surfaceID) == nil)
    }

    @Test("authoritative revalidation rejects a session rebind during recovery")
    func rebindDuringRecoveryIsRejected() async {
        let recovery = SuspendedAgentReportTranscriptRecovery(reply: "late exact reply")
        let targetBox = AgentReportTargetBox(target())
        let store = AgentReportCaptureStore(policy: .enabled, transcriptRecovery: recovery)
        let capture = Task {
            await store.capture(
                request(raw: nil),
                target: target(),
                revalidateTarget: { await targetBox.value }
            )
        }
        await recovery.waitUntilRecoveryStarted()
        await targetBox.set(target(surfaceID: UUID()))
        await recovery.resumeRecovery()

        #expect(await capture.value == .rejected(.identityMismatch))
        #expect(await store.latestReport(runtimeSurfaceID: surfaceID) == nil)
    }

    @Test("later receipt wins when an older transcript recovery finishes late")
    func monotonicReceiptOrderingRejectsLateRecovery() async {
        let recovery = SuspendedAgentReportTranscriptRecovery(reply: "older recovered reply")
        let store = AgentReportCaptureStore(policy: .enabled, transcriptRecovery: recovery)
        let olderCapture = Task {
            await store.capture(
                request(raw: nil, turnID: "turn-1", completionTimestamp: 9_999),
                target: target(turnID: "turn-1"),
                revalidateTarget: { target(turnID: "turn-1") }
            )
        }
        await recovery.waitUntilRecoveryStarted()

        #expect(
            await store.capture(
                request(raw: "newer exact reply", turnID: "turn-2", completionTimestamp: 1),
                target: target(turnID: "turn-2"),
                revalidateTarget: { target(turnID: "turn-2") }
            ) == .captured
        )
        await recovery.resumeRecovery()

        #expect(await olderCapture.value == .rejected(.staleCompletion))
        #expect(await store.latestReport(runtimeSurfaceID: surfaceID)?.finalReply == "newer exact reply")
    }

    @Test("raw text from a structured subagent session is rejected")
    func rawSubagentSessionIsRejected() async {
        let recovery = StubAgentReportTranscriptRecovery(reply: nil, isPrimarySession: false)
        let store = AgentReportCaptureStore(policy: .enabled, transcriptRecovery: recovery)

        #expect(
            await store.capture(request(raw: "subagent result"), target: target())
                == .rejected(.nonPrimarySession)
        )
        #expect(await store.latestReport(runtimeSurfaceID: surfaceID) == nil)
    }

    @Test("resume rebind mismatch cannot update the old surface")
    func resumeRebindRejectsOldSurface() async {
        let store = AgentReportCaptureStore(
            policy: .enabled,
            transcriptRecovery: StubAgentReportTranscriptRecovery(reply: nil)
        )
        let request = request(raw: "late old-surface reply")
        let reboundTarget = target(surfaceID: UUID(), sessionID: request.agentSessionID)

        #expect(await store.capture(request, target: reboundTarget) == .rejected(.identityMismatch))
        #expect(await store.latestReport(runtimeSurfaceID: surfaceID) == nil)
    }

    @Test("surface close purge removes only the exact runtime surface")
    func surfacePurge() async {
        let store = AgentReportCaptureStore(
            policy: .enabled,
            transcriptRecovery: StubAgentReportTranscriptRecovery(reply: nil)
        )
        #expect(await store.capture(request(raw: "exact"), target: target()) == .captured)

        await store.purge(runtimeSurfaceID: surfaceID)

        #expect(await store.latestReport(runtimeSurfaceID: surfaceID) == nil)
    }

    @Test("prompt or resume invalidation retains the last completed report")
    func lifecycleInvalidationRetainsCompletedReport() async {
        let recovery = SuspendedAgentReportTranscriptRecovery(reply: "late next-turn reply")
        let store = AgentReportCaptureStore(
            policy: .enabled,
            transcriptRecovery: recovery
        )
        #expect(await store.capture(request(raw: "completed"), target: target()) == .captured)
        let nextTurnCapture = Task {
            await store.capture(
                request(raw: nil, turnID: "turn-2"),
                target: target(turnID: "turn-2"),
                revalidateTarget: { target(turnID: "turn-2") }
            )
        }
        await recovery.waitUntilRecoveryStarted()

        await store.invalidatePendingCapture(runtimeSurfaceID: surfaceID)
        await recovery.resumeRecovery()

        #expect(await nextTurnCapture.value == .rejected(.inaccessibleSurface))
        #expect(await store.latestReport(runtimeSurfaceID: surfaceID)?.finalReply == "completed")
    }

    @Test("diagnostic descriptions disclose no identifiers or report properties")
    func diagnosticDescriptionsAreInvariantAcrossPrivateValues() {
        let shortRequest = request(raw: "private")
        let longRequest = AgentReportCaptureRequest(
            provider: .codex,
            workspaceID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            runtimeSurfaceID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            agentSessionID: "87654321-private-session",
            turnID: "12345678-private-turn",
            completionKind: .primaryStop,
            transcriptPath: "/private/transcript/path.jsonl",
            rawFinalReply: String(repeating: "secret", count: 10_000),
            completionTimestamp: Date(timeIntervalSince1970: 999)
        )
        let shortTarget = target()
        let longTarget = AgentReportCaptureTarget(
            workspaceID: longRequest.workspaceID,
            runtimeSurfaceID: longRequest.runtimeSurfaceID,
            stableSurfaceID: UUID(),
            agentSessionID: longRequest.agentSessionID,
            turnID: longRequest.turnID,
            lifecycleToken: UUID(),
            transcriptPath: longRequest.transcriptPath
        )
        let shortIdentity = shortRequest.duplicateIdentity
        let longIdentity = longRequest.duplicateIdentity
        let shortReport = report(request: shortRequest, target: shortTarget, reply: "private")
        let longReport = report(
            request: longRequest,
            target: longTarget,
            reply: String(repeating: "secret", count: 10_000)
        )

        let descriptions = [
            shortRequest.description, shortRequest.debugDescription,
            shortTarget.description, shortTarget.debugDescription,
            shortIdentity.description, shortIdentity.debugDescription,
            shortReport.description, shortReport.debugDescription,
        ]
        for description in descriptions {
            #expect(!description.contains("session-1"))
            #expect(!description.contains("session"))
            #expect(!description.contains("turn-1"))
            #expect(!description.contains("turn"))
            #expect(!description.contains("private"))
            #expect(!description.contains("7"))
        }
        #expect(shortRequest.description == longRequest.description)
        #expect(shortRequest.debugDescription == longRequest.debugDescription)
        #expect(shortTarget.description == longTarget.description)
        #expect(shortTarget.debugDescription == longTarget.debugDescription)
        #expect(shortIdentity.description == longIdentity.description)
        #expect(shortIdentity.debugDescription == longIdentity.debugDescription)
        #expect(shortReport.description == longReport.description)
        #expect(shortReport.debugDescription == longReport.debugDescription)
    }

    private func request(
        raw: String?,
        turnID: String = "turn-1",
        completionTimestamp: TimeInterval = 100
    ) -> AgentReportCaptureRequest {
        AgentReportCaptureRequest(
            provider: .codex,
            workspaceID: workspaceID,
            runtimeSurfaceID: surfaceID,
            agentSessionID: "session-1",
            turnID: turnID,
            completionKind: .primaryStop,
            transcriptPath: "/synthetic/session-1.jsonl",
            rawFinalReply: raw,
            completionTimestamp: Date(timeIntervalSince1970: completionTimestamp)
        )
    }

    private func target(
        workspaceID: UUID? = nil,
        surfaceID: UUID? = nil,
        sessionID: String = "session-1",
        turnID: String = "turn-1"
    ) -> AgentReportCaptureTarget {
        AgentReportCaptureTarget(
            workspaceID: workspaceID ?? self.workspaceID,
            runtimeSurfaceID: surfaceID ?? self.surfaceID,
            stableSurfaceID: stableSurfaceID,
            agentSessionID: sessionID,
            turnID: turnID,
            lifecycleToken: lifecycleToken,
            transcriptPath: "/synthetic/session-1.jsonl"
        )
    }

    private func report(
        request: AgentReportCaptureRequest,
        target: AgentReportCaptureTarget,
        reply: String
    ) -> AgentReport {
        AgentReport(
            provider: request.provider,
            runtimeSurfaceID: request.runtimeSurfaceID,
            stableSurfaceID: target.stableSurfaceID,
            workspaceID: request.workspaceID,
            agentSessionID: request.agentSessionID,
            turnID: request.turnID,
            completionKind: request.completionKind,
            finalReply: reply,
            captureSource: .rawHook,
            capturedAt: Date(timeIntervalSince1970: 1),
            promptTimestamp: nil,
            completionTimestamp: request.completionTimestamp,
            duplicateIdentity: request.duplicateIdentity
        )
    }
}

@Suite("Exact Codex final reply extraction")
struct CodexFinalReplyExtractorTests {
    private let extractor = CodexFinalReplyExtractor()

    @Test("primary-session validation rejects wrong and subagent metadata")
    func primarySessionValidation() {
        let primary = [jsonLine(type: "session_meta", payload: ["id": "session-1"])]
        let subagent = [jsonLine(type: "session_meta", payload: [
            "id": "session-1",
            "thread_source": "subagent",
        ])]

        #expect(extractor.isPrimarySession(lines: primary, sessionID: "session-1"))
        #expect(!extractor.isPrimarySession(lines: primary, sessionID: "other-session"))
        #expect(!extractor.isPrimarySession(lines: subagent, sessionID: "session-1"))
    }

    @Test("scopes to the accepted turn and excludes user, reasoning, and tools")
    func exactTurnClassification() {
        let exact = "  ## Exact final\n\n- Unicode: Привіт 🌍  \n"
        let lines = [
            jsonLine(type: "session_meta", payload: ["id": "session-1", "thread_source": "user"]),
            jsonLine(type: "turn_context", payload: ["turn_id": "old-turn"]),
            messageLine(role: "assistant", text: "prior response", turnID: "old-turn"),
            jsonLine(type: "event_msg", payload: ["type": "turn_complete", "turn_id": "old-turn"]),
            jsonLine(type: "turn_context", payload: ["turn_id": "turn-1"]),
            messageLine(role: "user", text: "visible prompt", turnID: "turn-1"),
            jsonLine(type: "response_item", payload: [
                "type": "reasoning",
                "summary": [["type": "summary_text", "text": "hidden reasoning"]],
            ]),
            jsonLine(type: "response_item", payload: [
                "type": "function_call_output",
                "output": "private tool output",
            ]),
            messageLine(role: "assistant", text: exact, turnID: "turn-1"),
            jsonLine(type: "event_msg", payload: ["type": "turn_complete", "turn_id": "turn-1"]),
        ]

        #expect(extractor.extract(lines: lines, sessionID: "session-1", turnID: "turn-1") == exact)
    }

    @Test("structured extraction does not apply the UI text budget")
    func longReplyIsNotTruncated() {
        let exact = String(repeating: "markdown-日本語\n", count: 1_500)
        #expect(exact.count > 16_384)
        let lines = completedTurnLines(final: exact)

        let result = extractor.extract(lines: lines, sessionID: "session-1", turnID: "turn-1")

        #expect(result == exact)
    }

    @Test("terminal last_agent_message is authoritative when available")
    func terminalMessageWins() {
        var lines = [
            jsonLine(type: "session_meta", payload: ["id": "session-1"]),
            jsonLine(type: "turn_context", payload: ["turn_id": "turn-1"]),
            messageLine(
                role: "assistant",
                text: "stream candidate",
                turnID: "turn-1",
                phase: "commentary"
            ),
        ]
        lines.append(jsonLine(type: "event_msg", payload: [
            "type": "task_complete",
            "turn_id": "turn-1",
            "last_agent_message": "exact terminal reply",
        ]))

        #expect(
            extractor.extract(lines: lines, sessionID: "session-1", turnID: "turn-1")
                == "exact terminal reply"
        )
    }

    @Test("subagent rollout session is rejected")
    func subagentSessionIsRejected() {
        let lines = [
            jsonLine(type: "session_meta", payload: ["id": "session-1", "thread_source": "subagent"]),
            jsonLine(type: "turn_context", payload: ["turn_id": "turn-1"]),
            messageLine(role: "assistant", text: "subagent result", turnID: "turn-1"),
            jsonLine(type: "event_msg", payload: ["type": "turn_complete", "turn_id": "turn-1"]),
        ]

        #expect(extractor.extract(lines: lines, sessionID: "session-1", turnID: "turn-1") == nil)
    }

    @Test("wrong session or missing terminal boundary is rejected")
    func identityAndTerminalBoundaryAreRequired() {
        let incomplete = [
            jsonLine(type: "session_meta", payload: ["id": "session-1"]),
            jsonLine(type: "turn_context", payload: ["turn_id": "turn-1"]),
            messageLine(role: "assistant", text: "not complete", turnID: "turn-1"),
        ]
        #expect(extractor.extract(lines: incomplete, sessionID: "other-session", turnID: "turn-1") == nil)
        #expect(extractor.extract(lines: incomplete, sessionID: "session-1", turnID: "turn-1") == nil)
    }

    @Test("multiple output blocks without an exact terminal string fail closed")
    func ambiguousOutputBlocksAreRejected() {
        let lines = [
            jsonLine(type: "session_meta", payload: ["id": "session-1"]),
            jsonLine(type: "turn_context", payload: ["turn_id": "turn-1"]),
            jsonLine(type: "response_item", payload: [
                "type": "message",
                "role": "assistant",
                "phase": "final_answer",
                "content": [
                    ["type": "output_text", "text": "first"],
                    ["type": "output_text", "text": "second"],
                ],
                "internal_chat_message_metadata_passthrough": ["turn_id": "turn-1"],
            ]),
            jsonLine(type: "event_msg", payload: ["type": "turn_complete", "turn_id": "turn-1"]),
        ]

        #expect(extractor.extract(lines: lines, sessionID: "session-1", turnID: "turn-1") == nil)
    }

    @Test("response-item fallback requires an authoritative final-answer phase")
    func fallbackPhaseMustBeFinalAnswer() {
        for phase in [nil, "commentary", "analysis", "intermediate", "unknown"] as [String?] {
            let lines = completedTurnLines(final: "must not capture", phase: phase)
            #expect(extractor.extract(lines: lines, sessionID: "session-1", turnID: "turn-1") == nil)
        }
        let final = completedTurnLines(final: "exact final", phase: "final_answer")
        #expect(extractor.extract(lines: final, sessionID: "session-1", turnID: "turn-1") == "exact final")
    }

    @Test("multiple final-answer response items are ambiguous without terminal text")
    func multipleFinalAnswerCandidatesAreRejected() {
        let lines = [
            jsonLine(type: "session_meta", payload: ["id": "session-1"]),
            jsonLine(type: "turn_context", payload: ["turn_id": "turn-1"]),
            messageLine(role: "assistant", text: "first final", turnID: "turn-1"),
            messageLine(role: "assistant", text: "second final", turnID: "turn-1"),
            jsonLine(type: "event_msg", payload: ["type": "turn_complete", "turn_id": "turn-1"]),
        ]

        #expect(extractor.extract(lines: lines, sessionID: "session-1", turnID: "turn-1") == nil)
    }

    @Test("nested sidechain metadata cannot authorize final-answer fallback")
    func nestedSidechainSessionIsRejected() {
        let lines = [
            jsonLine(type: "session_meta", payload: [
                "id": "session-1",
                "source": ["subagent": ["thread_id": "child"]],
            ]),
            jsonLine(type: "turn_context", payload: ["turn_id": "turn-1"]),
            messageLine(role: "assistant", text: "child final", turnID: "turn-1"),
            jsonLine(type: "event_msg", payload: ["type": "turn_complete", "turn_id": "turn-1"]),
        ]

        #expect(extractor.extract(lines: lines, sessionID: "session-1", turnID: "turn-1") == nil)
    }

    @Test("malformed trailing JSONL fragment cannot change an accepted result")
    func incompleteTrailingFragmentIsIgnored() {
        var lines = completedTurnLines(final: "exact complete reply")
        lines.append(#"{"type":"response_item","payload":{"type":"message""#)

        #expect(
            extractor.extract(lines: lines, sessionID: "session-1", turnID: "turn-1")
                == "exact complete reply"
        )
    }

    private func completedTurnLines(final: String, phase: String? = "final_answer") -> [String] {
        [
            jsonLine(type: "session_meta", payload: ["id": "session-1"]),
            jsonLine(type: "turn_context", payload: ["turn_id": "turn-1"]),
            messageLine(role: "assistant", text: final, turnID: "turn-1", phase: phase),
            jsonLine(type: "event_msg", payload: ["type": "turn_complete", "turn_id": "turn-1"]),
        ]
    }

    private func messageLine(
        role: String,
        text: String,
        turnID: String,
        phase: String? = "final_answer"
    ) -> String {
        var payload: [String: Any] = [
            "type": "message",
            "role": role,
            "content": [["type": role == "assistant" ? "output_text" : "input_text", "text": text]],
            "internal_chat_message_metadata_passthrough": ["turn_id": turnID],
        ]
        if let phase {
            payload["phase"] = phase
        }
        return jsonLine(type: "response_item", payload: payload)
    }

    private func jsonLine(type: String, payload: [String: Any]) -> String {
        let object: [String: Any] = ["type": type, "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

private actor StubAgentReportTranscriptRecovery: AgentReportTranscriptRecovering {
    private let reply: String?
    private let primarySession: Bool
    private(set) var callCount = 0
    private(set) var primaryValidationCallCount = 0
    private(set) var lastSessionID: String?
    private(set) var lastTurnID: String?

    init(reply: String?, isPrimarySession: Bool = true) {
        self.reply = reply
        self.primarySession = isPrimarySession
    }

    func isPrimaryCodexSession(recordedPath: String?, sessionID: String) async -> Bool {
        primaryValidationCallCount += 1
        return primarySession
    }

    func recoverCodexFinalReply(
        recordedPath: String?,
        sessionID: String,
        turnID: String
    ) async -> String? {
        callCount += 1
        lastSessionID = sessionID
        lastTurnID = turnID
        return reply
    }
}

private actor SuspendedAgentReportTranscriptRecovery: AgentReportTranscriptRecovering {
    private let reply: String
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var recoveryContinuation: CheckedContinuation<String?, Never>?

    init(reply: String) {
        self.reply = reply
    }

    func isPrimaryCodexSession(recordedPath: String?, sessionID: String) async -> Bool {
        true
    }

    func recoverCodexFinalReply(
        recordedPath: String?,
        sessionID: String,
        turnID: String
    ) async -> String? {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            recoveryContinuation = continuation
        }
    }

    func waitUntilRecoveryStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resumeRecovery() {
        recoveryContinuation?.resume(returning: reply)
        recoveryContinuation = nil
    }
}

private actor AgentReportTargetBox {
    private(set) var value: AgentReportCaptureTarget

    init(_ value: AgentReportCaptureTarget) {
        self.value = value
    }

    func set(_ value: AgentReportCaptureTarget) {
        self.value = value
    }
}
