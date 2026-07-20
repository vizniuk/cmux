import Foundation
import Testing
import Darwin
import CMUXAgentLaunch

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AgentChatSessionRegistryHookStoreTests {
    @Test func mobileChatObserverDetectsCmuxLaunchedOpaqueClaudeWrapper() throws {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 121,
                    name: "node",
                    path: "/opt/homebrew/bin/node",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 115),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { pid in
                guard pid == 121 else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "node",
                        "/Users/example/.cmux-agent-wrapper/subrouter.js",
                    ],
                    environment: [
                        "CMUX_AGENT_LAUNCH_KIND": "claude",
                        "CLAUDE_CODE_SESSION_ID": sessionID,
                        "CMUX_AGENT_LAUNCH_CWD": "/Users/example/opaque-project",
                    ]
                )
            },
            codexRolloutPath: { _ in nil }
        )

        let session = try #require(observed.first)
        #expect(observed.count == 1)
        #expect(session.sessionID == sessionID)
        #expect(session.agentKind == .claude)
        #expect(session.workspaceID == workspaceID.uuidString)
        #expect(session.surfaceID == surfaceID.uuidString)
        #expect(session.pid == 121)
        #expect(session.workingDirectory == "/Users/example/opaque-project")
    }

    @Test func unidentifiedClaudeLivenessFallbackOnlyAppliesToUnresolvedPendingAlias() {
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let now = Date(timeIntervalSince1970: 120)
        var pending = AgentChatSessionRecord(
            sessionID: pendingID,
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            workingDirectory: nil,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: now,
            title: nil,
            pid: nil
        )

        #expect(AgentChatSessionRegistry.allowsUnidentifiedClaudeLivenessFallback(for: pending))

        pending.rememberHookStoreSessionID(realSessionID)
        #expect(!AgentChatSessionRegistry.allowsUnidentifiedClaudeLivenessFallback(for: pending))

        let real = AgentChatSessionRecord(
            sessionID: realSessionID,
            agentKind: .claude,
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            workingDirectory: nil,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: now,
            title: nil,
            pid: nil
        )
        #expect(!AgentChatSessionRegistry.allowsUnidentifiedClaudeLivenessFallback(for: real))
    }

    @Test func mobileChatObserverRejectsArgvOnlyClaudeNeedleWithoutLaunchKind() {
        let workspaceID = UUID()
        let surfaceID = UUID()
        let sessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let snapshot = CmuxTopProcessSnapshot(
            processes: [
                topProcess(
                    pid: 122,
                    name: "node",
                    path: "/opt/homebrew/bin/node",
                    workspaceID: workspaceID,
                    surfaceID: surfaceID
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 116),
            includesProcessDetails: true
        )

        let observed = AgentChatSessionRegistry.scanObservedAgentSessions(
            in: snapshot,
            processArgumentsAndEnvironment: { pid in
                guard pid == 122 else { return nil }
                return CmuxTopProcessArguments(
                    arguments: [
                        "node",
                        "/Users/example/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js",
                    ],
                    environment: [
                        "CLAUDE_CODE_SESSION_ID": sessionID,
                        "CMUX_AGENT_LAUNCH_CWD": "/Users/example/not-authoritative",
                    ]
                )
            },
            codexRolloutPath: { _ in nil }
        )

        #expect(observed.isEmpty)
    }

    @MainActor
    @Test func hookStoreSeedKeepsStaleRealEntrySeparateFromPendingClaudeSession() async throws {
        let home = try temporaryHomeDirectory()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/\(realSessionID).jsonl"
        let stalePID = try #require(guaranteedDeadPID())
        try writeClaudeHookStore(
            home: home,
            sessionID: realSessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            transcriptPath: transcriptPath,
            pid: stalePID
        )
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )

        registry.noteResumeInitiated(
            sessionID: pendingID,
            source: "claude",
            surfaceID: surfaceID,
            workspaceID: workspaceID,
            workingDirectory: "/Users/example/project"
        )
        await registry.seedFromHookStores(agentSources: ["claude"])

        let pending = try #require(registry.record(sessionID: pendingID))
        let historical = try #require(registry.record(sessionID: realSessionID))
        #expect(pending.transcriptPath == nil)
        #expect(pending.hookStoreSessionID == nil)
        #expect(historical.transcriptPath == transcriptPath)
        #expect(historical.state == .ended)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == pendingID)
    }

    @MainActor
    @Test func hookStoreSeedMergesPidMatchedRealEntryIntoPendingClaudeSession() async throws {
        let home = try temporaryHomeDirectory()
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let pendingID = AgentChatSessionRegistry.pendingClaudeSessionID(surfaceID: surfaceID)
        let realSessionID = "24ec0052-450c-4914-b1dd-2ee80d4bc84b"
        let transcriptPath = "/Users/example/.claude/projects/-Users-example-project/\(realSessionID).jsonl"
        let livePID = Int(ProcessInfo.processInfo.processIdentifier)
        try writeClaudeHookStore(
            home: home,
            sessionID: realSessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            transcriptPath: transcriptPath,
            pid: livePID
        )
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )

        registry.applyObservedSessions([
            ObservedAgentSession(
                sessionID: pendingID,
                agentKind: .claude,
                surfaceID: surfaceID,
                workspaceID: workspaceID,
                pid: livePID,
                workingDirectory: "/Users/example/project",
                transcriptPath: nil
            ),
        ])
        await registry.seedFromHookStores(agentSources: ["claude"])

        let record = try #require(registry.record(sessionID: pendingID))
        #expect(registry.record(sessionID: realSessionID) == nil)
        #expect(record.hookStoreSessionID == realSessionID)
        #expect(record.transcriptPath == transcriptPath)
        #expect(record.pid == livePID)
        #expect(registry.liveSession(surfaceID: surfaceID)?.sessionID == pendingID)
    }

    @MainActor
    @Test func exactCodexReportBindingRequiresLiveWorkspaceSurfaceSessionAndTurn() async throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let sessionID = "synthetic-codex-session"
        let turnID = "synthetic-turn"
        let transcriptPath = home.appendingPathComponent("synthetic-rollout.jsonl").path
        try writeCodexHookStore(
            home: home,
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            transcriptPath: transcriptPath,
            lastPromptTurnID: turnID
        )
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )
        _ = registry.noteHookEvent(WorkstreamEvent(
            sessionId: "codex-\(sessionID)",
            hookEventName: .stop,
            source: "codex",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: transcriptPath
        ))

        let accepted = await registry.agentReportCaptureBinding(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            sessionID: sessionID,
            turnID: turnID,
            requestedTranscriptPath: transcriptPath
        )

        #expect(accepted?.transcriptPath == transcriptPath)
        #expect(await registry.agentReportCaptureBinding(
            workspaceID: UUID().uuidString,
            surfaceID: surfaceID,
            sessionID: sessionID,
            turnID: turnID,
            requestedTranscriptPath: transcriptPath
        ) == nil)
        #expect(await registry.agentReportCaptureBinding(
            workspaceID: workspaceID,
            surfaceID: UUID().uuidString,
            sessionID: sessionID,
            turnID: turnID,
            requestedTranscriptPath: transcriptPath
        ) == nil)
        #expect(await registry.agentReportCaptureBinding(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            sessionID: "other-session",
            turnID: turnID,
            requestedTranscriptPath: transcriptPath
        ) == nil)
        #expect(await registry.agentReportCaptureBinding(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            sessionID: sessionID,
            turnID: "stale-turn",
            requestedTranscriptPath: transcriptPath
        ) == nil)
        #expect(await registry.agentReportCaptureBinding(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            sessionID: sessionID,
            turnID: turnID,
            requestedTranscriptPath: home.appendingPathComponent("other-session.jsonl").path
        ) == nil)
    }

    @MainActor
    @Test func reportCopyBindingSeparatesCaptureWorkspaceFromDisplayWorkspace() async throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let captureWorkspaceID = UUID().uuidString
        let displayWorkspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let sessionID = "synthetic-transferred-session"
        let turnID = "synthetic-transferred-turn"
        let transcriptPath = home.appendingPathComponent("transferred-rollout.jsonl").path
        try writeCodexHookStore(
            home: home,
            sessionID: sessionID,
            workspaceID: captureWorkspaceID,
            surfaceID: surfaceID,
            transcriptPath: transcriptPath,
            lastPromptTurnID: turnID
        )
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )
        _ = registry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .stop,
            source: "codex",
            workspaceId: captureWorkspaceID,
            surfaceId: surfaceID,
            transcriptPath: transcriptPath
        ))
        let service = AgentChatTranscriptService(registry: registry)

        #expect(await registry.agentReportCaptureBinding(
            workspaceID: captureWorkspaceID,
            surfaceID: surfaceID,
            sessionID: sessionID,
            turnID: turnID,
            requestedTranscriptPath: transcriptPath
        ) != nil)

        service.updateSessionWorkspace(sessionID: sessionID, workspaceID: displayWorkspaceID)
        service.updateSessionWorkspace(sessionID: sessionID, workspaceID: displayWorkspaceID)
        #expect(service.sessionRecord(sessionID: sessionID)?.workspaceID == displayWorkspaceID)
        #expect(await registry.agentReportCaptureBinding(
            workspaceID: captureWorkspaceID,
            surfaceID: surfaceID,
            sessionID: sessionID,
            turnID: turnID,
            requestedTranscriptPath: transcriptPath
        ) == nil)
        #expect(await registry.agentReportCopyBinding(
            captureWorkspaceID: captureWorkspaceID,
            surfaceID: surfaceID,
            sessionID: sessionID,
            turnID: turnID
        )?.transcriptPath == transcriptPath)

        #expect(await registry.agentReportCopyBinding(
            captureWorkspaceID: displayWorkspaceID,
            surfaceID: surfaceID,
            sessionID: sessionID,
            turnID: turnID
        ) == nil)
        #expect(await registry.agentReportCopyBinding(
            captureWorkspaceID: captureWorkspaceID,
            surfaceID: UUID().uuidString,
            sessionID: sessionID,
            turnID: turnID
        ) == nil)
        #expect(await registry.agentReportCopyBinding(
            captureWorkspaceID: captureWorkspaceID,
            surfaceID: surfaceID,
            sessionID: "different-session",
            turnID: turnID
        ) == nil)
        #expect(await registry.agentReportCopyBinding(
            captureWorkspaceID: captureWorkspaceID,
            surfaceID: surfaceID,
            sessionID: sessionID,
            turnID: "different-turn"
        ) == nil)

        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .sessionEnd,
            source: "codex",
            workspaceId: displayWorkspaceID,
            surfaceId: surfaceID,
            transcriptPath: transcriptPath
        ))
        #expect(await registry.agentReportCopyBinding(
            captureWorkspaceID: captureWorkspaceID,
            surfaceID: surfaceID,
            sessionID: sessionID,
            turnID: turnID
        ) == nil)

        let wrongProviderRegistry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )
        _ = wrongProviderRegistry.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .stop,
            source: "claude",
            workspaceId: displayWorkspaceID,
            surfaceId: surfaceID,
            transcriptPath: transcriptPath
        ))
        #expect(await wrongProviderRegistry.agentReportCopyBinding(
            captureWorkspaceID: captureWorkspaceID,
            surfaceID: surfaceID,
            sessionID: sessionID,
            turnID: turnID
        ) == nil)
    }

    @MainActor
    @Test func codexResumeRebindPreventsCaptureOnOldSurface() async throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let workspaceID = UUID().uuidString
        let oldSurfaceID = UUID().uuidString
        let newSurfaceID = UUID().uuidString
        let sessionID = "synthetic-resumed-session"
        let turnID = "resumed-turn"
        let transcriptPath = home.appendingPathComponent("resumed-rollout.jsonl").path
        try writeCodexHookStore(
            home: home,
            sessionID: sessionID,
            workspaceID: workspaceID,
            surfaceID: oldSurfaceID,
            transcriptPath: transcriptPath,
            lastPromptTurnID: turnID
        )
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )
        registry.noteResumeInitiated(
            sessionID: sessionID,
            source: "codex",
            surfaceID: oldSurfaceID,
            workspaceID: workspaceID,
            workingDirectory: home.path
        )
        registry.noteResumeInitiated(
            sessionID: sessionID,
            source: "codex",
            surfaceID: newSurfaceID,
            workspaceID: workspaceID,
            workingDirectory: home.path
        )

        #expect(await registry.agentReportCaptureBinding(
            workspaceID: workspaceID,
            surfaceID: oldSurfaceID,
            sessionID: sessionID,
            turnID: turnID,
            requestedTranscriptPath: transcriptPath
        ) == nil)
    }

    @MainActor
    @Test func historicalCodexEntryCannotCaptureWhenAnotherSessionOwnsActiveSurfaceBoundary() async throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let oldSessionID = "synthetic-old-session"
        let currentSessionID = "synthetic-current-session"
        let oldTurnID = "old-turn"
        let currentTurnID = "current-turn"
        let storeDirectory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "sessions": [
                oldSessionID: [
                    "workspaceId": workspaceID,
                    "surfaceId": surfaceID,
                    "lastPromptTurnId": oldTurnID,
                    "updatedAt": 100.0,
                ],
                currentSessionID: [
                    "workspaceId": workspaceID,
                    "surfaceId": surfaceID,
                    "lastPromptTurnId": currentTurnID,
                    "updatedAt": 200.0,
                ],
            ],
            "activeSessionsBySurface": [
                surfaceID: [
                    "sessionId": currentSessionID,
                    "turnId": currentTurnID,
                    "updatedAt": 200.0,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: storeDirectory.appendingPathComponent("codex-hook-sessions.json"))
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )

        #expect(await registry.agentReportCaptureBinding(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            sessionID: oldSessionID,
            turnID: oldTurnID,
            requestedTranscriptPath: nil
        ) == nil)
        #expect(await registry.agentReportCaptureBinding(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            sessionID: currentSessionID,
            turnID: currentTurnID,
            requestedTranscriptPath: nil
        ) != nil)
    }

    @MainActor
    @Test func managedChildFeedRecordCannotDisplaceParentPrivateCaptureBoundary() async throws {
        let home = try temporaryHomeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let parentSessionID = "synthetic-parent-feed-session"
        let parentTurnID = "parent-turn"
        try writeCodexHookStore(
            home: home,
            sessionID: parentSessionID,
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            transcriptPath: nil,
            lastPromptTurnID: parentTurnID
        )
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )
        _ = registry.noteHookEvent(WorkstreamEvent(
            sessionId: parentSessionID,
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: nil
        ))
        _ = registry.noteHookEvent(WorkstreamEvent(
            sessionId: "synthetic-managed-child-feed-session",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: workspaceID,
            surfaceId: surfaceID,
            transcriptPath: home.appendingPathComponent("managed-child-rollout.jsonl").path
        ))

        let binding = await registry.agentReportCaptureBinding(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            sessionID: parentSessionID,
            turnID: parentTurnID,
            requestedTranscriptPath: nil
        )
        #expect(binding != nil)
        #expect(binding?.transcriptPath == nil)
    }

    private func guaranteedDeadPID() -> Int? {
        for pid in 900_000..<1_000_000 {
            errno = 0
            if kill(pid_t(pid), 0) != 0, errno == ESRCH {
                return pid
            }
        }
        return nil
    }

    private func topProcess(
        pid: Int,
        name: String,
        path: String?,
        workspaceID: UUID,
        surfaceID: UUID
    ) -> CmuxTopProcessInfo {
        CmuxTopProcessInfo(
            pid: pid,
            parentPID: 1,
            name: name,
            path: path,
            ttyDevice: nil,
            cmuxWorkspaceID: workspaceID,
            cmuxSurfaceID: surfaceID,
            cmuxAttributionReason: "test",
            processGroupID: pid,
            terminalProcessGroupID: pid,
            cpuPercent: 0,
            residentBytes: 1,
            virtualBytes: 1,
            threadCount: 1
        )
    }

    private func temporaryHomeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-chat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeClaudeHookStore(
        home: URL,
        sessionID: String,
        workspaceID: String,
        surfaceID: String,
        transcriptPath: String?,
        pid: Int
    ) throws {
        let directory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "sessions": [
                sessionID: [
                    "workspaceId": workspaceID,
                    "surfaceId": surfaceID,
                    "cwd": "/Users/example/project",
                    "transcriptPath": (transcriptPath as Any?) ?? NSNull(),
                    "pid": pid,
                    "updatedAt": 140.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("claude-hook-sessions.json"))
    }

    private func writeCodexHookStore(
        home: URL,
        sessionID: String,
        workspaceID: String,
        surfaceID: String,
        transcriptPath: String?,
        lastPromptTurnID: String
    ) throws {
        let directory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var sessionEntry: [String: Any] = [
            "workspaceId": workspaceID,
            "surfaceId": surfaceID,
            "lastPromptTurnId": lastPromptTurnID,
            "updatedAt": 200.0,
        ]
        if let transcriptPath {
            sessionEntry["transcriptPath"] = transcriptPath
        }
        let payload: [String: Any] = [
            "sessions": [
                sessionID: sessionEntry,
            ],
            "activeSessionsBySurface": [
                surfaceID: [
                    "sessionId": sessionID,
                    "turnId": lastPromptTurnID,
                    "updatedAt": 200.0,
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("codex-hook-sessions.json"))
    }
}
