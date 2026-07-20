import AppKit
import CMUXAgentLaunch
import CmuxAgentChat
@testable import CmuxControlSocket
import CmuxCore
import Darwin
import Foundation
import Testing
import CmuxTerminal
import struct CmuxSettings.IntegrationsCatalogSection
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private func testComment(_ message: @autoclosure () -> String) -> Comment? {
    let value = message()
    return value.isEmpty ? nil : Comment(rawValue: value)
}

private func XCTAssertEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 == value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNotEqual<T: Equatable>(
    _ expression1: @autoclosure () throws -> T,
    _ expression2: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value1 = try expression1()
        let value2 = try expression2()
        #expect(value1 != value2, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertTrue(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(try expression(), testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertFalse(
    _ expression: @autoclosure () throws -> Bool,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let value = try expression()
        #expect(!value, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTAssertNil<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        #expect(try expression() == nil, testComment(message()), sourceLocation: sourceLocation)
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

private func XCTUnwrap<T>(
    _ expression: @autoclosure () throws -> T?,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> T {
    let value = try expression()
    return try #require(value, testComment(message()), sourceLocation: sourceLocation)
}

private func XCTFail(
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    Issue.record(Comment(rawValue: message()), sourceLocation: sourceLocation)
}

@MainActor
@Suite(.serialized)
final class TerminalControllerSocketSecurityTests {
    private var teardownBlocks: [() -> Void] = []

    @Test func browserDownloadQueueKeepsCompletionAfterPromptReadyEvent() {
        let controller = TerminalController.shared
        let surfaceId = UUID()
        controller.cleanupSurfaceState(surfaceIds: [surfaceId])
        defer { controller.cleanupSurfaceState(surfaceIds: [surfaceId]) }

        recordDownloadEvent("started", id: "download-1", surfaceId: surfaceId)
        recordDownloadEvent("ready_to_save", id: "download-1", surfaceId: surfaceId)

        let returned = controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId)
        XCTAssertEqual(returned?["type"] as? String, "ready_to_save")
        recordDownloadEvent("ready_to_save", id: "download-1", surfaceId: surfaceId)
        XCTAssertNil(controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId))
        recordDownloadEvent("saved", id: "download-1", surfaceId: surfaceId, path: "/tmp/report.csv")
        for index in 0...140 { recordDownloadEvent("started", id: "started-\(index)", surfaceId: surfaceId) }
        let saved = controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId); XCTAssertEqual(saved?["type"] as? String, "saved")
        XCTAssertEqual(saved?["path"] as? String, "/tmp/report.csv")
        XCTAssertNil(controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId))
    }

    @Test func browserDownloadQueuePrefersPromptedCompletionWhenAlreadyClosed() {
        let controller = TerminalController.shared
        let surfaceId = UUID()
        controller.cleanupSurfaceState(surfaceIds: [surfaceId])
        defer { controller.cleanupSurfaceState(surfaceIds: [surfaceId]) }

        recordDownloadEvent("started", id: "download-closed", surfaceId: surfaceId)
        recordDownloadEvent("ready_to_save", id: "download-closed", surfaceId: surfaceId)
        recordDownloadEvent("saved", id: "download-closed", surfaceId: surfaceId, path: "/tmp/report.csv")

        let returned = controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId)
        XCTAssertEqual(returned?["type"] as? String, "saved")
        XCTAssertEqual(returned?["path"] as? String, "/tmp/report.csv")
        XCTAssertNil(controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId))
    }

    @Test func browserDownloadConsumedIDRegistryIsBounded() {
        let controller = TerminalController.shared
        let surfaceId = UUID()
        controller.cleanupSurfaceState(surfaceIds: [surfaceId])
        defer { controller.cleanupSurfaceState(surfaceIds: [surfaceId]) }

        let oldestID = "download-0"
        let newestID = "download-140"
        for index in 0...140 {
            controller.v2MarkBrowserDownloadEventConsumed(
                ["type": "saved", "download_id": "download-\(index)"],
                surfaceId: surfaceId
            )
        }

        recordDownloadEvent("saved", id: oldestID, surfaceId: surfaceId)

        let returned = controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId)
        XCTAssertEqual(returned?["download_id"] as? String, oldestID)

        recordDownloadEvent("saved", id: newestID, surfaceId: surfaceId)

        XCTAssertNil(controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId))
    }

    @Test func browserDownloadEventQueueIsBounded() {
        let controller = TerminalController.shared
        let surfaceId = UUID()
        controller.cleanupSurfaceState(surfaceIds: [surfaceId])
        defer { controller.cleanupSurfaceState(surfaceIds: [surfaceId]) }

        for index in 0...140 {
            recordDownloadEvent(
                "ready_to_save",
                id: "download-\(index)",
                surfaceId: surfaceId,
                filename: "report-\(index).csv"
            )
        }

        var returnedIDs: [String] = []
        while let event = controller.v2PopBrowserDownloadEvent(surfaceId: surfaceId) {
            if let downloadID = event["download_id"] as? String {
                returnedIDs.append(downloadID)
            }
        }

        XCTAssertEqual(returnedIDs.count, 128)
        XCTAssertEqual(returnedIDs.first, "download-13")
        XCTAssertEqual(returnedIDs.last, "download-140")
    }

    private func recordDownloadEvent(
        _ type: String,
        id: String,
        surfaceId: UUID,
        filename: String = "report.csv",
        path: String? = nil
    ) {
        var event: [String: Any] = ["type": type, "download_id": id, "filename": filename]
        if let path {
            event["path"] = path
        }
        TerminalController.shared.v2RecordBrowserDownloadEvent(surfaceId: surfaceId, event: event)
    }

    init() {
        TerminalController.shared.stop()
    }

    deinit {
        teardownBlocks.forEach { $0() }
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("csec-\(name.prefix(4))-\(shortID).sock")
            .path
    }

    private func addTeardownBlock(_ block: @escaping () -> Void) {
        teardownBlocks.append(block)
    }

    @Test func testSocketPermissionsFollowAccessMode() throws {
        let tabManager = TabManager()

        let allowAllPath = makeSocketPath("allow-all")
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: allowAllPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: allowAllPath)
        XCTAssertEqual(try socketMode(at: allowAllPath), 0o666)

        TerminalController.shared.stop()

        let restrictedPath = makeSocketPath("cmux-only")
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: restrictedPath,
            accessMode: .cmuxOnly
        )
        try waitForSocket(at: restrictedPath)
        XCTAssertEqual(try socketMode(at: restrictedPath), 0o600)
    }

    @Test func testPasswordModeRejectsUnauthenticatedCommands() throws {
        let socketPath = makeSocketPath("password-mode")
        let tabManager = TabManager()

        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .password
        )
        try waitForSocket(at: socketPath)

        let pingOnly = try sendCommands(["ping"], to: socketPath)
        XCTAssertEqual(pingOnly.count, 1)
        XCTAssertTrue(pingOnly[0].hasPrefix("ERROR:"))
        XCTAssertFalse(pingOnly[0].localizedCaseInsensitiveContains("PONG"))

        let wrongAuthThenPing = try sendCommands(
            ["auth not-the-password", "ping"],
            to: socketPath
        )
        XCTAssertEqual(wrongAuthThenPing.count, 2)
        XCTAssertTrue(wrongAuthThenPing[0].hasPrefix("ERROR:"))
        XCTAssertTrue(wrongAuthThenPing[1].hasPrefix("ERROR:"))
    }

    @Test func testSocketCommandPolicyDistinguishesFocusIntent() throws {
#if DEBUG
        let nonFocus = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "ping",
            isV2: false
        )
        XCTAssertTrue(nonFocus.insideSuppressed)
        XCTAssertFalse(nonFocus.insideAllowsFocus)
        XCTAssertFalse(nonFocus.outsideSuppressed)
        XCTAssertFalse(nonFocus.outsideAllowsFocus)

        let focusV1 = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "focus_window",
            isV2: false
        )
        XCTAssertTrue(focusV1.insideSuppressed)
        XCTAssertTrue(focusV1.insideAllowsFocus)
        XCTAssertFalse(focusV1.outsideSuppressed)

        let focusV2 = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "workspace.select",
            isV2: true
        )
        XCTAssertTrue(focusV2.insideSuppressed)
        XCTAssertTrue(focusV2.insideAllowsFocus)
        XCTAssertFalse(focusV2.outsideSuppressed)

        let triggerFlash = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "surface.trigger_flash",
            isV2: true
        )
        XCTAssertTrue(triggerFlash.insideSuppressed)
        XCTAssertFalse(triggerFlash.insideAllowsFocus)

        let simulateShortcut = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "simulate_shortcut",
            isV2: false
        )
        XCTAssertTrue(simulateShortcut.insideSuppressed)
        XCTAssertFalse(simulateShortcut.insideAllowsFocus)

        let settingsOpen = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "settings.open",
            isV2: true
        )
        XCTAssertTrue(settingsOpen.insideSuppressed)
        XCTAssertFalse(settingsOpen.insideAllowsFocus)

        let feedbackOpen = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "feedback.open",
            isV2: true
        )
        XCTAssertTrue(feedbackOpen.insideSuppressed)
        XCTAssertFalse(feedbackOpen.insideAllowsFocus)

        let debugType = TerminalController.debugSocketCommandPolicySnapshot(
            commandKey: "debug.type",
            isV2: true
        )
        XCTAssertTrue(debugType.insideSuppressed)
        XCTAssertFalse(debugType.insideAllowsFocus)
#else
        return
