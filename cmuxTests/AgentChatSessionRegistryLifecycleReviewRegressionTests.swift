import CMUXAgentLaunch
import CmuxAgentChat
import Darwin
import Foundation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatSessionRegistryLifecycleReviewRegressionTests {
    @MainActor
    @Test func promptAndResumeLifecycleInvalidateOnlyBoundReportSurfaces() {
        let registry = AgentChatSessionRegistry()
        let service = AgentChatTranscriptService(registry: registry)
        let workspaceID = UUID().uuidString
        let originalSurfaceID = UUID()
        let resumedSurfaceID = UUID()
        let sessionID = "synthetic-report-lifecycle-session"
        var invalidated: [UUID] = []
        service.setAgentReportSurfaceInvalidator { invalidated.append($0) }

        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: workspaceID,
            surfaceId: originalSurfaceID.uuidString
        ))
        service.noteResumeInitiated(
            sessionID: sessionID,
            source: "codex",
            surfaceID: resumedSurfaceID.uuidString,
            workspaceID: workspaceID,
            workingDirectory: nil
        )

        #expect(invalidated.contains(originalSurfaceID))
        #expect(invalidated.contains(resumedSurfaceID))
    }

    @Test func exactCodexRecoveryReadsOffMainAndIgnoresIncompleteTrailingFragment() async throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionID = "synthetic-recovery-session"
        let turnID = "synthetic-recovery-turn"
        let exact = "  # Exact\n\n日本語 and Markdown  \n"
        let transcriptURL = home
            .appendingPathComponent(".codex/sessions/2026/07/17", isDirectory: true)
            .appendingPathComponent("synthetic-rollout.jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let lines: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": sessionID]],
            ["type": "turn_context", "payload": ["turn_id": turnID]],
            ["type": "response_item", "payload": [
                "type": "reasoning",
                "summary": [["type": "summary_text", "text": "excluded reasoning"]],
            ]],
            ["type": "response_item", "payload": [
                "type": "message",
                "role": "assistant",
                "phase": "final_answer",
                "content": [["type": "output_text", "text": exact]],
                "internal_chat_message_metadata_passthrough": ["turn_id": turnID],
            ]],
            ["type": "event_msg", "payload": ["type": "turn_complete", "turn_id": turnID]],
        ]
        let complete = try lines.map { object in
            String(
                decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                as: UTF8.self
            )
        }.joined(separator: "\n") + "\n"
        try (complete + #"{"type":"response_item","payload":{"type":"message""#).write(
            to: transcriptURL,
            atomically: true,
            encoding: .utf8
        )
        let resolver = AgentChatTranscriptResolver(homeDirectory: home, environment: [:])

        let recovered = await resolver.recoverCodexFinalReply(
            recordedPath: transcriptURL.path,
            sessionID: sessionID,
            turnID: turnID
        )

        #expect(recovered?.body == exact)
    }

    @Test func resolverReturnsExactBindingForRecordedMissingAndStaleFallbacks() async throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(
            ".codex/sessions/2026/07/21",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionID = "resolver-binding-session"
        let turnID = "resolver-binding-turn"
        let first = directory.appendingPathComponent("rollout-a-\(sessionID).jsonl")
        let second = directory.appendingPathComponent("rollout-b-\(sessionID).jsonl")
        try codexTranscriptText(
            sessionID: sessionID,
            turnID: turnID,
            finalReply: "fallback F1"
        ).write(to: first, atomically: false, encoding: .utf8)
        try codexTranscriptText(
            sessionID: sessionID,
            turnID: turnID,
            finalReply: "fallback F2"
        ).write(to: second, atomically: false, encoding: .utf8)
        let resolver = AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        let firstDirect = try #require(await resolver.recoverCodexFinalReply(
            recordedPath: first.path,
            sessionID: sessionID,
            turnID: turnID
        ))
        let secondDirect = try #require(await resolver.recoverCodexFinalReply(
            recordedPath: second.path,
            sessionID: sessionID,
            turnID: turnID
        ))
        #expect(firstDirect.transcriptBinding != secondDirect.transcriptBinding)

        let missingFallback = try #require(await resolver.recoverCodexFinalReply(
            recordedPath: nil,
            sessionID: sessionID,
            turnID: turnID
        ))
        let repeatedFallback = try #require(await resolver.recoverCodexFinalReply(
            recordedPath: nil,
            sessionID: sessionID,
            turnID: turnID
        ))
        #expect(missingFallback.transcriptBinding == repeatedFallback.transcriptBinding)
        #expect([
            firstDirect.transcriptBinding,
            secondDirect.transcriptBinding,
        ].contains(missingFallback.transcriptBinding))

        let staleFallback = try #require(await resolver.recoverCodexFinalReply(
            recordedPath: directory.appendingPathComponent("missing.jsonl").path,
            sessionID: sessionID,
            turnID: turnID
        ))
        let outsideFallback = try #require(await resolver.recoverCodexFinalReply(
            recordedPath: home.appendingPathComponent("outside.jsonl").path,
            sessionID: sessionID,
            turnID: turnID
        ))
        #expect(staleFallback.transcriptBinding == missingFallback.transcriptBinding)
        #expect(outsideFallback.transcriptBinding == missingFallback.transcriptBinding)

        let primaryAuthority = try #require(await resolver.validatePrimaryCodexSession(
            recordedPath: nil,
            sessionID: sessionID
        ))
        #expect(primaryAuthority.transcriptBinding == missingFallback.transcriptBinding)

        let selectedURL = missingFallback.transcriptBinding == firstDirect.transcriptBinding
            ? first
            : second
        let replacementURL = selectedURL == first ? second : first
        try FileManager.default.removeItem(at: selectedURL)
        let changedSelection = try #require(await resolver.recoverCodexFinalReply(
            recordedPath: nil,
            sessionID: sessionID,
            turnID: turnID
        ))
        #expect(changedSelection.transcriptBinding != missingFallback.transcriptBinding)
        #expect(
            changedSelection.transcriptBinding
                == (replacementURL == first
                    ? firstDirect.transcriptBinding
                    : secondDirect.transcriptBinding)
        )

        try FileManager.default.removeItem(at: replacementURL)
        #expect(await resolver.recoverCodexFinalReply(
            recordedPath: nil,
            sessionID: sessionID,
            turnID: turnID
        ) == nil)
    }

    @Test func canonicallyEquivalentTrustedResolutionProducesOneBinding() async throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let realCodexRoot = home.appendingPathComponent("real-codex", isDirectory: true)
        let configuredCodexRoot = home.appendingPathComponent("configured-codex", isDirectory: true)
        let canonicalTranscript = realCodexRoot
            .appendingPathComponent("sessions/2026/07/21", isDirectory: true)
            .appendingPathComponent("rollout-canonical-session.jsonl")
        try FileManager.default.createDirectory(
            at: canonicalTranscript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try codexTranscriptText(
            sessionID: "canonical-session",
            turnID: "canonical-turn",
            finalReply: "canonical body"
        ).write(to: canonicalTranscript, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: configuredCodexRoot,
            withDestinationURL: realCodexRoot
        )
        let configuredTranscript = configuredCodexRoot
            .appendingPathComponent("sessions/2026/07/21", isDirectory: true)
            .appendingPathComponent("rollout-canonical-session.jsonl")
        let resolver = AgentChatTranscriptResolver(
            homeDirectory: home,
            environment: ["CODEX_HOME": configuredCodexRoot.path]
        )

        let configured = try #require(await resolver.recoverCodexFinalReply(
            recordedPath: configuredTranscript.path,
            sessionID: "canonical-session",
            turnID: "canonical-turn"
        ))
        let canonical = try #require(await resolver.recoverCodexFinalReply(
            recordedPath: canonicalTranscript.path,
            sessionID: "canonical-session",
            turnID: "canonical-turn"
        ))

        #expect(configured.transcriptBinding == canonical.transcriptBinding)
    }

    @Test func invalidUTF8CompleteRecordClearsInheritedAuthorityAndCandidates() async throws {
        let fixture = try rawTranscriptFixture(fileName: "invalid-utf8-authority.jsonl")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        var data = Data()
        appendJSONLLine(
            #"{"type":"session_meta","payload":{"id":"\#(fixture.sessionID)"}}"#,
            to: &data
        )
        appendJSONLLine(
            #"{"type":"turn_context","payload":{"turn_id":"turn-a"}}"#,
            to: &data
        )
        appendJSONLLine(finalReplyLine(text: "stale report candidate", turnID: nil), to: &data)
        appendInvalidUTF8JSONRecord(terminated: true, to: &data)
        appendJSONLLine(finalReplyLine(text: "must not inherit turn A", turnID: nil), to: &data)
        appendJSONLLine(
            #"{"type":"event_msg","payload":{"type":"turn_complete","last_agent_message":"stale completion candidate"}}"#,
            to: &data
        )
        try data.write(to: fixture.transcript)

        let recovered = await AgentChatTranscriptResolver(
            homeDirectory: fixture.home,
            environment: [:]
        ).recoverCodexFinalReply(
            recordedPath: fixture.transcript.path,
            sessionID: fixture.sessionID,
            turnID: "turn-a"
        )

        #expect(recovered == nil)
    }

    @Test func invalidUTF8CorruptionAllowsOnlyNewExplicitTurnBoundary() async throws {
        let fixture = try rawTranscriptFixture(fileName: "invalid-utf8-new-boundary.jsonl")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        var data = Data()
        appendJSONLLine(
            #"{"type":"session_meta","payload":{"id":"\#(fixture.sessionID)"}}"#,
            to: &data
        )
        appendJSONLLine(
            #"{"type":"turn_context","payload":{"turn_id":"turn-a"}}"#,
            to: &data
        )
        appendInvalidUTF8JSONRecord(terminated: true, to: &data)
        appendJSONLLine(finalReplyLine(text: "must not inherit turn A", turnID: nil), to: &data)
        appendJSONLLine(
            #"{"type":"event_msg","payload":{"type":"turn_complete"}}"#,
            to: &data
        )
        appendJSONLLine(
            #"{"type":"turn_context","payload":{"turn_id":"turn-b"}}"#,
            to: &data
        )
        appendJSONLLine(finalReplyLine(text: "authorized turn B", turnID: nil), to: &data)
        appendJSONLLine(
            #"{"type":"event_msg","payload":{"type":"turn_complete"}}"#,
            to: &data
        )
        try data.write(to: fixture.transcript)

        let resolver = AgentChatTranscriptResolver(homeDirectory: fixture.home, environment: [:])
        #expect(
            await resolver.recoverCodexFinalReply(
                recordedPath: fixture.transcript.path,
                sessionID: fixture.sessionID,
                turnID: "turn-a"
            ) == nil
        )
        #expect(
            await resolver.recoverCodexFinalReply(
                recordedPath: fixture.transcript.path,
                sessionID: fixture.sessionID,
                turnID: "turn-b"
            )?.body == "authorized turn B"
        )
    }

    @Test func invalidUTF8IncompleteEOFTailIsDiscarded() async throws {
        let fixture = try rawTranscriptFixture(fileName: "invalid-utf8-incomplete-tail.jsonl")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        var data = Data()
        appendJSONLLine(
            #"{"type":"session_meta","payload":{"id":"\#(fixture.sessionID)"}}"#,
            to: &data
        )
        appendJSONLLine(
            #"{"type":"turn_context","payload":{"turn_id":"turn-a"}}"#,
            to: &data
        )
        appendJSONLLine(finalReplyLine(text: "complete before tail", turnID: nil), to: &data)
        appendJSONLLine(
            #"{"type":"event_msg","payload":{"type":"turn_complete"}}"#,
            to: &data
        )
        appendInvalidUTF8JSONRecord(terminated: false, to: &data)
        try data.write(to: fixture.transcript)

        let recovered = await AgentChatTranscriptResolver(
            homeDirectory: fixture.home,
            environment: [:]
        ).recoverCodexFinalReply(
            recordedPath: fixture.transcript.path,
            sessionID: fixture.sessionID,
            turnID: "turn-a"
        )

        #expect(recovered?.body == "complete before tail")
    }

    @Test func completedTurnIsFrozenBeforeLaterInvalidUTF8() async throws {
        let fixture = try rawTranscriptFixture(fileName: "invalid-utf8-after-completion.jsonl")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        var data = Data()
        appendJSONLLine(
            #"{"type":"session_meta","payload":{"id":"\#(fixture.sessionID)"}}"#,
            to: &data
        )
        appendJSONLLine(
            #"{"type":"turn_context","payload":{"turn_id":"turn-a"}}"#,
            to: &data
        )
        appendJSONLLine(finalReplyLine(text: "frozen turn A", turnID: nil), to: &data)
        appendJSONLLine(
            #"{"type":"event_msg","payload":{"type":"turn_complete"}}"#,
            to: &data
        )
        appendInvalidUTF8JSONRecord(terminated: true, to: &data)
        appendJSONLLine(
            #"{"type":"turn_context","payload":{"turn_id":"turn-b"}}"#,
            to: &data
        )
        appendJSONLLine(finalReplyLine(text: "later turn B", turnID: nil), to: &data)
        appendJSONLLine(
            #"{"type":"event_msg","payload":{"type":"turn_complete"}}"#,
            to: &data
        )
        try data.write(to: fixture.transcript)

        let recovered = await AgentChatTranscriptResolver(
            homeDirectory: fixture.home,
            environment: [:]
        ).recoverCodexFinalReply(
            recordedPath: fixture.transcript.path,
            sessionID: fixture.sessionID,
            turnID: "turn-a"
        )

        #expect(recovered?.body == "frozen turn A")
    }

    @Test func codexReportPathValidationRejectsUntrustedAndNonRegularTargets() async throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessionsRoot = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let nestedDirectory = sessionsRoot.appendingPathComponent("2026/07/17", isDirectory: true)
        let outsideDirectory = home.appendingPathComponent("outside", isDirectory: true)
        let siblingDirectory = home.appendingPathComponent(".codex/sessions-escape", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingDirectory, withIntermediateDirectories: true)

        let valid = nestedDirectory.appendingPathComponent("rollout-valid.jsonl")
        let outside = outsideDirectory.appendingPathComponent("rollout-outside.jsonl")
        let sibling = siblingDirectory.appendingPathComponent("rollout-sibling.jsonl")
        let wrongExtension = nestedDirectory.appendingPathComponent("rollout-wrong.txt")
        for url in [valid, outside, sibling, wrongExtension] {
            try "{}\n".write(to: url, atomically: true, encoding: .utf8)
        }

        let insideSymlink = nestedDirectory.appendingPathComponent("rollout-inside-link.jsonl")
        let escapeSymlink = nestedDirectory.appendingPathComponent("rollout-escape-link.jsonl")
        try FileManager.default.createSymbolicLink(at: insideSymlink, withDestinationURL: valid)
        try FileManager.default.createSymbolicLink(at: escapeSymlink, withDestinationURL: outside)
        let intermediateSymlink = sessionsRoot.appendingPathComponent("linked-day", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: intermediateSymlink, withDestinationURL: nestedDirectory)
        let intermediateSymlinkTarget = intermediateSymlink.appendingPathComponent("rollout-valid.jsonl")

        let directoryTarget = nestedDirectory.appendingPathComponent("rollout-directory.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryTarget, withIntermediateDirectories: true)
        let fifoTarget = nestedDirectory.appendingPathComponent("rollout-fifo.jsonl")
        #expect(Darwin.mkfifo(fifoTarget.path, S_IRUSR | S_IWUSR) == 0)

        let resolver = AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        let noFallbackSession = "session-with-no-filename-match"
        #expect(
            AgentChatTranscriptResolver.hasStrictRawPathComponents(valid.path)
        )
        for rawPath in [
            "~/.codex/sessions/2026/07/17/rollout-valid.jsonl",
            "~user/.codex/sessions/2026/07/17/rollout-valid.jsonl",
            "2026/07/17/rollout-valid.jsonl",
            "/",
            "",
            "//tmp/rollout-valid.jsonl",
            "///tmp/rollout-valid.jsonl",
            "/tmp//rollout-valid.jsonl",
            "/tmp/rollout-valid.jsonl/",
            "/tmp/./rollout-valid.jsonl",
            "/tmp/../rollout-valid.jsonl",
        ] {
            #expect(!AgentChatTranscriptResolver.hasStrictRawPathComponents(rawPath))
        }
        #expect(
            resolver.codexTranscriptPath(recordedPath: valid.path, sessionID: noFallbackSession)
                == valid.resolvingSymlinksInPath().path
        )
        #expect(
            resolver.codexTranscriptPath(
                recordedPath: "~/.codex/sessions/2026/07/17/rollout-valid.jsonl",
                sessionID: noFallbackSession
            ) == nil
        )
        #expect(
            resolver.codexTranscriptPath(
                recordedPath: "~user/.codex/sessions/2026/07/17/rollout-valid.jsonl",
                sessionID: noFallbackSession
            ) == nil
        )
        #expect(
            resolver.codexTranscriptPath(
                recordedPath: "/" + valid.path,
                sessionID: noFallbackSession
            ) == nil
        )
        #expect(
            resolver.codexTranscriptPath(
                recordedPath: valid.path + "/",
                sessionID: noFallbackSession
            ) == nil
        )
        #expect(resolver.codexTranscriptPath(recordedPath: insideSymlink.path, sessionID: noFallbackSession) == nil)
        #expect(
            resolver.codexTranscriptPath(
                recordedPath: intermediateSymlinkTarget.path,
                sessionID: noFallbackSession
            ) == nil
        )
        #expect(resolver.codexTranscriptPath(recordedPath: outside.path, sessionID: noFallbackSession) == nil)
        #expect(resolver.codexTranscriptPath(recordedPath: sibling.path, sessionID: noFallbackSession) == nil)
        #expect(resolver.codexTranscriptPath(recordedPath: escapeSymlink.path, sessionID: noFallbackSession) == nil)
        #expect(resolver.codexTranscriptPath(recordedPath: directoryTarget.path, sessionID: noFallbackSession) == nil)
        #expect(resolver.codexTranscriptPath(recordedPath: fifoTarget.path, sessionID: noFallbackSession) == nil)
        #expect(resolver.codexTranscriptPath(recordedPath: wrongExtension.path, sessionID: noFallbackSession) == nil)
        #expect(
            resolver.codexTranscriptPath(
                recordedPath: sessionsRoot.path + "/../../outside/rollout-outside.jsonl",
                sessionID: noFallbackSession
            ) == nil
        )
        #expect(
            resolver.codexTranscriptPath(
                recordedPath: nestedDirectory.path + "//rollout-valid.jsonl",
                sessionID: noFallbackSession
            ) == nil
        )
        #expect(
            resolver.codexTranscriptPath(
                recordedPath: nestedDirectory.path + "/./rollout-valid.jsonl",
                sessionID: noFallbackSession
            ) == nil
        )
        #expect(
            resolver.codexTranscriptPath(
                recordedPath: "2026/07/17/rollout-valid.jsonl",
                sessionID: noFallbackSession
            ) == nil
        )
        #expect(
            resolver.codexTranscriptPath(
                recordedPath: nestedDirectory.appendingPathComponent("missing.jsonl").path,
                sessionID: noFallbackSession
            ) == nil
        )

        let wrongMetadata = nestedDirectory.appendingPathComponent("rollout-wrong-metadata.jsonl")
        try [
            #"{"type":"session_meta","payload":{"id":"different-session"}}"#,
            #"{"type":"turn_context","payload":{"turn_id":"expected-turn"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"wrong session"}],"internal_chat_message_metadata_passthrough":{"turn_id":"expected-turn"}}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"expected-turn"}}"#,
        ].joined(separator: "\n").appending("\n").write(
            to: wrongMetadata,
            atomically: true,
            encoding: .utf8
        )
        #expect(
            await resolver.recoverCodexFinalReply(
                recordedPath: wrongMetadata.path,
                sessionID: "expected-session",
                turnID: "expected-turn"
            ) == nil
        )
    }

    @Test func trustedOpenRejectsLeafReplacementBeforeOpenAndClosesDescriptors() async throws {
        let fixture = try trustedCodexFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let original = fixture.transcript
        let moved = original.deletingLastPathComponent().appendingPathComponent("moved-original.jsonl")
        let replacement = codexTranscriptText(
            sessionID: fixture.sessionID,
            turnID: fixture.turnID,
            finalReply: "replacement must not be read"
        )
        let events = TrustedOpenEventRecorder()
        let resolver = AgentChatTranscriptResolver(
            homeDirectory: fixture.home,
            environment: [:],
            trustedOpenCheckpoint: { checkpoint in
                events.record(checkpoint)
                guard checkpoint == .beforeOpeningLeaf else { return }
                try! FileManager.default.moveItem(at: original, to: moved)
                try! replacement.write(to: original, atomically: false, encoding: .utf8)
            }
        )

        let recovered = await resolver.recoverCodexFinalReply(
            recordedPath: original.path,
            sessionID: fixture.sessionID,
            turnID: fixture.turnID
        )

        #expect(recovered == nil)
        #expect(events.count(of: .didCloseDescriptor) == 5)
    }

    @Test func trustedOpenRejectsIntermediateReplacementWithOutsideSymlink() async throws {
        let fixture = try trustedCodexFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let sessionsRoot = fixture.home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let year = sessionsRoot.appendingPathComponent("2026", isDirectory: true)
        let movedYear = sessionsRoot.appendingPathComponent("held-2026", isDirectory: true)
        let outside = fixture.home.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let events = TrustedOpenEventRecorder()
        let resolver = AgentChatTranscriptResolver(
            homeDirectory: fixture.home,
            environment: [:],
            trustedOpenCheckpoint: { checkpoint in
                events.record(checkpoint)
                guard checkpoint == .beforeOpeningIntermediate(0) else { return }
                try! FileManager.default.moveItem(at: year, to: movedYear)
                try! FileManager.default.createSymbolicLink(at: year, withDestinationURL: outside)
            }
        )

        let recovered = await resolver.recoverCodexFinalReply(
            recordedPath: fixture.transcript.path,
            sessionID: fixture.sessionID,
            turnID: fixture.turnID
        )

        #expect(recovered == nil)
        #expect(events.count(of: .didCloseDescriptor) == 1)
    }

    @Test func trustedOpenRejectsLeafReplacementWithFIFOWithoutBlocking() async throws {
        let fixture = try trustedCodexFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let original = fixture.transcript
        let moved = original.deletingLastPathComponent().appendingPathComponent("fifo-original.jsonl")
        let events = TrustedOpenEventRecorder()
        let resolver = AgentChatTranscriptResolver(
            homeDirectory: fixture.home,
            environment: [:],
            trustedOpenCheckpoint: { checkpoint in
                events.record(checkpoint)
                guard checkpoint == .beforeOpeningLeaf else { return }
                try! FileManager.default.moveItem(at: original, to: moved)
                precondition(Darwin.mkfifo(original.path, S_IRUSR | S_IWUSR) == 0)
            }
        )

        let recovered = await resolver.recoverCodexFinalReply(
            recordedPath: original.path,
            sessionID: fixture.sessionID,
            turnID: fixture.turnID
        )

        #expect(recovered == nil)
        #expect(events.count(of: .didCloseDescriptor) == 5)
    }

    @Test func openedLeafDescriptorSurvivesOutsideSymlinkReplacement() async throws {
        let fixture = try trustedCodexFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let original = fixture.transcript
        let moved = original.deletingLastPathComponent().appendingPathComponent("opened-original.jsonl")
        let outside = fixture.home.appendingPathComponent("outside.jsonl")
        try codexTranscriptText(
            sessionID: fixture.sessionID,
            turnID: fixture.turnID,
            finalReply: "outside replacement"
        ).write(to: outside, atomically: false, encoding: .utf8)
        let events = TrustedOpenEventRecorder()
        let resolver = AgentChatTranscriptResolver(
            homeDirectory: fixture.home,
            environment: [:],
            trustedOpenCheckpoint: { checkpoint in
                events.record(checkpoint)
                guard checkpoint == .afterOpeningLeaf else { return }
                try! FileManager.default.moveItem(at: original, to: moved)
                try! FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
            }
        )

        let recovered = await resolver.recoverCodexFinalReply(
            recordedPath: original.path,
            sessionID: fixture.sessionID,
            turnID: fixture.turnID
        )

        #expect(recovered?.body == fixture.finalReply)
        #expect(events.count(of: .didCloseDescriptor) == 5)
    }

    @Test func openedIntermediateDescriptorSurvivesPathReplacement() async throws {
        let fixture = try trustedCodexFixture()
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let sessionsRoot = fixture.home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let year = sessionsRoot.appendingPathComponent("2026", isDirectory: true)
        let movedYear = sessionsRoot.appendingPathComponent("opened-2026", isDirectory: true)
        let outside = fixture.home.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let events = TrustedOpenEventRecorder()
        let resolver = AgentChatTranscriptResolver(
            homeDirectory: fixture.home,
            environment: [:],
            trustedOpenCheckpoint: { checkpoint in
                events.record(checkpoint)
                guard checkpoint == .afterOpeningIntermediate(0) else { return }
                try! FileManager.default.moveItem(at: year, to: movedYear)
                try! FileManager.default.createSymbolicLink(at: year, withDestinationURL: outside)
            }
        )

        let recovered = await resolver.recoverCodexFinalReply(
            recordedPath: fixture.transcript.path,
            sessionID: fixture.sessionID,
            turnID: fixture.turnID
        )

        #expect(recovered?.body == fixture.finalReply)
        #expect(events.count(of: .didCloseDescriptor) == 5)
    }

    @Test func transcriptAndJSONLRecordLimitsFailClosedAtByteBoundaries() async throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".codex/sessions/2026/07/17", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionID = "resource-session"
        let smallLimits = AgentReportResourceLimits(
            maximumReportBodyBytes: 64,
            maximumJSONLRecordBytes: 128,
            maximumTranscriptBytes: 1_024,
            maximumAuthorizedSocketFrameBytes: 256
        )
        let resolver = AgentChatTranscriptResolver(
            homeDirectory: home,
            environment: [:],
            reportResourceLimits: smallLimits
        )

        let belowTranscript = directory.appendingPathComponent("below-transcript.jsonl")
        let aboveTranscript = directory.appendingPathComponent("above-transcript.jsonl")
        try writePrimaryTranscript(
            to: belowTranscript,
            sessionID: sessionID,
            totalBytes: smallLimits.maximumTranscriptBytes - 1,
            maximumRecordBytes: smallLimits.maximumJSONLRecordBytes
        )
        try writePrimaryTranscript(
            to: aboveTranscript,
            sessionID: sessionID,
            totalBytes: smallLimits.maximumTranscriptBytes + 1,
            maximumRecordBytes: smallLimits.maximumJSONLRecordBytes
        )
        #expect(await resolver.validatePrimaryCodexSession(
            recordedPath: belowTranscript.path,
            sessionID: sessionID
        ) != nil)
        #expect(await resolver.validatePrimaryCodexSession(
            recordedPath: aboveTranscript.path,
            sessionID: sessionID
        ) == nil)

        let productionRecordLimit = AgentReportResourceLimits.sliceA.maximumJSONLRecordBytes
        let recordResolver = AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        let belowRecord = directory.appendingPathComponent("below-record.jsonl")
        let aboveTerminatedRecord = directory.appendingPathComponent("above-terminated-record.jsonl")
        let aboveUnterminatedRecord = directory.appendingPathComponent("above-unterminated-record.jsonl")
        try writeRecordBoundaryTranscript(
            to: belowRecord,
            sessionID: sessionID,
            recordBytes: productionRecordLimit - 1,
            terminated: true
        )
        try writeRecordBoundaryTranscript(
            to: aboveTerminatedRecord,
            sessionID: sessionID,
            recordBytes: productionRecordLimit + 1,
            terminated: true
        )
        try writeRecordBoundaryTranscript(
            to: aboveUnterminatedRecord,
            sessionID: sessionID,
            recordBytes: productionRecordLimit + 1,
            terminated: false
        )
        #expect(await recordResolver.validatePrimaryCodexSession(
            recordedPath: belowRecord.path,
            sessionID: sessionID
        ) != nil)
        #expect(await recordResolver.validatePrimaryCodexSession(
            recordedPath: aboveTerminatedRecord.path,
            sessionID: sessionID
        ) == nil)
        #expect(await recordResolver.validatePrimaryCodexSession(
            recordedPath: aboveUnterminatedRecord.path,
            sessionID: sessionID
        ) == nil)
    }

    @Test func cumulativeTranscriptGrowthAfterOpenIsRejected() async throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let transcript = home
            .appendingPathComponent(".codex/sessions/2026/07/17", isDirectory: true)
            .appendingPathComponent("growing.jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sessionID = "growing-session"
        let limits = AgentReportResourceLimits(
            maximumReportBodyBytes: 64,
            maximumJSONLRecordBytes: 256,
            maximumTranscriptBytes: 1_024,
            maximumAuthorizedSocketFrameBytes: 256
        )
        try writePrimaryTranscript(
            to: transcript,
            sessionID: sessionID,
            totalBytes: 512,
            maximumRecordBytes: limits.maximumJSONLRecordBytes
        )
        let resolver = AgentChatTranscriptResolver(
            homeDirectory: home,
            environment: [:],
            reportResourceLimits: limits,
            trustedOpenCheckpoint: { checkpoint in
                guard checkpoint == .beforeReadingFirstChunk,
                      let handle = try? FileHandle(forWritingTo: transcript) else {
                    return
                }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(repeating: 0x20, count: 600))
                try? handle.close()
            }
        )

        #expect(await resolver.validatePrimaryCodexSession(
            recordedPath: transcript.path,
            sessionID: sessionID
        ) == nil)
    }

    @MainActor
    @Test func relaunchOnlyPlaceholderCannotBecomeResumeSessionIdentity() {
        #expect(!AgentChatTranscriptService.isValidResumeSessionID(""))
        #expect(!AgentChatTranscriptService.isValidResumeSessionID("  \n"))
        #expect(AgentChatTranscriptService.isValidResumeSessionID("upstream-session-id"))
    }

    @MainActor
    @Test func endedSessionListabilityRetriesTransientMissingTranscriptAfterRetryWindow() throws {
        let home = try temporaryHomeDirectory()
        var now = Date(timeIntervalSince1970: 260)
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            now: { now }
        )
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let transcriptURL = home
            .appendingPathComponent(".claude/projects/-Users-example-project", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")

        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionEnd,
            source: "claude",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: transcriptURL.path,
            cwd: "/Users/example/project",
            ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 260)
        ))
        let initiallyMissingRecord = try #require(service.sessionRecord(sessionID: sessionID))
        #expect(!service.shouldListEndedSession(initiallyMissingRecord))

        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)

        let resolvedRecord = try #require(service.sessionRecord(sessionID: sessionID))
        now = Date(timeIntervalSince1970: 264)
        #expect(!service.shouldListEndedSession(resolvedRecord))
        now = Date(timeIntervalSince1970: 266)
        #expect(service.shouldListEndedSession(resolvedRecord))
    }

    @Test func endedListabilityCacheRefreshesExpiredMissingTranscript() throws {
        let home = try temporaryHomeDirectory()
        let resolver = AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptURL = home
            .appendingPathComponent(".claude/projects/-Users-example-project", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")
        let record = AgentChatSessionRecord(
            sessionID: sessionID,
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: UUID().uuidString,
            workingDirectory: "/Users/example/project",
            transcriptPath: transcriptURL.path,
            state: .ended,
            endedAt: Date(timeIntervalSince1970: 10),
            lastActivityAt: Date(timeIntervalSince1970: 10),
            title: nil,
            pid: nil,
            hookStoreSessionID: nil
        )
        var cache = AgentChatEndedTranscriptListabilityCache()

        let initiallyListable = cache.shouldList(
            record,
            resolver: resolver,
            now: Date(timeIntervalSince1970: 10)
        )
        #expect(!initiallyListable)

        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)

        let beforeRetryWindowListable = cache.shouldList(
            record,
            resolver: resolver,
            now: Date(timeIntervalSince1970: 14)
        )
        #expect(!beforeRetryWindowListable)

        let eventuallyListable = cache.shouldList(
            record,
            resolver: resolver,
            now: Date(timeIntervalSince1970: 16)
        )
        #expect(eventuallyListable)
    }

    @MainActor
    @Test func observeScanDoesNotReviveEndedRecordForSamePID() throws {
        let registry = AgentChatSessionRegistry()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            ppid: 303,
            receivedAt: Date(timeIntervalSince1970: 20)
        ))
        registry.update(sessionID: sessionID) { record in
            record.state = .ended
            record.pid = 303
        }
        let ended = try #require(registry.record(sessionID: sessionID))
        let observed = ObservedAgentSession(
            sessionID: sessionID,
            agentKind: .claude,
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            pid: 303,
            workingDirectory: "/Users/example/project",
            transcriptPath: nil,
            sampledAt: Date(timeIntervalSince1970: 30)
        )

        let revived = registry.reviveEndedObservedSessionIfNeeded(
            current: ended,
            observed: observed,
            now: Date(timeIntervalSince1970: 31)
        )

        #expect(!revived)
        #expect(registry.record(sessionID: sessionID)?.state == .ended)
    }

    @MainActor
    @Test func unlistableEndedSessionPushesRemovalInsteadOfEndedDescriptor() throws {
        let home = try temporaryHomeDirectory()
        let coding = ChatWireCoding()
        var emitted: [ChatSessionEventFrame] = []
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:]),
            hasEventSubscribers: { true },
            emitEventPayload: { payload in
                guard let data = try? JSONSerialization.data(withJSONObject: payload),
                      let frame = try? coding.decode(ChatSessionEventFrame.self, from: data) else {
                    return
                }
                emitted.append(frame)
            }
        )
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let missingTranscript = home
            .appendingPathComponent(".claude/projects/-Users-example-project", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")

        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: missingTranscript.path,
            cwd: "/Users/example/project",
            ppid: 111,
            receivedAt: Date(timeIntervalSince1970: 270)
        ))
        emitted.removeAll()
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionEnd,
            source: "claude",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: missingTranscript.path,
            cwd: "/Users/example/project",
            ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 271)
        ))

        #expect(emitted.contains { frame in
            guard case .sessionRemoved = frame.event else { return false }
            return frame.sessionID == sessionID
        })
        #expect(!emitted.contains { frame in
            guard case .stateChanged(.ended) = frame.event else { return false }
            return frame.sessionID == sessionID
        })
        #expect(!emitted.contains { frame in
            guard case .descriptorChanged(let descriptor) = frame.event else { return false }
            return frame.sessionID == sessionID && descriptor.state == .ended
        })
    }

    @MainActor
    @Test func endedCodexSessionPushesEndedStateInsteadOfRemoval() throws {
        let coding = ChatWireCoding()
        var emitted: [ChatSessionEventFrame] = []
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { true },
            emitEventPayload: { payload in
                guard let data = try? JSONSerialization.data(withJSONObject: payload),
                      let frame = try? coding.decode(ChatSessionEventFrame.self, from: data) else {
                    return
                }
                emitted.append(frame)
            }
        )
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString

        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionStart,
            source: "codex",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            ppid: 111,
            receivedAt: Date(timeIntervalSince1970: 280)
        ))
        emitted.removeAll()
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionEnd,
            source: "codex",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 281)
        ))

        #expect(!emitted.contains { frame in
            guard case .sessionRemoved = frame.event else { return false }
            return frame.sessionID == sessionID
        })
        #expect(emitted.contains { frame in
            guard case .stateChanged(.ended) = frame.event else { return false }
            return frame.sessionID == sessionID
        })
    }

    private func trustedCodexFixture() throws -> (
        home: URL,
        transcript: URL,
        sessionID: String,
        turnID: String,
        finalReply: String
    ) {
        let home = try temporaryHomeDirectory()
        let transcript = home
            .appendingPathComponent(".codex/sessions/2026/07/17", isDirectory: true)
            .appendingPathComponent("rollout-fixture.jsonl")
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sessionID = "descriptor-session"
        let turnID = "descriptor-turn"
        let finalReply = "descriptor-pinned exact reply"
        try codexTranscriptText(
            sessionID: sessionID,
            turnID: turnID,
            finalReply: finalReply
        ).write(to: transcript, atomically: false, encoding: .utf8)
        return (home, transcript, sessionID, turnID, finalReply)
    }

    private func rawTranscriptFixture(fileName: String) throws -> (
        home: URL,
        transcript: URL,
        sessionID: String
    ) {
        let home = try temporaryHomeDirectory()
        let transcript = home
            .appendingPathComponent(".codex/sessions/2026/07/17", isDirectory: true)
            .appendingPathComponent(fileName)
        try FileManager.default.createDirectory(
            at: transcript.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return (home, transcript, "invalid-utf8-session")
    }

    private func appendJSONLLine(_ line: String, to data: inout Data) {
        data.append(contentsOf: line.utf8)
        data.append(0x0A)
    }

    private func appendInvalidUTF8JSONRecord(terminated: Bool, to data: inout Data) {
        data.append(contentsOf: #"{"type":"event_msg","payload":{"type":"status","message":""#.utf8)
        data.append(0xFF)
        data.append(contentsOf: #""}}"#.utf8)
        if terminated {
            data.append(0x0A)
        }
    }

    private func finalReplyLine(text: String, turnID: String?) -> String {
        let metadata = turnID.map {
            #", "internal_chat_message_metadata_passthrough":{"turn_id":"\#($0)"}"#
        } ?? ""
        return #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"\#(text)"}]\#(metadata)}}"#
    }

    private func codexTranscriptText(
        sessionID: String,
        turnID: String,
        finalReply: String
    ) -> String {
        [
            #"{"type":"session_meta","payload":{"id":"\#(sessionID)"}}"#,
            #"{"type":"turn_context","payload":{"turn_id":"\#(turnID)"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer","content":[{"type":"output_text","text":"\#(finalReply)"}],"internal_chat_message_metadata_passthrough":{"turn_id":"\#(turnID)"}}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"\#(turnID)"}}"#,
        ].joined(separator: "\n") + "\n"
    }

    private func writePrimaryTranscript(
        to url: URL,
        sessionID: String,
        totalBytes: Int,
        maximumRecordBytes: Int
    ) throws {
        let header = Data(
            (#"{"type":"session_meta","payload":{"id":"\#(sessionID)"}}"# + "\n").utf8
        )
        var data = header
        while data.count < totalBytes {
            let remaining = totalBytes - data.count
            if remaining == 1 {
                data.append(0x0A)
                continue
            }
            let framedBytes = min(remaining, maximumRecordBytes + 1)
            let recordBytes = framedBytes - 1
            if recordBytes == 1 {
                data.append(0x30)
            } else {
                data.append(contentsOf: Data("{}".utf8))
                if recordBytes > 2 {
                    data.append(contentsOf: Data(repeating: 0x20, count: recordBytes - 2))
                }
            }
            data.append(0x0A)
        }
        try data.write(to: url)
    }

    private func writeRecordBoundaryTranscript(
        to url: URL,
        sessionID: String,
        recordBytes: Int,
        terminated: Bool
    ) throws {
        var data = Data(
            (#"{"type":"session_meta","payload":{"id":"\#(sessionID)"}}"# + "\n").utf8
        )
        data.append(contentsOf: Data(repeating: 0x20, count: recordBytes))
        if terminated {
            data.append(0x0A)
        }
        try data.write(to: url)
    }

    private func temporaryHomeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Synchronous test checkpoints cross a detached reader task; this tiny lock
/// records immutable enum values without exposing transcript or report data.
private final class TrustedOpenEventRecorder: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock(
        initialState: [AgentChatTranscriptResolver.TrustedOpenCheckpoint]()
    )

    func record(_ checkpoint: AgentChatTranscriptResolver.TrustedOpenCheckpoint) {
        storage.withLock { $0.append(checkpoint) }
    }

    func count(of checkpoint: AgentChatTranscriptResolver.TrustedOpenCheckpoint) -> Int {
        storage.withLock { events in events.filter { $0 == checkpoint }.count }
    }
}