#endif
    }

    @Test func testDebugTextBoxEndpointsRejectBlankSurfaceID() throws {
#if DEBUG
        TerminalController.shared.setActiveTabManager(TabManager())
        defer { TerminalController.shared.setActiveTabManager(nil) }

        let requests: [(method: String, params: [String: Any], id: Int)] = [
            ("debug.textbox.inline_fixture", ["surface_id": "   "], 1),
            ("debug.textbox.interact", ["surface_id": "   ", "action": "select"], 2)
        ]

        for request in requests {
            let payload: [String: Any] = [
                "jsonrpc": "2.0",
                "id": request.id,
                "method": request.method,
                "params": request.params
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            let line = try XCTUnwrap(String(data: data, encoding: .utf8))
            let responseText = TerminalController.shared.handleSocketLine(line)
            let responseData = try XCTUnwrap(responseText.data(using: .utf8))
            let response = try XCTUnwrap(
                JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                "Unexpected JSON-RPC response: \(responseText)"
            )
            XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
            let error = try XCTUnwrap(response["error"] as? [String: Any])
            XCTAssertEqual(error["code"] as? String, "invalid_params")
            XCTAssertEqual(error["message"] as? String, "surface_id cannot be empty")
        }
#else
        return
#endif
    }

    @Test func testRemoteStatusPayloadOmitsSensitiveSSHConfiguration() {
        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: false, eagerLoadTerminal: false)

        workspace.configureRemoteConnection(
            .init(
                destination: "example.com",
                port: 2222,
                identityFile: "/Users/test/.ssh/id_ed25519",
                sshOptions: ["ControlMaster=auto", "ControlPersist=600"],
                localProxyPort: 1080,
                relayPort: 4444,
                relayID: "relay-id",
                relayToken: "relay-token",
                localSocketPath: "/tmp/cmux-test.sock",
                terminalStartupCommand: "ssh example.com"
            ),
            autoConnect: false
        )

        let payload = workspace.remoteStatusPayload()
        XCTAssertNil(payload["identity_file"])
        XCTAssertNil(payload["ssh_options"])
        XCTAssertEqual(payload["has_identity_file"] as? Bool, true)
        XCTAssertEqual(payload["has_ssh_options"] as? Bool, true)
    }

    @Test func testRemoteConfigureRejectsInvalidPersistentDaemonSlot() throws {
        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": UUID().uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "persistent_daemon_slot": "../bad",
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_params")
        XCTAssertEqual(
            error["message"] as? String,
            "persistent_daemon_slot must contain only letters, numbers, '.', '_' or '-'"
        )
    }

    @Test func testRemoteConfigureDefaultsPersistentDaemonSlotForBootstrapSSH() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": workspace.id.uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "preserve_after_terminal_exit": true,
                "auto_connect": false,
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(workspace.remoteConfiguration?.preserveAfterTerminalExit, true)
        XCTAssertEqual(
            workspace.remoteConfiguration?.persistentDaemonSlot,
            "ssh-\(workspace.id.uuidString.lowercased())"
        )
    }

    @Test func testRemoteConfigureDerivesAgentSocketPathFromForwardAgentOption() throws {
        let previousAgentSocketPath = getenv("SSH_AUTH_SOCK").map { String(cString: $0) }
        let agentSocketPath = try makeExistingAgentSocketPath()
        setenv("SSH_AUTH_SOCK", agentSocketPath, 1)
        defer {
            if let previousAgentSocketPath {
                setenv("SSH_AUTH_SOCK", previousAgentSocketPath, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": workspace.id.uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "ssh_options": ["ForwardAgent=yes"],
                "auto_connect": false,
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(workspace.remoteConfiguration?.agentSocketPath, agentSocketPath)
        XCTAssertEqual(workspace.remoteConfiguration?.sshTerminalStartupEnvironment?["SSH_AUTH_SOCK"], agentSocketPath)
        XCTAssertEqual(workspace.remoteConfiguration?.sshProcessEnvironment?["SSH_AUTH_SOCK"], agentSocketPath)
    }

    @Test func testRemoteConfigureExplicitEmptyAgentSocketSuppressesForwardAgentFallback() throws {
        let previousAgentSocketPath = getenv("SSH_AUTH_SOCK").map { String(cString: $0) }
        let agentSocketPath = try makeExistingAgentSocketPath()
        setenv("SSH_AUTH_SOCK", agentSocketPath, 1)
        defer {
            if let previousAgentSocketPath {
                setenv("SSH_AUTH_SOCK", previousAgentSocketPath, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": workspace.id.uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "ssh_options": ["ForwardAgent=yes"],
                "ssh_auth_sock": "",
                "auto_connect": false,
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertNil(workspace.remoteConfiguration?.agentSocketPath)
        XCTAssertNil(workspace.remoteConfiguration?.sshTerminalStartupEnvironment?["SSH_AUTH_SOCK"])
        XCTAssertNil(workspace.remoteConfiguration?.sshProcessEnvironment?["SSH_AUTH_SOCK"])
    }

    @Test func testRemoteConfigureUsesLastForwardAgentOption() throws {
        let previousAgentSocketPath = getenv("SSH_AUTH_SOCK").map { String(cString: $0) }
        let agentSocketPath = try makeExistingAgentSocketPath()
        setenv("SSH_AUTH_SOCK", agentSocketPath, 1)
        defer {
            if let previousAgentSocketPath {
                setenv("SSH_AUTH_SOCK", previousAgentSocketPath, 1)
            } else {
                unsetenv("SSH_AUTH_SOCK")
            }
        }

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let workspace = manager.addWorkspace(select: false, eagerLoadTerminal: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": workspace.id.uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "ssh_options": ["ForwardAgent=yes", "ForwardAgent=no"],
                "auto_connect": false,
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        XCTAssertNil(workspace.remoteConfiguration?.agentSocketPath)
        XCTAssertNil(workspace.remoteConfiguration?.sshTerminalStartupEnvironment?["SSH_AUTH_SOCK"])
        XCTAssertNil(workspace.remoteConfiguration?.sshProcessEnvironment?["SSH_AUTH_SOCK"])
    }

    @Test func testRemoteConfigureRejectsPersistentDaemonSlotWithoutPreserve() throws {
        let response = try handleV2Request(
            method: "workspace.remote.configure",
            params: [
                "workspace_id": UUID().uuidString,
                "transport": "ssh",
                "destination": "example.com",
                "persistent_daemon_slot": "ssh-test-slot",
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_params")
        XCTAssertEqual(
            error["message"] as? String,
            "preserve_after_terminal_exit is required when persistent_daemon_slot is set"
        )
    }

    @Test func testRemotePTYResizeRunsOnSocketWorker() async throws {
        let socketPath = makeSocketPath("pty-worker")
        let tabManager = TabManager()
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let params: [String: Any] = [
            "workspace_id": UUID().uuidString,
            "session_id": "session",
            "attachment_id": "attachment",
            "attachment_token": "token",
            "cols": 100,
            "rows": 30,
        ]
        let requestLine = try makeV2RequestLine(
            method: "workspace.remote.pty_resize",
            params: params
        )

        let mainEnvelope = try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))
        let mainError = try XCTUnwrap(mainEnvelope["error"] as? [String: Any])
        XCTAssertEqual(mainError["code"] as? String, "invalid_dispatch")

        let workerEnvelope = try await sendV2RequestAsync(
            method: "workspace.remote.pty_resize",
            params: params,
            to: socketPath
        )
        let workerError = try XCTUnwrap(workerEnvelope["error"] as? [String: Any])
        XCTAssertNotEqual(workerError["code"] as? String, "invalid_dispatch")
        XCTAssertNotEqual(workerError["code"] as? String, "method_not_found")
        XCTAssertEqual(workerError["code"] as? String, "not_found")
    }

    @Test func privateAgentReportCaptureRoutesOnWorkerAndDisabledGateRetainsNothing() async throws {
        let socketPath = makeSocketPath("report-capture-worker")
        let tabManager = TabManager()
        let store = AgentReportCaptureStore(
            transcriptRecovery: AgentChatTranscriptResolver()
        )
        TerminalController.shared.agentReportCaptureStore = store
        defer { TerminalController.shared.agentReportCaptureStore = nil }
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let surfaceID = UUID()
        let privateBody = "PRIVATE-SOCKET-RESPONSE-SENTINEL"
        let params: [String: Any] = [
            "provider": "codex",
            "workspace_id": UUID().uuidString,
            "surface_id": surfaceID.uuidString,
            "session_id": "synthetic-session",
            "turn_id": "synthetic-turn",
            "completion_kind": "primaryStop",
            "completion_timestamp": 100.0,
            "raw_final_reply": privateBody,
        ]
        let requestLine = try makeV2RequestLine(method: "agent.report.capture", params: params)
        let mainEnvelope = try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))
        let mainError = try XCTUnwrap(mainEnvelope["error"] as? [String: Any])
        XCTAssertEqual(mainError["code"] as? String, "invalid_dispatch")

        let workerEnvelope = try await sendV2RequestAsync(
            method: "agent.report.capture",
            params: params,
            to: socketPath
        )
        XCTAssertEqual(workerEnvelope["ok"] as? Bool, true)
        let result = try XCTUnwrap(workerEnvelope["result"] as? [String: Any])
        XCTAssertEqual(result["status"] as? String, "queued")
        XCTAssertFalse(String(describing: workerEnvelope).contains(privateBody))
        let retained = await store.latestReport(runtimeSurfaceID: surfaceID)
        XCTAssertNil(retained)
    }

    @Test func privateAgentReportEndpointRejectsOversizedBodyWithoutRetentionOrEmission() async throws {
        let socketPath = makeSocketPath("report-body-limit")
        let controller = TerminalController.shared
        let store = AgentReportCaptureStore(
            policy: .enabled,
            transcriptRecovery: SuspendedEndpointAgentReportRecovery(reply: "unused")
        )
        controller.agentReportCaptureStore = store
        defer { controller.agentReportCaptureStore = nil }
        controller.start(tabManager: TabManager(), socketPath: socketPath, accessMode: .allowAll)
        try waitForSocket(at: socketPath)

        let surfaceID = UUID()
        let sentinel = "PRIVATE-OVERSIZED-ENDPOINT-SENTINEL"
        let oversized = String(
            repeating: "x",
            count: AgentReportResourceLimits.sliceA.maximumReportBodyBytes + 1
        ) + sentinel
        let envelope = try await sendV2RequestAsync(
            method: "agent.report.capture",
            params: [
                "provider": "codex",
                "workspace_id": UUID().uuidString,
                "surface_id": surfaceID.uuidString,
                "session_id": "oversized-session",
                "turn_id": "oversized-turn",
                "completion_kind": "primaryStop",
                "completion_timestamp": 100.0,
                "raw_final_reply": oversized,
            ],
            to: socketPath
        )

        #expect(envelope["ok"] as? Bool == false)
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["code"] as? String == "invalid_params")
        #expect(error["data"] == nil)
        #expect(!String(describing: envelope).contains(sentinel))
        #expect(await store.latestReport(runtimeSurfaceID: surfaceID) == nil)
    }

    @Test func appAgentReportResourcePolicyValuesAreFixed() {
        let limits = AgentReportResourceLimits.sliceA
        #expect(limits.maximumReportBodyBytes == 2 * 1024 * 1024)
        #expect(limits.maximumJSONLRecordBytes == 8 * 1024 * 1024)
        #expect(limits.maximumTranscriptBytes == 128 * 1024 * 1024)
        #expect(limits.maximumAuthorizedSocketFrameBytes == 16 * 1024 * 1024)
    }

    @Test func socketFrameCeilingMatchesSharedSliceAPolicy() {
        #expect(
            ControlClientLineReader.maximumAuthorizedRequestFrameBytes
                == AgentReportResourceLimits.sliceA.maximumAuthorizedSocketFrameBytes
        )
    }

    @Test func centralAgentReportCopyWritesExactBodyAndUnavailableDoesNotTouchClipboard() async throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        let store = AgentReportCaptureStore(
            policy: .enabled,
            transcriptRecovery: SuspendedEndpointAgentReportRecovery(reply: "unused")
        )
        let workspaceID = workspace.id
        let surfaceID = panel.id
        let exact = "  ## 完了 ✅\n\nUnicode: Привіт\nno-extra-newline"
        let request = agentReportRequest(workspace: workspace, panel: panel, raw: exact)
        let target = agentReportTarget(workspace: workspace, panel: panel)
        #expect(await store.capture(request, target: target, revalidateTarget: { target }) == .captured)
        let pasteboard = NSPasteboard(name: .init("cmux-agent-report-copy-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("stale clipboard", forType: .string)

        let copied = await AppDelegate.copyLatestAgentReport(
            store: store,
            runtimeSurfaceID: surfaceID,
            to: pasteboard,
            authorize: { report in
                report.workspaceID == workspaceID && report.runtimeSurfaceID == surfaceID
            }
        )

        #expect(copied)
        #expect(pasteboard.string(forType: .string) == exact)
        #expect(!pasteboard.string(forType: .string)!.contains(workspaceID.uuidString))
        #expect(pasteboard.string(forType: .string)!.hasSuffix("no-extra-newline"))

        pasteboard.clearContents()
        pasteboard.setString("preserve me", forType: .string)
        let unavailableChangeCount = pasteboard.changeCount
        #expect(
            await AppDelegate.copyLatestAgentReport(
                store: store,
                runtimeSurfaceID: UUID(),
                to: pasteboard,
                authorize: { _ in true }
            ) == false
        )
        #expect(pasteboard.changeCount == unavailableChangeCount)
        #expect(pasteboard.string(forType: .string) == "preserve me")

        #expect(
            await AppDelegate.copyLatestAgentReport(
                store: store,
                runtimeSurfaceID: surfaceID,
                to: pasteboard,
                authorize: { _ in true },
                shouldWrite: { false }
            ) == false
        )
        #expect(pasteboard.changeCount == unavailableChangeCount)

        #expect(
            await AppDelegate.copyLatestAgentReport(
                store: store,
                runtimeSurfaceID: surfaceID,
                to: pasteboard,
                authorize: { _ in false }
            ) == false
        )
        #expect(pasteboard.changeCount == unavailableChangeCount)
        workspace.teardownAllPanels()
    }

    @Test func shiftCommandCUsesCentralRequestWhileCommandCAndTextInputRemainUntouched() throws {
        let previousAppDelegate = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }
        let workspaceID = UUID()
        let surfaceID = UUID()
        var requests: [(UUID, UUID)] = []
        let shiftCommandC = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "C",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))

        #expect(app.handleAgentReportCopyShortcut(
            event: shiftCommandC,
            captureEnabled: true,
            targetResolver: { _ in (workspaceID, surfaceID) },
            performCopy: { requests.append(($0, $1)) }
        ))
        #expect(requests.count == 1)
        #expect(requests.first?.0 == workspaceID)
        #expect(requests.first?.1 == surfaceID)

        let commandC = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))
        #expect(!app.handleAgentReportCopyShortcut(
            event: commandC,
            captureEnabled: true,
            targetResolver: { _ in (workspaceID, surfaceID) },
            performCopy: { requests.append(($0, $1)) }
        ))
        #expect(!app.handleAgentReportCopyShortcut(
            event: shiftCommandC,
            captureEnabled: true,
            firstResponder: NSTextView(),
            targetResolver: { _ in (workspaceID, surfaceID) },
            performCopy: { requests.append(($0, $1)) }
        ))
        #expect(!app.handleAgentReportCopyShortcut(
            event: shiftCommandC,
            captureEnabled: true,
            targetResolver: { _ in (workspaceID, surfaceID) },
            configuredShortcutOwnsEvent: { _ in true },
            performCopy: { requests.append(($0, $1)) }
        ))
        #expect(!app.handleAgentReportCopyShortcut(
            event: shiftCommandC,
            captureEnabled: true,
            targetResolver: { _ in (workspaceID, surfaceID) },
            hasActiveConfiguredChord: true,
            performCopy: { requests.append(($0, $1)) }
        ))

        let configuredChord = StoredShortcut(
            key: "c",
            command: true,
            shift: true,
            option: false,
            control: false,
            chordKey: "x"
        )
        let configuredSingleStroke = StoredShortcut(
            key: "c",
            command: true,
            shift: true,
            option: false,
            control: false
        )
        #expect(app.configuredShortcutClaimsEvent(
            shiftCommandC,
            shortcut: configuredSingleStroke,
            permitsChordPrefix: false
        ))
        #expect(app.configuredShortcutClaimsEvent(
            shiftCommandC,
            shortcut: configuredChord,
            permitsChordPrefix: true
        ))
        #expect(!app.configuredShortcutClaimsEvent(
            shiftCommandC,
            shortcut: configuredChord,
            permitsChordPrefix: false
        ))
        #expect(!app.handleAgentReportCopyShortcut(
            event: shiftCommandC,
            captureEnabled: true,
            targetResolver: { _ in (workspaceID, surfaceID) },
            configuredShortcutOwnsEvent: { event in
                app.configuredShortcutClaimsEvent(
                    event,
                    shortcut: configuredChord,
                    permitsChordPrefix: true
                )
            },
            performCopy: { requests.append(($0, $1)) }
        ))
        #expect(requests.count == 1)
    }

    @Test func representedMenuAndSmallButtonExposeOnlyLocalizedContentFreeState() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        let surfaceView = panel.hostedView.surfaceView
        var requests: [(UUID, UUID)] = []
        surfaceView.agentReportCopyRequestHandler = { requests.append(($0, $1)) }
        defer {
            surfaceView.agentReportCopyRequestHandler = nil
            workspace.teardownAllPanels()
        }

        let enabledItem = surfaceView.makeAgentReportCopyMenuItem(
            workspaceID: workspace.id,
            runtimeSurfaceID: panel.id,
            isCaptureEnabled: true,
            hasReport: true
        )
        let unavailableItem = surfaceView.makeAgentReportCopyMenuItem(
            workspaceID: workspace.id,
            runtimeSurfaceID: panel.id,
            isCaptureEnabled: false,
            hasReport: true
        )
        #expect(enabledItem.title == String(localized: "agentReport.copy", defaultValue: "Copy Agent Report"))
        #expect(enabledItem.isEnabled)
        #expect(!unavailableItem.isEnabled)

        // The represented IDs remain authoritative even if app focus changes
        // after the menu was constructed.
        surfaceView.copyAgentReport(enabledItem)
        #expect(requests.count == 1)
        #expect(requests.first?.0 == workspace.id)
        #expect(requests.first?.1 == panel.id)

        let hostedView = panel.hostedView
        hostedView.frame = NSRect(x: 0, y: 0, width: 44, height: 40)
        hostedView.layoutSubtreeIfNeeded()
        hostedView.applyAgentReportCopyControlState(isCaptureEnabled: true, hasReport: true)
        let button = hostedView.agentReportCopyButtonForTesting
        let localizedTitle = String(localized: "agentReport.copy", defaultValue: "Copy Agent Report")
        #expect(!button.isHidden)
        #expect(button.isEnabled)
        #expect(button.toolTip == localizedTitle)
        #expect(button.accessibilityLabel() == localizedTitle)
        #expect(button.title.isEmpty)
        #expect(hostedView.bounds.contains(button.frame))
        #expect(!String(describing: button).contains("PRIVATE-REPORT"))

        button.performClick(nil)
        #expect(requests.count == 2)
        #expect(requests.last?.0 == workspace.id)
        #expect(requests.last?.1 == panel.id)

        hostedView.applyAgentReportCopyControlState(isCaptureEnabled: true, hasReport: false)
        #expect(!button.isHidden)
        #expect(!button.isEnabled)
        hostedView.applyAgentReportCopyControlState(isCaptureEnabled: false, hasReport: false)
        #expect(button.isHidden)
    }

    @Test(arguments: ["tab", "pane", "workspace"])
    func completedReportIsPurgedByEveryTrueRemovalPath(_ removalPath: String) async throws {
        let controller = TerminalController.shared
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        let store = AgentReportCaptureStore(
            policy: .enabled,
            transcriptRecovery: SuspendedEndpointAgentReportRecovery(reply: "unused")
        )
        controller.agentReportCaptureStore = store
        var purgeCount = 0
        let purges = AsyncStream<UUID> { continuation in
            controller.agentReportPurgeObserverForTesting = { surfaceID in
                if surfaceID == panel.id { purgeCount += 1 }
                continuation.yield(surfaceID)
            }
        }
        var purgeIterator = purges.makeAsyncIterator()
        defer {
            controller.agentReportPurgeObserverForTesting = nil
            controller.agentReportCaptureStore = nil
            for remainingWorkspace in manager.tabs {
                remainingWorkspace.teardownAllPanels()
            }
        }

        let request = agentReportRequest(workspace: workspace, panel: panel, raw: "completed")
        let target = agentReportTarget(workspace: workspace, panel: panel)
        #expect(
            await store.capture(request, target: target, revalidateTarget: { target })
                == .captured
        )

        try performTrueRemoval(
            removalPath,
            manager: manager,
            workspace: workspace,
            panel: panel
        )
        #expect(await purgeIterator.next() == panel.id)
        #expect(await store.latestReport(runtimeSurfaceID: panel.id) == nil)
        #expect(purgeCount == 1)
    }

    @Test(arguments: ["tab", "pane", "workspace"])
    func pendingCaptureCannotCommitAfterEveryTrueRemovalPath(_ removalPath: String) async throws {
        let controller = TerminalController.shared
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        let recovery = SuspendedEndpointAgentReportRecovery(reply: "late report")
        let store = AgentReportCaptureStore(policy: .enabled, transcriptRecovery: recovery)
        controller.agentReportCaptureStore = store
        let purges = AsyncStream<UUID> { continuation in
            controller.agentReportPurgeObserverForTesting = { continuation.yield($0) }
        }
        var purgeIterator = purges.makeAsyncIterator()
        defer {
            controller.agentReportPurgeObserverForTesting = nil
            controller.agentReportCaptureStore = nil
            for remainingWorkspace in manager.tabs {
                remainingWorkspace.teardownAllPanels()
            }
        }

        let request = agentReportRequest(workspace: workspace, panel: panel, raw: nil)
        let target = agentReportTarget(workspace: workspace, panel: panel)
        let capture = Task {
            await store.capture(request, target: target, revalidateTarget: { target })
        }
        await recovery.waitUntilRecoveryStarted()

        try performTrueRemoval(
            removalPath,
            manager: manager,
            workspace: workspace,
            panel: panel
        )
        #expect(await purgeIterator.next() == panel.id)
        await recovery.resumeRecovery()

        #expect(await capture.value == .rejected(.inaccessibleSurface))
        #expect(await store.latestReport(runtimeSurfaceID: panel.id) == nil)
    }

    @Test func liveWorkspaceTransferMovesAvailabilityAndCentralCopyAuthority() async throws {
        let previousAppDelegate = AppDelegate.shared
        let controller = TerminalController.shared
        let previousTabManager = controller.tabManager
        let previousService = controller.agentChatTranscriptService
        let previousStore = controller.agentReportCaptureStore
        let manager = TabManager()
        let source = try #require(manager.selectedWorkspace)
        let destination = manager.addWorkspace(select: false)
        let panel = try #require(source.focusedTerminalPanel)
        let differentPanel = try #require(destination.focusedTerminalPanel)
        let exact = "  transferred report ✅\n\nПривіт\nno-extra-newline"
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-report-transfer-\(UUID().uuidString)", isDirectory: true)
        let storeDirectory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "sessions": [
                "lifecycle-session": [
                    "workspaceId": source.id.uuidString,
                    "surfaceId": panel.id.uuidString,
                    "transcriptPath": "/synthetic/lifecycle.jsonl",
                    "lastPromptTurnId": "lifecycle-turn",
                    "updatedAt": 100.0,
                ],
            ],
            "activeSessionsBySurface": [
                panel.id.uuidString: [
                    "sessionId": "lifecycle-session",
                    "turnId": "lifecycle-turn",
                    "updatedAt": 100.0,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: storeDirectory.appendingPathComponent("codex-hook-sessions.json"))
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )
        let service = AgentChatTranscriptService(
            registry: registry,
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        )
        let store = AgentReportCaptureStore(
            policy: .enabled,
            transcriptRecovery: SuspendedEndpointAgentReportRecovery(reply: "unused")
        )
        let app = AppDelegate()
        app.tabManager = manager
        app.applyAgentReportCapturePolicy(true)
        AppDelegate.shared = app
        controller.tabManager = manager
        controller.agentChatTranscriptService = service
        controller.agentReportCaptureStore = store
        var purgeCount = 0
        controller.agentReportPurgeObserverForTesting = { _ in purgeCount += 1 }
        defer {
            controller.agentReportPurgeObserverForTesting = nil
            controller.tabManager = previousTabManager
            controller.agentChatTranscriptService = previousService
            controller.agentReportCaptureStore = previousStore
            AppDelegate.shared = previousAppDelegate
            for workspace in manager.tabs {
                workspace.teardownAllPanels()
            }
            try? FileManager.default.removeItem(at: home)
        }

        let snapshots = await store.availabilitySnapshots()
        var snapshotIterator = snapshots.makeAsyncIterator()
        _ = try #require(await snapshotIterator.next())
        let request = agentReportRequest(workspace: source, panel: panel, raw: exact)
        let target = AgentReportCaptureTarget(
            workspaceID: source.id,
            runtimeSurfaceID: panel.id,
            stableSurfaceID: panel.stableSurfaceId,
            agentSessionID: request.agentSessionID,
            turnID: request.turnID,
            lifecycleToken: service.agentReportLifecycleToken(for: panel.id),
            transcriptPath: request.transcriptPath
        )
        #expect(
            await store.capture(request, target: target, revalidateTarget: { target })
                == .captured
        )
        let capturedReport = try #require(await store.latestReport(runtimeSurfaceID: panel.id))
        let capturedSnapshot = try #require(await snapshotIterator.next())
        #expect(capturedSnapshot.hasReport(runtimeSurfaceID: panel.id))
        #expect(!String(describing: capturedSnapshot).contains(exact))
        app.acceptAgentReportAvailability(capturedSnapshot)
        #expect(app.agentReportCopyControlAvailability(
            workspaceID: source.id,
            runtimeSurfaceID: panel.id,
            representedSurface: panel.surface
        ).hasReport)

        let detached = try #require(source.detachSurface(panelId: panel.id))
        let destinationPane = try #require(destination.bonsplitController.allPaneIds.first)
        #expect(destination.attachDetachedSurface(detached, inPane: destinationPane) == panel.id)

        #expect(await store.latestReport(runtimeSurfaceID: panel.id) == capturedReport)
        #expect(purgeCount == 0)
        #expect(!app.agentReportCopyControlAvailability(
            workspaceID: source.id,
            runtimeSurfaceID: panel.id,
            representedSurface: panel.surface
        ).hasReport)
        let destinationAvailability = app.agentReportCopyControlAvailability(
            workspaceID: destination.id,
            runtimeSurfaceID: panel.id,
            representedSurface: panel.surface
        )
        #expect(destinationAvailability.hasReport)

        let sourcePasteboard = NSPasteboard(name: .init("cmux-transfer-source-\(UUID().uuidString)"))
        sourcePasteboard.clearContents()
        sourcePasteboard.setString("preserve source", forType: .string)
        let sourceChangeCount = sourcePasteboard.changeCount
        #expect(
            await AppDelegate.copyLatestAgentReport(
                store: store,
                runtimeSurfaceID: panel.id,
                to: sourcePasteboard,
                authorize: { context in
                    await controller.authorizesAgentReportCopy(
                        context,
                        representedWorkspaceID: source.id,
                        representedSurfaceID: panel.id
                    )
                }
            ) == false
        )
        #expect(sourcePasteboard.changeCount == sourceChangeCount)
        #expect(sourcePasteboard.string(forType: .string) == "preserve source")

        let destinationPasteboard = NSPasteboard(name: .init("cmux-transfer-destination-\(UUID().uuidString)"))
        destinationPasteboard.clearContents()
        #expect(
            await AppDelegate.copyLatestAgentReport(
                store: store,
                runtimeSurfaceID: panel.id,
                to: destinationPasteboard,
                authorize: { context in
                    await controller.authorizesAgentReportCopy(
                        context,
                        representedWorkspaceID: destination.id,
                        representedSurfaceID: panel.id
                    )
                }
            )
        )
        #expect(destinationPasteboard.string(forType: .string) == exact)
        #expect(destinationPasteboard.string(forType: .string)?.hasSuffix("no-extra-newline") == true)

        let differentPasteboard = NSPasteboard(name: .init("cmux-transfer-different-\(UUID().uuidString)"))
        differentPasteboard.clearContents()
        differentPasteboard.setString("preserve different", forType: .string)
        let differentChangeCount = differentPasteboard.changeCount
        #expect(
            await AppDelegate.copyLatestAgentReport(
                store: store,
                runtimeSurfaceID: differentPanel.id,
                to: differentPasteboard,
                authorize: { _ in true }
            ) == false
        )
        #expect(differentPasteboard.changeCount == differentChangeCount)

        var requests: [(UUID, UUID)] = []
        let surfaceView = panel.hostedView.surfaceView
        surfaceView.agentReportCopyRequestHandler = { requests.append(($0, $1)) }
        defer { surfaceView.agentReportCopyRequestHandler = nil }
        let menuItem = surfaceView.makeAgentReportCopyMenuItem(
            workspaceID: destination.id,
            runtimeSurfaceID: panel.id,
            isCaptureEnabled: destinationAvailability.isCaptureEnabled,
            hasReport: destinationAvailability.hasReport
        )
        #expect(menuItem.isEnabled)
        manager.selectWorkspace(source)
        surfaceView.copyAgentReport(menuItem)
        #expect(requests.count == 1)
        #expect(requests[0].0 == destination.id)
        #expect(requests[0].1 == panel.id)
        let menuTarget = requests[0]
        let menuPasteboard = NSPasteboard(name: .init("cmux-transfer-menu-\(UUID().uuidString)"))
        #expect(
            await AppDelegate.copyLatestAgentReport(
                store: store,
                runtimeSurfaceID: menuTarget.1,
                to: menuPasteboard,
                authorize: { context in
                    await controller.authorizesAgentReportCopy(
                        context,
                        representedWorkspaceID: menuTarget.0,
                        representedSurfaceID: menuTarget.1
                    )
                }
            )
        )
        #expect(menuPasteboard.string(forType: .string) == exact)

        let hostedView = panel.hostedView
        hostedView.synchronizeAgentReportCopyControl()
        let button = hostedView.agentReportCopyButtonForTesting
        #expect(!button.isHidden)
        #expect(button.isEnabled)
        button.performClick(nil)
        #expect(requests.count == 2)
        #expect(requests[1].0 == destination.id)
        #expect(requests[1].1 == panel.id)
        let buttonTarget = requests[1]
        let buttonPasteboard = NSPasteboard(name: .init("cmux-transfer-button-\(UUID().uuidString)"))
        #expect(
            await AppDelegate.copyLatestAgentReport(
                store: store,
                runtimeSurfaceID: buttonTarget.1,
                to: buttonPasteboard,
                authorize: { context in
                    await controller.authorizesAgentReportCopy(
                        context,
                        representedWorkspaceID: buttonTarget.0,
                        representedSurfaceID: buttonTarget.1
                    )
                }
            )
        )
        #expect(buttonPasteboard.string(forType: .string) == exact)

        let shiftCommandC = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "C",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))
        #expect(app.handleAgentReportCopyShortcut(
            event: shiftCommandC,
            captureEnabled: true,
            targetResolver: { _ in (destination.id, panel.id) },
            performCopy: { requests.append(($0, $1)) }
        ))
        #expect(requests.count == 3)
        #expect(requests[2].0 == destination.id)
        #expect(requests[2].1 == panel.id)
        let shortcutTarget = requests[2]
        let shortcutPasteboard = NSPasteboard(name: .init("cmux-transfer-shortcut-\(UUID().uuidString)"))
        #expect(
            await AppDelegate.copyLatestAgentReport(
                store: store,
                runtimeSurfaceID: shortcutTarget.1,
                to: shortcutPasteboard,
                authorize: { context in
                    await controller.authorizesAgentReportCopy(
                        context,
                        representedWorkspaceID: shortcutTarget.0,
                        representedSurfaceID: shortcutTarget.1
                    )
                }
            )
        )
        #expect(shortcutPasteboard.string(forType: .string) == exact)

        let detachedBack = try #require(destination.detachSurface(panelId: panel.id))
        let sourcePane = try #require(source.bonsplitController.allPaneIds.first)
        #expect(source.attachDetachedSurface(detachedBack, inPane: sourcePane) == panel.id)
        #expect(app.agentReportCopyControlAvailability(
            workspaceID: source.id,
            runtimeSurfaceID: panel.id,
            representedSurface: panel.surface
        ).hasReport)
        #expect(!app.agentReportCopyControlAvailability(
            workspaceID: destination.id,
            runtimeSurfaceID: panel.id,
            representedSurface: panel.surface
        ).hasReport)
        #expect(await store.latestReport(runtimeSurfaceID: panel.id) == capturedReport)

        await store.purge(runtimeSurfaceID: panel.id)
        let purgedSnapshot = try #require(await snapshotIterator.next())
        app.acceptAgentReportAvailability(purgedSnapshot)
        #expect(!app.agentReportCopyControlAvailability(
            workspaceID: source.id,
            runtimeSurfaceID: panel.id,
            representedSurface: panel.surface
        ).hasReport)
        let purgedPasteboard = NSPasteboard(name: .init("cmux-transfer-purged-\(UUID().uuidString)"))
        purgedPasteboard.clearContents()
        purgedPasteboard.setString("preserve purged", forType: .string)
        let purgedChangeCount = purgedPasteboard.changeCount
        #expect(
            await AppDelegate.copyLatestAgentReport(
                store: store,
                runtimeSurfaceID: panel.id,
                to: purgedPasteboard,
                authorize: { _ in true }
            ) == false
        )
        #expect(purgedPasteboard.changeCount == purgedChangeCount)
    }

    @Test(arguments: ["session-rebind", "resume", "lifecycle-token", "disable"])
    func transferredReportFailsClosedAfterAuthorityRevocation(_ revocation: String) async throws {
        let previousAppDelegate = AppDelegate.shared
        let controller = TerminalController.shared
        let previousTabManager = controller.tabManager
        let previousService = controller.agentChatTranscriptService
        let previousStore = controller.agentReportCaptureStore
        let manager = TabManager()
        let source = try #require(manager.selectedWorkspace)
        let destination = manager.addWorkspace(select: false)
        let panel = try #require(source.focusedTerminalPanel)
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-report-transfer-revoke-\(UUID().uuidString)", isDirectory: true)
        let storeDirectory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "sessions": [
                "lifecycle-session": [
                    "workspaceId": source.id.uuidString,
                    "surfaceId": panel.id.uuidString,
                    "transcriptPath": "/synthetic/lifecycle.jsonl",
                    "lastPromptTurnId": "lifecycle-turn",
                    "updatedAt": 100.0,
                ],
            ],
            "activeSessionsBySurface": [
                panel.id.uuidString: [
                    "sessionId": "lifecycle-session",
                    "turnId": "lifecycle-turn",
                    "updatedAt": 100.0,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: storeDirectory.appendingPathComponent("codex-hook-sessions.json"))
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )
        let service = AgentChatTranscriptService(
            registry: registry,
            resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        )
        let store = AgentReportCaptureStore(
            policy: .enabled,
            transcriptRecovery: SuspendedEndpointAgentReportRecovery(reply: "unused")
        )
        service.setAgentReportSurfaceInvalidator { surfaceID in
            Task { await store.invalidatePendingCapture(runtimeSurfaceID: surfaceID) }
        }
        let app = AppDelegate()
        app.tabManager = manager
        app.applyAgentReportCapturePolicy(true)
        AppDelegate.shared = app
        controller.tabManager = manager
        controller.agentChatTranscriptService = service
        controller.agentReportCaptureStore = store
        defer {
            controller.tabManager = previousTabManager
            controller.agentChatTranscriptService = previousService
            controller.agentReportCaptureStore = previousStore
            AppDelegate.shared = previousAppDelegate
            for workspace in manager.tabs {
                workspace.teardownAllPanels()
            }
            try? FileManager.default.removeItem(at: home)
        }

        let snapshots = await store.availabilitySnapshots()
        var snapshotIterator = snapshots.makeAsyncIterator()
        _ = try #require(await snapshotIterator.next())
        let request = agentReportRequest(workspace: source, panel: panel, raw: "retained before revoke")
        let target = AgentReportCaptureTarget(
            workspaceID: source.id,
            runtimeSurfaceID: panel.id,
            stableSurfaceID: panel.stableSurfaceId,
            agentSessionID: request.agentSessionID,
            turnID: request.turnID,
            lifecycleToken: service.agentReportLifecycleToken(for: panel.id),
            transcriptPath: request.transcriptPath
        )
        #expect(await store.capture(request, target: target, revalidateTarget: { target }) == .captured)
        let capturedSnapshot = try #require(await snapshotIterator.next())
        app.acceptAgentReportAvailability(capturedSnapshot)
        let detached = try #require(source.detachSurface(panelId: panel.id))
        let destinationPane = try #require(destination.bonsplitController.allPaneIds.first)
        #expect(destination.attachDetachedSurface(detached, inPane: destinationPane) == panel.id)
        #expect(app.agentReportCopyControlAvailability(
            workspaceID: destination.id,
            runtimeSurfaceID: panel.id,
            representedSurface: panel.surface
        ).hasReport)

        let preconditionPasteboard = NSPasteboard(
            name: .init("cmux-transfer-revoke-precondition-\(UUID().uuidString)")
        )
        #expect(
            await AppDelegate.copyLatestAgentReport(
                store: store,
                runtimeSurfaceID: panel.id,
                to: preconditionPasteboard,
                authorize: { context in
                    await controller.authorizesAgentReportCopy(
                        context,
                        representedWorkspaceID: destination.id,
                        representedSurfaceID: panel.id
                    )
                }
            )
        )

        switch revocation {
        case "session-rebind":
            service.noteResumeInitiated(
                sessionID: "replacement-session",
                source: "codex",
                surfaceID: panel.id.uuidString,
                workspaceID: destination.id.uuidString,
                workingDirectory: nil
            )
        case "resume":
            service.noteResumeInitiated(
                sessionID: request.agentSessionID,
                source: "codex",
                surfaceID: panel.id.uuidString,
                workspaceID: destination.id.uuidString,
                workingDirectory: nil
            )
        case "lifecycle-token":
            service.invalidateAgentReportSurfaceLifecycle(runtimeSurfaceID: panel.id)
        case "disable":
            app.applyAgentReportCapturePolicy(false)
            await store.setPolicy(.disabled)
        default:
            Issue.record("Unknown transfer revocation")
        }

        let revokedSnapshot = try #require(await snapshotIterator.next())
        app.acceptAgentReportAvailability(revokedSnapshot)
        #expect(!app.agentReportCopyControlAvailability(
            workspaceID: destination.id,
            runtimeSurfaceID: panel.id,
            representedSurface: panel.surface
        ).hasReport)
        let revokedPasteboard = NSPasteboard(
            name: .init("cmux-transfer-revoked-\(revocation)-\(UUID().uuidString)")
        )
        revokedPasteboard.clearContents()
        revokedPasteboard.setString("preserve revoked", forType: .string)
        let revokedChangeCount = revokedPasteboard.changeCount
        #expect(
            await AppDelegate.copyLatestAgentReport(
                store: store,
                runtimeSurfaceID: panel.id,
                to: revokedPasteboard,
                authorize: { context in
                    await controller.authorizesAgentReportCopy(
                        context,
                        representedWorkspaceID: destination.id,
                        representedSurfaceID: panel.id
                    )
                }
            ) == false
        )
        #expect(revokedPasteboard.changeCount == revokedChangeCount)
        #expect(revokedPasteboard.string(forType: .string) == "preserve revoked")
    }

    @Test func repeatedWorkspaceTeardownPurgesEachSurfaceExactlyOnce() async throws {
        let controller = TerminalController.shared
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        let store = AgentReportCaptureStore(
            policy: .enabled,
            transcriptRecovery: SuspendedEndpointAgentReportRecovery(reply: "unused")
        )
        controller.agentReportCaptureStore = store
        var purgeCount = 0
        let purges = AsyncStream<UUID> { continuation in
            controller.agentReportPurgeObserverForTesting = { surfaceID in
                if surfaceID == panel.id { purgeCount += 1 }
                continuation.yield(surfaceID)
            }
        }
        var purgeIterator = purges.makeAsyncIterator()
        defer {
            controller.agentReportPurgeObserverForTesting = nil
            controller.agentReportCaptureStore = nil
            workspace.teardownAllPanels()
        }

        let request = agentReportRequest(workspace: workspace, panel: panel, raw: "completed")
        let target = agentReportTarget(workspace: workspace, panel: panel)
        #expect(
            await store.capture(request, target: target, revalidateTarget: { target })
                == .captured
        )
        workspace.teardownAllPanels()
        #expect(await purgeIterator.next() == panel.id)
        workspace.teardownAllPanels()

        #expect(purgeCount == 1)
        #expect(await store.latestReport(runtimeSurfaceID: panel.id) == nil)
    }

    @Test func enabledPrivateAgentReportEndpointValidatesAndCapturesExactLiveSurface() async throws {
        let socketPath = makeSocketPath("report-capture-enabled")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-report-endpoint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let tabManager = TabManager()
        let workspace = tabManager.addWorkspace(select: true)
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let sessionID = "synthetic-endpoint-session"
        let turnID = "synthetic-endpoint-turn"
        let historicalSessionID = "synthetic-historical-endpoint-session"
        let historicalTurnID = "synthetic-historical-endpoint-turn"
        let exact = "  ## Exact endpoint reply\n\n日本語 ✅  \n"
        let transcriptURL = home
            .appendingPathComponent(".codex/sessions/2026/07/17", isDirectory: true)
            .appendingPathComponent("synthetic-rollout.jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"type":"session_meta","payload":{"id":"synthetic-endpoint-session"}}"#
            .appending("\n")
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        let storeDirectory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let hookStorePayload: [String: Any] = [
            "sessions": [
                sessionID: [
                    "workspaceId": workspace.id.uuidString,
                    "surfaceId": panel.id.uuidString,
                    "transcriptPath": transcriptURL.path,
                    "lastPromptTurnId": turnID,
                    "updatedAt": 100.0,
                ],
                historicalSessionID: [
                    "workspaceId": workspace.id.uuidString,
                    "surfaceId": panel.id.uuidString,
                    "transcriptPath": transcriptURL.path,
                    "lastPromptTurnId": historicalTurnID,
                    "updatedAt": 50.0,
                ],
            ],
            "activeSessionsBySurface": [
                panel.id.uuidString: [
                    "sessionId": sessionID,
                    "turnId": turnID,
                    "updatedAt": 100.0,
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: hookStorePayload, options: [.sortedKeys])
            .write(to: storeDirectory.appendingPathComponent("codex-hook-sessions.json"))

        let resolver = AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
        let registry = AgentChatSessionRegistry(
            hookStore: AgentChatHookSessionStore(homeDirectory: home)
        )
        let service = AgentChatTranscriptService(registry: registry, resolver: resolver)
        let store = AgentReportCaptureStore(policy: .enabled, transcriptRecovery: resolver)
        let controller = TerminalController.shared
        controller.agentChatTranscriptService = service
        controller.agentReportCaptureStore = store
        defer {
            controller.agentReportCaptureResultObserverForTesting = nil
            controller.agentChatTranscriptService = nil
            controller.agentReportCaptureStore = nil
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
        }
        controller.start(tabManager: tabManager, socketPath: socketPath, accessMode: .allowAll)
        try waitForSocket(at: socketPath)
        #expect(controller.tabManager === tabManager)
        #expect(workspace.panels[panel.id] === panel)
        #expect(workspace.surfaceIdFromPanelId(panel.id) != nil)
        let directBinding = await registry.agentReportCaptureBinding(
            workspaceID: workspace.id.uuidString,
            surfaceID: panel.id.uuidString,
            sessionID: sessionID,
            turnID: turnID,
            requestedTranscriptPath: transcriptURL.path
        )
        #expect(directBinding?.transcriptPath == transcriptURL.path)

        let params: [String: Any] = [
            "provider": "codex",
            "workspace_id": workspace.id.uuidString,
            "surface_id": panel.id.uuidString,
            "session_id": sessionID,
            "turn_id": turnID,
            "completion_kind": "primaryStop",
            "completion_timestamp": 100.0,
            "transcript_path": transcriptURL.path,
            "raw_final_reply": exact,
        ]
        var historicalParams = params
        historicalParams["session_id"] = historicalSessionID
        historicalParams["turn_id"] = historicalTurnID
        historicalParams["raw_final_reply"] = "historical reply must not capture"
        let results = AsyncStream<AgentReportCaptureResult> { continuation in
            controller.agentReportCaptureResultObserverForTesting = { result in
                continuation.yield(result)
            }
        }
        var resultIterator = results.makeAsyncIterator()
        let historicalEnvelope = try await sendV2RequestAsync(
            method: "agent.report.capture",
            params: historicalParams,
            to: socketPath
        )
        #expect(historicalEnvelope["ok"] as? Bool == true)
        #expect(await resultIterator.next() == .rejected(.inaccessibleSurface))
        #expect(await store.latestReport(runtimeSurfaceID: panel.id) == nil)

        let envelope = try await sendV2RequestAsync(
            method: "agent.report.capture",
            params: params,
            to: socketPath
        )
        #expect(envelope["ok"] as? Bool == true)
        #expect(!String(describing: envelope).contains(exact))
        #expect(await resultIterator.next() == .captured)

        let report = try #require(await store.latestReport(runtimeSurfaceID: panel.id))
        #expect(report.finalReply == exact)
        #expect(report.captureSource == .rawHook)
    }

    @Test func queuedLifecycleCleanupCannotCommitAfterPromptOrResumeTransition() async throws {
        for lifecycle in ["prompt", "resume"] {
            let socketPath = makeSocketPath("report-\(lifecycle)")
            let home = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-report-lifecycle-\(lifecycle)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

            let tabManager = TabManager()
            let workspace = tabManager.addWorkspace(select: true)
            let panel = try #require(workspace.focusedTerminalPanel)
            let sessionID = "synthetic-\(lifecycle)-lifecycle-session"
            let turnID = "synthetic-\(lifecycle)-lifecycle-turn"
            let transcriptURL = home
                .appendingPathComponent(".codex/sessions/2026/07/17", isDirectory: true)
                .appendingPathComponent("rollout-\(sessionID).jsonl")
            try FileManager.default.createDirectory(
                at: transcriptURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try "{}\n".write(to: transcriptURL, atomically: true, encoding: .utf8)
            let storeDirectory = home.appendingPathComponent(".cmuxterm", isDirectory: true)
            try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            let hookStorePayload: [String: Any] = [
                "sessions": [
                    sessionID: [
                        "workspaceId": workspace.id.uuidString,
                        "surfaceId": panel.id.uuidString,
                        "transcriptPath": transcriptURL.path,
                        "lastPromptTurnId": turnID,
                        "updatedAt": 100.0,
                    ],
                ],
                "activeSessionsBySurface": [
                    panel.id.uuidString: [
                        "sessionId": sessionID,
                        "turnId": turnID,
                        "updatedAt": 100.0,
                    ],
                ],
            ]
            try JSONSerialization.data(withJSONObject: hookStorePayload, options: [.sortedKeys])
                .write(to: storeDirectory.appendingPathComponent("codex-hook-sessions.json"))

            let recovery = SuspendedEndpointAgentReportRecovery(reply: "late private report")
            let invalidationGate = QueuedAgentReportInvalidationGate()
            let registry = AgentChatSessionRegistry(
                hookStore: AgentChatHookSessionStore(homeDirectory: home)
            )
            let service = AgentChatTranscriptService(
                registry: registry,
                resolver: AgentChatTranscriptResolver(homeDirectory: home, environment: [:])
            )
            let store = AgentReportCaptureStore(policy: .enabled, transcriptRecovery: recovery)
            service.setAgentReportSurfaceInvalidator { surfaceID in
                Task {
                    await invalidationGate.enqueue(surfaceID: surfaceID, store: store)
                }
            }

            let controller = TerminalController.shared
            controller.agentChatTranscriptService = service
            controller.agentReportCaptureStore = store
            controller.start(tabManager: tabManager, socketPath: socketPath, accessMode: .allowAll)
            try waitForSocket(at: socketPath)
            let results = AsyncStream<AgentReportCaptureResult> { continuation in
                controller.agentReportCaptureResultObserverForTesting = { continuation.yield($0) }
            }
            var resultIterator = results.makeAsyncIterator()
            let envelope = try await sendV2RequestAsync(
                method: "agent.report.capture",
                params: [
                    "provider": "codex",
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": panel.id.uuidString,
                    "session_id": sessionID,
                    "turn_id": turnID,
                    "completion_kind": "primaryStop",
                    "completion_timestamp": 100.0,
                    "transcript_path": transcriptURL.path,
                ],
                to: socketPath
            )
            #expect(envelope["ok"] as? Bool == true)
            await recovery.waitUntilRecoveryStarted()

            if lifecycle == "prompt" {
                service.noteHookEvent(WorkstreamEvent(
                    sessionId: sessionID,
                    hookEventName: .userPromptSubmit,
                    source: "codex",
                    workspaceId: workspace.id.uuidString,
                    surfaceId: panel.id.uuidString,
                    transcriptPath: transcriptURL.path
                ))
            } else {
                service.noteResumeInitiated(
                    sessionID: sessionID,
                    source: "codex",
                    surfaceID: panel.id.uuidString,
                    workspaceID: workspace.id.uuidString,
                    workingDirectory: home.path
                )
            }
            await invalidationGate.waitUntilQueued()
            await recovery.resumeRecovery()

            #expect(await resultIterator.next() == .rejected(.inaccessibleSurface))
            #expect(await store.latestReport(runtimeSurfaceID: panel.id) == nil)

            await invalidationGate.release()
            controller.agentReportCaptureResultObserverForTesting = nil
            controller.agentChatTranscriptService = nil
            controller.agentReportCaptureStore = nil
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
            try? FileManager.default.removeItem(at: home)
        }
    }

    @Test func testWorkspaceWorkerMethodRejectsWindowAliasInsteadOfDefaultWindowFallback() async throws {
        let socketPath = makeSocketPath("alias-worker")
        let tabManager = TabManager()
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let params: [String: Any] = ["window": "window:2"]
        let requestLine = try makeV2RequestLine(
            method: "workspace.remote.pty_sessions",
            params: params
        )

        let mainEnvelope = try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))
        let mainError = try XCTUnwrap(mainEnvelope["error"] as? [String: Any])
        XCTAssertEqual(mainError["code"] as? String, "invalid_dispatch")

        let workerEnvelope = try await sendV2RequestAsync(
            method: "workspace.remote.pty_sessions",
            params: params,
            to: socketPath
        )
        try assertUnsupportedWorkspaceWindowAlias(workerEnvelope)
    }

    @Test func testHeartbeatMethodsSupportInProcessAndSocketDispatch() async throws {
        let socketPath = makeSocketPath("heartbeat-worker")
        let tabManager = TabManager()
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        for method in ["system.ping", "system.capabilities"] {
            let requestLine = try makeV2RequestLine(method: method, params: [:])
            let mainEnvelope = try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))
            XCTAssertEqual(mainEnvelope["ok"] as? Bool, true, method)
            try assertHeartbeatResult(method: method, envelope: mainEnvelope)

            let workerEnvelope = try await sendV2RequestAsync(method: method, params: [:], to: socketPath)
            XCTAssertEqual(workerEnvelope["ok"] as? Bool, true, method)
            try assertHeartbeatResult(method: method, envelope: workerEnvelope)
        }
    }

    @Test func testV1PingRunsOnWorkerLaneAndStaysMainThreadCallable() async throws {
        let socketPath = makeSocketPath("v1-ping")
        let tabManager = TabManager()
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        // v1 `ping` sits on the worker lane
        // (`ControlCommandExecutionPolicy(forV1Command:)`) but is
        // mainThreadCallable, so in-process main-thread dispatch must answer
        // inline instead of tripping the v1 invalid-dispatch guard.
        XCTAssertEqual(TerminalController.shared.handleSocketLine("ping"), "PONG")
        XCTAssertEqual(TerminalController.shared.handleSocketLine("PING"), "PONG")

        // Worker-lane proof: this synchronous round-trip blocks the main
        // thread in read() until the reply lands, so the reply can only
        // arrive if the connection thread serves `ping` without a
        // DispatchQueue.main.sync hop. A main-lane `ping` would deadlock here
        // (main waits on the reply, the reply waits on main).
        let responses = try sendCommands(["ping"], to: socketPath)
        XCTAssertEqual(responses, ["PONG"])

        // A main-lane v1 command still round-trips through the main hop. It
        // must be sent off-main (async, like sendV2RequestAsync) so the main
        // thread stays free to serve the command's DispatchQueue.main.sync.
        let mainLane = try await sendV1CommandsAsync(["current_workspace"], to: socketPath)
        XCTAssertEqual(mainLane.count, 1)
        XCTAssertFalse(mainLane[0].isEmpty)
    }

    @Test func testSurfaceReadTextIsServicedOnTheWorkerLane() async throws {
        let socketPath = makeSocketPath("v2-read-text-worker")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }
        // Release the focused terminal's Ghostty surface so the capture hop
        // fails deterministically at the raw-snapshot read: the reply must be
        // the legacy `internal_error` bytes. A worker-lane dispatch drift
        // (policy lists the method but the worker switch case is missing)
        // would instead answer the loud "has no worker handler" backstop, and
        // a coordinator re-lift would answer method_not_found — both caught
        // here.
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)
        panel.surface.releaseSurfaceForTesting()

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        // surface.read_text is worker-lane and NOT mainThreadCallable: an
        // in-process main-thread caller is rejected with invalid_dispatch
        // instead of running the (possibly multi-MB) scrollback formatting
        // inline on the main thread. A `read_text`'s reply cannot land while
        // the main thread is wedged (its Ghostty capture legitimately takes
        // one v2MainSync hop), so unlike the set_status worker-lane proof
        // below this round-trip runs with the main actor free.
        let inline = TerminalController.shared.handleSocketLine(
            #"{"id":"rt-main","method":"surface.read_text","params":{}}"#
        )
        XCTAssertTrue(inline.contains("invalid_dispatch"), inline)
        XCTAssertTrue(inline.contains("surface.read_text must run off the main thread"), inline)

        // Worker-lane round-trip from a background sender (timeout-bounded by
        // the await): byte-faithful legacy error for a released surface.
        let envelope = try await sendV2RequestAsync(
            method: "surface.read_text",
            params: ["workspace_id": workspace.id.uuidString],
            to: socketPath
        )
        XCTAssertEqual(envelope["ok"] as? Bool, false)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "internal_error")
        XCTAssertEqual(error["message"] as? String, "Failed to read terminal text")

        // v1 twin: read_screen shares the capture-hop/format-off-main split
        // and the not-mainThreadCallable policy.
        let v1Inline = TerminalController.shared.handleSocketLine("read_screen")
        XCTAssertEqual(v1Inline, "ERROR: read_screen must run off the main thread")
        let v1Replies = try await sendV1CommandsAsync(["read_screen"], to: socketPath)
        XCTAssertEqual(v1Replies, ["ERROR: Terminal surface not found"])
    }

    @Test func testV1SetStatusIsServicedOnWorkerLaneWhileMainThreadIsBlocked() throws {
        let socketPath = makeSocketPath("v1-status-worker")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        // Worker-lane proof for a migrated telemetry verb (tranche B1): the
        // scoped set_status path is parse + TerminalMutationBus enqueue with
        // zero v2MainSync hops, so its reply must arrive while this test
        // wedges the main thread in the semaphore wait below. The verb is
        // mainThreadCallable, so the round-trip has to be sent from a
        // background queue — an in-process main-thread send would run inline
        // and prove nothing. A regression that reroutes the verb to the main
        // lane (or adds a main hop to the scoped path) turns this into a
        // bounded timeout failure, not a deadlock, because the sender thread
        // just parks in read() until then.
        let command = "set_status build ok --tab=\(workspace.id.uuidString)"
        let replyArrived = DispatchSemaphore(value: 0)
        let replyBox = WorkerLaneReplyBox()
        DispatchQueue.global(qos: .userInitiated).async {
            replyBox.store(Result { try self.sendV1Commands([command], to: socketPath) })
            replyArrived.signal()
        }

        let waited = replyArrived.wait(timeout: .now() + 5)
        XCTAssertEqual(
            waited == .success,
            true,
            "set_status must be serviced on the socket-worker lane; its reply did not arrive while the main thread was blocked"
        )
        XCTAssertEqual(try replyBox.take(), ["OK"])

        // The mutation is bus-deferred and the main thread has been held by
        // this test since before the send, so the reply necessarily preceded
        // the apply; drain and verify the deferred write lands.
        XCTAssertNil(workspace.statusEntries["build"])
        TerminalMutationBus.shared.drainForTesting()
        XCTAssertEqual(workspace.statusEntries["build"]?.value, "ok")
    }

    private func assertHeartbeatResult(method: String, envelope: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws {
        let result = try XCTUnwrap(envelope["result"] as? [String: Any], method, file: file, line: line)
        switch method {
        case "system.ping":
            XCTAssertEqual(result["pong"] as? Bool, true, file: file, line: line)
        case "system.capabilities":
            let methods = try XCTUnwrap(result["methods"] as? [String], method, file: file, line: line)
            let advertisedMethods = Set(methods)
            let expectedMethods: Set<String> = [
                "system.ping",
                "system.capabilities",
                "mobile.host.status",
                "mobile.attach_ticket.create",
                "mobile.workspace.list",
                "workspace.list",
                "workspace.create",
                "mobile.terminal.create",
                "terminal.create",
                "mobile.terminal.input",
                "terminal.input",
                "mobile.terminal.replay",
                "terminal.replay",
                "mobile.terminal.viewport",
                "terminal.viewport",
                "mobile.events.subscribe",
                "mobile.events.unsubscribe",
            ]
            XCTAssertTrue(
                expectedMethods.isSubset(of: advertisedMethods),
                "Missing capabilities: \(expectedMethods.subtracting(advertisedMethods).sorted())",
                file: file,
                line: line
            )
        default:
            XCTFail("Unexpected heartbeat method \(method)", file: file, line: line)
        }
    }

    @Test func testRemotePTYBridgeWaitForReadyRunsOnSocketWorker() async throws {
        let socketPath = makeSocketPath("pty-bridge-worker")
        let tabManager = TabManager()
        TerminalController.shared.start(
            tabManager: tabManager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let params: [String: Any] = [
            "workspace_id": UUID().uuidString,
            "session_id": "session",
            "attachment_id": "attachment",
            "wait_for_ready": true,
        ]
        let requestLine = try makeV2RequestLine(
            method: "workspace.remote.pty_bridge",
            params: params
        )

        let mainEnvelope = try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))
        let mainError = try XCTUnwrap(mainEnvelope["error"] as? [String: Any])
        XCTAssertEqual(mainError["code"] as? String, "invalid_dispatch")

        let workerEnvelope = try await sendV2RequestAsync(
            method: "workspace.remote.pty_bridge",
            params: params,
            to: socketPath
        )
        let workerError = try XCTUnwrap(workerEnvelope["error"] as? [String: Any])
        XCTAssertNotEqual(workerError["code"] as? String, "invalid_dispatch")
        XCTAssertNotEqual(workerError["code"] as? String, "method_not_found")
        XCTAssertEqual(workerError["code"] as? String, "not_found")
    }

    @Test func testRemotePTYAttachEndRoutesMovedSurfaceToCurrentWorkspace() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let manager = TabManager()
        let moved = try makeMovedRemotePTYSurface(in: manager)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: makeSocketPath("pty-end"),
            accessMode: .allowAll
        )

        let requestLine = try makeV2RequestLine(
            method: "workspace.remote.pty_attach_end",
            params: [
                "workspace_id": moved.source.id.uuidString,
                "surface_id": moved.panel.id.uuidString,
                "session_id": moved.sessionID,
            ]
        )
        let envelope = try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))

        XCTAssertEqual(envelope["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(envelope)")
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        XCTAssertEqual(result["window_id"] as? String, windowId.uuidString)
        XCTAssertEqual(result["workspace_id"] as? String, moved.destination.id.uuidString)
        XCTAssertEqual(result["surface_id"] as? String, moved.panel.id.uuidString)
        XCTAssertEqual(result["cleared_remote_pty_session"] as? Bool, true)
        XCTAssertEqual(result["untracked_remote_terminal"] as? Bool, true)
        XCTAssertFalse(moved.destination.isRemoteTerminalSurface(moved.panel.id))
        XCTAssertEqual(moved.destination.activeRemoteTerminalSessionCount, 0)
    }

    @Test func testRemotePTYRejectsWorkspaceSurfaceMismatchWithoutMovedSurfaceOptIn() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let socketPath = makeSocketPath("pty-mismatch")
        let manager = TabManager()
        let moved = try makeMovedRemotePTYSurface(in: manager)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await sendV2RequestAsync(
            method: "workspace.remote.pty_resize",
            params: [
                "workspace_id": moved.source.id.uuidString,
                "surface_id": moved.panel.id.uuidString,
                "session_id": moved.sessionID,
                "attachment_id": moved.panel.id.uuidString,
                "attachment_token": "token",
                "cols": 100,
                "rows": 30,
            ],
            to: socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_params")
        XCTAssertEqual(error["message"] as? String, "surface_id does not belong to workspace_id")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["workspace_id"] as? String, moved.source.id.uuidString)
        XCTAssertEqual(data["surface_id"] as? String, moved.panel.id.uuidString)
        XCTAssertEqual(data["resolved_workspace_id"] as? String, moved.destination.id.uuidString)
    }

    @Test func testRemotePTYResizeRoutesMovedSurfaceToCurrentWorkspace() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let socketPath = makeSocketPath("pty-move")
        let manager = TabManager()
        let moved = try makeMovedRemotePTYSurface(in: manager)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await sendV2RequestAsync(
            method: "workspace.remote.pty_resize",
            params: [
                "workspace_id": moved.source.id.uuidString,
                "surface_id": moved.panel.id.uuidString,
                "session_id": moved.sessionID,
                "attachment_id": moved.panel.id.uuidString,
                "attachment_token": "token",
                "cols": 100,
                "rows": 30,
                "allow_moved_surface": true,
            ],
            to: socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "remote_pty_error")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        let locatedWorkspaceId = appDelegate.workspaceContainingPanel(
            panelId: moved.panel.id,
            preferredWorkspaceId: moved.source.id
        )?.workspace.id.uuidString
        XCTAssertEqual(
            data["workspace_id"] as? String,
            moved.destination.id.uuidString,
            "source=\(moved.source.id.uuidString) destination=\(moved.destination.id.uuidString) " +
            "located=\(locatedWorkspaceId ?? "nil") " +
            "sourceActive=\(moved.source.surfaceIdFromPanelId(moved.panel.id) != nil) " +
            "destinationActive=\(moved.destination.surfaceIdFromPanelId(moved.panel.id) != nil)"
        )
        XCTAssertEqual(data["session_id"] as? String, moved.sessionID)
        XCTAssertEqual(data["attachment_id"] as? String, moved.panel.id.uuidString)
    }

    @Test func testRemotePTYBridgeRoutesMovedSurfaceToCurrentWorkspace() async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let socketPath = makeSocketPath("pty-bridge-move")
        let manager = TabManager()
        let moved = try makeMovedRemotePTYSurface(in: manager)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await sendV2RequestAsync(
            method: "workspace.remote.pty_bridge",
            params: [
                "workspace_id": moved.source.id.uuidString,
                "surface_id": moved.panel.id.uuidString,
                "session_id": moved.sessionID,
                "attachment_id": moved.panel.id.uuidString,
                "command": "",
                "require_existing": true,
                "allow_moved_surface": true,
            ],
            to: socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "remote_pty_error")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["workspace_id"] as? String, moved.destination.id.uuidString)
        XCTAssertEqual(data["session_id"] as? String, moved.sessionID)
        XCTAssertEqual(data["attachment_id"] as? String, moved.panel.id.uuidString)
    }

    @Test func testRemotePTYAllWorkspacesTreatsMissingPTYListAsUnsupported() {
        let unsupported = NSError(
            domain: "cmux.remote.daemon.rpc",
            code: 14,
            userInfo: [
                NSLocalizedDescriptionKey: "pty.list failed (method_not_found): Unknown method",
            ]
        )
        XCTAssertTrue(remotePTYSessionListErrorIsUnsupportedDaemon(unsupported))

        let notReady = NSError(
            domain: "cmux.remote.pty",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "remote daemon is not ready",
            ]
        )
        XCTAssertFalse(remotePTYSessionListErrorIsUnsupportedDaemon(notReady))

        let differentRPCMethod = NSError(
            domain: "cmux.remote.daemon.rpc",
            code: 14,
            userInfo: [
                NSLocalizedDescriptionKey: "pty.close failed (method_not_found): Unknown method",
            ]
        )
        XCTAssertFalse(remotePTYSessionListErrorIsUnsupportedDaemon(differentRPCMethod))
    }

    @Test func testNotificationCreateUsesExplicitSurfaceIDWhenProvided() async throws {
        let socketPath = makeSocketPath("notify-surface")
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }
        guard let targetPanel = workspace.newTerminalSplit(from: focusedPanelId, orientation: .horizontal) else {
            XCTFail("Expected split panel to be created")
            return
        }
        workspace.focusPanel(focusedPanelId)

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try self.sendV2Request(
                        method: "notification.create",
                        params: [
                            "workspace_id": workspace.id.uuidString,
                            "surface_id": targetPanel.id.uuidString,
                            "title": "Targeted"
                        ],
                        to: socketPath
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(result["surface_id"] as? String, targetPanel.id.uuidString)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: targetPanel.id))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }

    @Test func testPaneCreateStartupEnvironmentMarksManagedSubagentForRawNotificationSuppression() async throws {
        let socketPath = makeSocketPath("pane-env")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)
        let defaults = UserDefaults.standard
        let previousSuppressionDefault = defaults.object(forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)

        defaults.set(true, forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            if let previousSuppressionDefault {
                defaults.set(previousSuppressionDefault, forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)
            } else {
                defaults.removeObject(forKey: IntegrationsCatalogSection().suppressSubagentNotifications.userDefaultsKey)
            }
        }

        let sourcePanelId = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertFalse(workspace.suppressesRawTerminalNotification(panelId: sourcePanelId))

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await sendV2RequestAsync(
            method: "pane.create",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": sourcePanelId.uuidString,
                "direction": "right",
                "startup_environment": [
                    "CMUX_AGENT_MANAGED_SUBAGENT": "1"
                ]
            ],
            to: socketPath
        )

        XCTAssertEqual(response["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(response)")
        let result = try XCTUnwrap(response["result"] as? [String: Any], "Unexpected JSON-RPC response: \(response)")
        let newSurfaceIDString = try XCTUnwrap(result["surface_id"] as? String)
        let newSurfaceID = try XCTUnwrap(UUID(uuidString: newSurfaceIDString))
        let newPanel = try XCTUnwrap(workspace.panels[newSurfaceID] as? TerminalPanel)

        XCTAssertEqual(newPanel.surface.startupEnvironmentValue("CMUX_AGENT_MANAGED_SUBAGENT"), "1")
        XCTAssertTrue(workspace.suppressesRawTerminalNotification(panelId: newSurfaceID))
        XCTAssertFalse(workspace.suppressesRawTerminalNotification(panelId: sourcePanelId))
    }

    @Test func testSurfaceRelayRPCsReturnResolvedFocusedSurfaceWhenSurfaceIDOmitted() async throws {
        let socketPath = makeSocketPath("relay-fallback")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)

        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let reportTTYResponse = try await sendV2RequestAsync(
            method: "surface.report_tty",
            params: [
                "workspace_id": workspace.id.uuidString,
                "tty_name": "ttys999"
            ],
            to: socketPath
        )

        XCTAssertEqual(reportTTYResponse["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(reportTTYResponse)")
        let reportTTYResult = try XCTUnwrap(reportTTYResponse["result"] as? [String: Any], "Unexpected JSON-RPC response: \(reportTTYResponse)")
        XCTAssertEqual(reportTTYResult["surface_id"] as? String, focusedPanelId.uuidString)
        XCTAssertEqual(workspace.surfaceTTYNames[focusedPanelId], "ttys999")

        let portsKickResponse = try await sendV2RequestAsync(
            method: "surface.ports_kick",
            params: ["workspace_id": workspace.id.uuidString],
            to: socketPath
        )

        XCTAssertEqual(portsKickResponse["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(portsKickResponse)")
        let portsKickResult = try XCTUnwrap(portsKickResponse["result"] as? [String: Any], "Unexpected JSON-RPC response: \(portsKickResponse)")
        XCTAssertEqual(portsKickResult["surface_id"] as? String, focusedPanelId.uuidString)
    }

    @Test func testSurfaceRelayRPCsRejectExplicitUnknownSurfaceID() async throws {
        let socketPath = makeSocketPath("relay-invalid")
        let manager = TabManager()
        let workspace = manager.addWorkspace(select: true)

        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
        }

        let unknownSurfaceId = UUID()

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let reportTTYResponse = try await sendV2RequestAsync(
            method: "surface.report_tty",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": unknownSurfaceId.uuidString,
                "tty_name": "ttys999"
            ],
            to: socketPath
        )

        XCTAssertEqual(reportTTYResponse["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(reportTTYResponse)")
        let reportTTYError = try XCTUnwrap(reportTTYResponse["error"] as? [String: Any], "Unexpected JSON-RPC response: \(reportTTYResponse)")
        XCTAssertEqual(reportTTYError["code"] as? String, "not_found")
        let reportTTYData = try XCTUnwrap(reportTTYError["data"] as? [String: Any], "Expected error data payload")
        XCTAssertEqual(reportTTYData["surface_id"] as? String, unknownSurfaceId.uuidString)
        XCTAssertTrue(workspace.surfaceTTYNames.isEmpty)

        let portsKickResponse = try await sendV2RequestAsync(
            method: "surface.ports_kick",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": unknownSurfaceId.uuidString
            ],
            to: socketPath
        )

        XCTAssertEqual(portsKickResponse["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(portsKickResponse)")
        let portsKickError = try XCTUnwrap(portsKickResponse["error"] as? [String: Any], "Unexpected JSON-RPC response: \(portsKickResponse)")
        XCTAssertEqual(portsKickError["code"] as? String, "not_found")
        let portsKickData = try XCTUnwrap(portsKickError["data"] as? [String: Any], "Expected error data payload")
        XCTAssertEqual(portsKickData["surface_id"] as? String, unknownSurfaceId.uuidString)
    }

    @Test func testWorkspaceCloseRejectsPinnedWorkspace() async throws {
        let socketPath = makeSocketPath("close-pinned")
        let manager = TabManager()
        let pinnedWorkspace = manager.addWorkspace(select: false)
        manager.setPinned(pinnedWorkspace, pinned: true)

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let response = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try self.sendV2Request(
                        method: "workspace.close",
                        params: ["workspace_id": pinnedWorkspace.id.uuidString],
                        to: socketPath
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any], "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(error["code"] as? String, "protected")

        let data = try XCTUnwrap(error["data"] as? [String: Any], "Expected error data payload")
        XCTAssertEqual(data["workspace_id"] as? String, pinnedWorkspace.id.uuidString)
        XCTAssertEqual(data["pinned"] as? Bool, true)
        XCTAssertTrue(manager.tabs.contains(where: { $0.id == pinnedWorkspace.id }))
    }

    @Test func testV2SurfaceCloseCommandsRecordRecentlyClosedHistory() throws {
        ClosedItemHistoryStore.shared.removeAll()
        let defaults = UserDefaults.standard
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        BrowserAvailabilitySettings.setDisabled(true)
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            if let previousBrowserDisabled {
                defaults.set(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey)
            } else {
                defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
            }
            TerminalController.shared.setActiveTabManager(nil)
        }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let terminalPanel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true))
        workspace.setPanelCustomTitle(panelId: terminalPanel.id, title: "Socket Terminal")
        let browserPanel = try XCTUnwrap(workspace.newBrowserSurface(
            inPane: pane,
            focus: true,
            creationPolicy: .restoration
        ))
        workspace.setPanelCustomTitle(panelId: browserPanel.id, title: "Socket Browser")
        TerminalController.shared.setActiveTabManager(manager)

        let terminalClose = try handleV2Request(
            method: "surface.close",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": terminalPanel.id.uuidString
            ]
        )
        XCTAssertEqual(terminalClose["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(terminalClose)")
        XCTAssertNil(workspace.panels[terminalPanel.id])

        let browserClose = try handleV2Request(
            method: "browser.tab.close",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": browserPanel.id.uuidString
            ]
        )
        XCTAssertEqual(browserClose["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(browserClose)")
        XCTAssertNil(workspace.panels[browserPanel.id])

        XCTAssertEqual(
            ClosedItemHistoryStore.shared.menuSnapshot().items.map(\.title),
            ["Socket Browser", "Socket Terminal"]
        )
    }

    @Test func testBrowserOpenSplitDoesNotExternallyOpenDiffViewerWhenBrowserDisabled() throws {
        let defaults = UserDefaults.standard
        let previousBrowserDisabled = defaults.object(forKey: BrowserAvailabilitySettings.disabledKey)
        BrowserAvailabilitySettings.setDisabled(true)
        defer {
            if let previousBrowserDisabled {
                defaults.set(previousBrowserDisabled, forKey: BrowserAvailabilitySettings.disabledKey)
            } else {
                defaults.removeObject(forKey: BrowserAvailabilitySettings.disabledKey)
            }
            TerminalController.shared.setActiveTabManager(nil)
        }

        TerminalController.shared.setActiveTabManager(TabManager())
        let token = UUID().uuidString.lowercased()
        let response = try handleV2Request(
            method: "browser.open_split",
            params: [
                "url": "\(CmuxDiffViewerURLSchemeHandler.scheme)://\(token)/diff.html",
                "diff_viewer_token": token
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any], "Unexpected JSON-RPC response: \(response)")
        XCTAssertEqual(error["code"] as? String, "browser_disabled")
    }

    @Test func browserZoomSetReportsRenderLimitDetailsForOversizedViewportCombination() throws {
        let manager = TabManager()
        defer {
            manager.tabs.forEach { $0.teardownAllPanels() }
            TerminalController.shared.setActiveTabManager(nil)
        }

        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let browserPanel = try XCTUnwrap(workspace.newBrowserSurface(
            inPane: pane,
            focus: true,
            creationPolicy: .restoration
        ))
        TerminalController.shared.setActiveTabManager(manager)

        let viewportResponse = try handleV2Request(
            method: "browser.viewport.set",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": browserPanel.id.uuidString,
                "width": 4_096,
                "height": 4_096,
            ]
        )
        XCTAssertEqual(viewportResponse["ok"] as? Bool, true, "Unexpected JSON-RPC response: \(viewportResponse)")
        XCTAssertTrue(browserPanel.setPageZoomFactor(1.4))

        let response = try handleV2Request(
            method: "browser.zoom.set",
            params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": browserPanel.id.uuidString,
                "direction": "in",
            ]
        )

        XCTAssertEqual(response["ok"] as? Bool, false, "Unexpected JSON-RPC response: \(response)")
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalid_params")
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["reason"] as? String, "viewport_zoom_render_geometry_too_large")
        let requestedPageZoom = try XCTUnwrap(data["requested_page_zoom"] as? Double)
        let maximumPageZoom = try XCTUnwrap(data["maximum_page_zoom"] as? Double)
        #expect(abs(requestedPageZoom - 1.5) < 0.000_001)
        #expect(abs(maximumPageZoom - 2.0.squareRoot()) < 0.000_001)
        #expect(abs(browserPanel.currentPageZoomFactor() - 1.4) < 0.000_001)
    }

    @Test func testLegacyCloseSurfaceCommandRecordsRecentlyClosedHistory() throws {
        ClosedItemHistoryStore.shared.removeAll()
        defer {
            ClosedItemHistoryStore.shared.removeAll()
            TerminalController.shared.setActiveTabManager(nil)
        }

        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let pane = try XCTUnwrap(workspace.bonsplitController.allPaneIds.first)
        let panel = try XCTUnwrap(workspace.newTerminalSurface(inPane: pane, focus: true))
        workspace.setPanelCustomTitle(panelId: panel.id, title: "Legacy Socket Terminal")
        TerminalController.shared.setActiveTabManager(manager)

        let response = TerminalController.shared.handleSocketLine("close_surface \(panel.id.uuidString)")

        XCTAssertEqual(response, "OK")
        XCTAssertNil(workspace.panels[panel.id])
        XCTAssertEqual(
            ClosedItemHistoryStore.shared.menuSnapshot().items.map(\.title),
            ["Legacy Socket Terminal"]
        )
    }

    private func waitForSocket(at path: String, timeout: TimeInterval = 5.0) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        XCTFail("Timed out waiting for socket at \(path)")
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
    }

    private func socketMode(at path: String) throws -> UInt16 {
        var fileInfo = stat()
        guard lstat(path, &fileInfo) == 0 else {
            throw posixError("lstat(\(path))")
        }
        return UInt16(fileInfo.st_mode & 0o777)
    }

    private func sendCommands(_ commands: [String], to socketPath: String) throws -> [String] {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket(AF_UNIX)")
        }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(socketPath.utf8)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < maxPathLen else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let cPath = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
            cPath.initialize(repeating: 0, count: maxPathLen)
            for (index, byte) in bytes.enumerated() {
                cPath[index] = CChar(bitPattern: byte)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            throw posixError("connect(\(socketPath))")
        }

        var responses: [String] = []
        for command in commands {
            try writeLine(command, to: fd)
            responses.append(try readLine(from: fd))
        }
        return responses
    }

    private func makeV2RequestLine(method: String, params: [String: Any]) throws -> String {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func makeMovedRemotePTYSurface(
        in manager: TabManager
    ) throws -> (source: Workspace, destination: Workspace, panel: TerminalPanel, sessionID: String) {
        let source = manager.addWorkspace(select: true)
        let destination = manager.addWorkspace(select: false)
        let config = WorkspaceRemoteConfiguration(
            destination: "cmux-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64011,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/cmux-debug-test.sock",
            terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        source.configureRemoteConnection(config, autoConnect: false)
        destination.configureRemoteConnection(config, autoConnect: false)

        let sourcePanelID = try XCTUnwrap(source.focusedTerminalPanel?.id)
        let destinationPaneID = try XCTUnwrap(destination.bonsplitController.allPaneIds.first)
        let sessionID = "moved-surface-session"
        let panel = try XCTUnwrap(
            source.newTerminalSplit(
                from: sourcePanelID,
                orientation: .horizontal,
                initialCommand: nil,
                remotePTYSessionID: sessionID
            )
        )
        let detached = try XCTUnwrap(source.detachSurface(panelId: panel.id))
        XCTAssertEqual(detached.remotePTYSessionID, sessionID)
        XCTAssertEqual(
            destination.attachDetachedSurface(detached, inPane: destinationPaneID, focus: false),
            panel.id
        )
        XCTAssertTrue(destination.isRemoteTerminalSurface(panel.id))

        return (source, destination, panel, sessionID)
    }

    private func decodeV2Envelope(_ raw: String) throws -> [String: Any] {
        let data = try XCTUnwrap(raw.data(using: .utf8))
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "Expected JSON-RPC response object"
        )
    }

    private func handleV2Request(
        method: String,
        params: [String: Any]
    ) throws -> [String: Any] {
        let requestLine = try makeV2RequestLine(method: method, params: params)
        return try decodeV2Envelope(TerminalController.shared.handleSocketLine(requestLine))
    }

    private func assertUnsupportedWorkspaceWindowAlias(
        _ envelope: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(envelope["ok"] as? Bool, false, file: file, line: line)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(error["code"] as? String, "invalid_params", file: file, line: line)
        let data = try XCTUnwrap(error["data"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(data["unsupported_param"] as? String, "window", file: file, line: line)
        XCTAssertEqual(data["supported_param"] as? String, "window_id", file: file, line: line)
    }

    private nonisolated func sendV2Request(
        method: String,
        params: [String: Any],
        to socketPath: String
    ) throws -> [String: Any] {
        let fd = try connect(to: socketPath)
        defer { Darwin.close(fd) }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode JSON-RPC request"
            ])
        }
        try writeLine(line, to: fd)

        let responseLine = try readLine(from: fd)
        let responseData = Data(responseLine.utf8)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            "Expected JSON-RPC response object"
        )
    }

    private func sendV2RequestAsync(
        method: String,
        params: [String: Any],
        to socketPath: String
    ) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try self.sendV2Request(
                        method: method,
                        params: params,
                        to: socketPath
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// v1 twin of `sendV2Request`: one connection, newline-delimited v1
    /// commands, one reply line each. Nonisolated so `sendV1CommandsAsync`
    /// can run it on a global queue while the main actor stays free.
    private nonisolated func sendV1Commands(_ commands: [String], to socketPath: String) throws -> [String] {
        let fd = try connect(to: socketPath)
        defer { Darwin.close(fd) }
        var responses: [String] = []
        for command in commands {
            try writeLine(command, to: fd)
            responses.append(try readLine(from: fd))
        }
        return responses
    }

    /// v1 twin of `sendV2RequestAsync`: main-lane v1 commands need the main
    /// thread free for their `DispatchQueue.main.sync` hop, so the blocking
    /// socket round-trip runs on a global queue and the main-actor test
    /// awaits the result.
    private func sendV1CommandsAsync(_ commands: [String], to socketPath: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.sendV1Commands(commands, to: socketPath))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated func connect(to socketPath: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket(AF_UNIX)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(socketPath.utf8)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < maxPathLen else {
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let cPath = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
            cPath.initialize(repeating: 0, count: maxPathLen)
            for (index, byte) in bytes.enumerated() {
                cPath[index] = CChar(bitPattern: byte)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            let error = posixError("connect(\(socketPath))")
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private nonisolated func writeLine(_ command: String, to fd: Int32) throws {
        let payload = Array((command + "\n").utf8)
        var offset = 0
        while offset < payload.count {
            let wrote = payload.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            guard wrote >= 0 else {
                throw posixError("write(\(command))")
            }
            offset += wrote
        }
    }

    private nonisolated func readLine(from fd: Int32) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 1)
        var data = Data()

        while true {
            let count = Darwin.read(fd, &buffer, 1)
            guard count >= 0 else {
                throw posixError("read")
            }
            if count == 0 { break }
            if buffer[0] == 0x0A { break }
            data.append(buffer[0])
        }

        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Invalid UTF-8 response from socket"
            ])
        }
        return line
    }

    private func makeExistingAgentSocketPath() throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("agent.sock")
        XCTAssertTrue(
            FileManager.default.createFile(atPath: url.path, contents: Data()),
            "Expected to create \(url.path)"
        )
        return url.path
    }

    private func agentReportRequest(
        workspace: Workspace,
        panel: TerminalPanel,
        raw: String?
    ) -> AgentReportCaptureRequest {
        AgentReportCaptureRequest(
            provider: .codex,
            workspaceID: workspace.id,
            runtimeSurfaceID: panel.id,
            agentSessionID: "lifecycle-session",
            turnID: "lifecycle-turn",
            completionKind: .primaryStop,
            transcriptPath: "/synthetic/lifecycle.jsonl",
            rawFinalReply: raw,
            completionTimestamp: Date(timeIntervalSince1970: 100)
        )
    }

    private func agentReportTarget(
        workspace: Workspace,
        panel: TerminalPanel
    ) -> AgentReportCaptureTarget {
        AgentReportCaptureTarget(
            workspaceID: workspace.id,
            runtimeSurfaceID: panel.id,
            stableSurfaceID: panel.stableSurfaceId,
            agentSessionID: "lifecycle-session",
            turnID: "lifecycle-turn",
            lifecycleToken: UUID(),
            transcriptPath: "/synthetic/lifecycle.jsonl"
        )
    }

    private func performTrueRemoval(
        _ removalPath: String,
        manager: TabManager,
        workspace: Workspace,
        panel: TerminalPanel
    ) throws {
        switch removalPath {
        case "tab":
            #expect(workspace.closePanel(panel.id, force: true))
        case "pane":
            _ = try #require(
                workspace.newTerminalSplit(from: panel.id, orientation: .horizontal)
            )
            let pane = try #require(workspace.paneId(forPanelId: panel.id))
            #expect(workspace.bonsplitController.closePane(pane))
        case "workspace":
            _ = manager.addWorkspace(select: false)
            manager.closeWorkspace(workspace, recordHistory: false)
        default:
            Issue.record("Unknown true-removal test path")
        }
    }

    private nonisolated func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}

private actor SuspendedEndpointAgentReportRecovery: AgentReportTranscriptRecovering {
    private let reply: String
    private var recoveryStarted = false
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
        recoveryStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { recoveryContinuation = $0 }
    }

    func waitUntilRecoveryStarted() async {
        if recoveryStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func resumeRecovery() {
        recoveryContinuation?.resume(returning: reply)
        recoveryContinuation = nil
    }
}

private actor QueuedAgentReportInvalidationGate {
    private var queuedCount = 0
    private var queuedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func enqueue(surfaceID: UUID, store: AgentReportCaptureStore) async {
        queuedCount += 1
        let waiters = queuedWaiters
        queuedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !isReleased {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        await store.invalidatePendingCapture(runtimeSurfaceID: surfaceID)
    }

    func waitUntilQueued() async {
        if queuedCount > 0 { return }
        await withCheckedContinuation { queuedWaiters.append($0) }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

/// Cross-thread reply capture for the worker-lane-while-main-blocked tests:
/// the background sender stores exactly once before signaling its semaphore,
/// and the main-actor test reads only after that signal. The lock makes the
/// handoff explicit instead of relying on the semaphore's happens-before
/// alone.
private final class WorkerLaneReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[String], Error>?

    func store(_ result: Result<[String], Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func take() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let result else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
        }
        return try result.get()
    }
}
