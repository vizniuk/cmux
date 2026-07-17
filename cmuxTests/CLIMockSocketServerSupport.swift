import XCTest
import Darwin

extension CMUXOpenCommandTests {
    func openTypedDiffSession(payload: [String: Any], cliPath: String) throws -> String {
        let source = try XCTUnwrap(payload["sessionSource"] as? [String: Any])
        let token = try XCTUnwrap(payload["capabilityToken"] as? String)
        let sidecarURL = URL(fileURLWithPath: cliPath)
            .deletingLastPathComponent()
            .appendingPathComponent("cmux-diff-sidecar", isDirectory: false)
        let rootURL = URL(fileURLWithPath: "/tmp/cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
        let request: [String: Any] = [
            "id": "xctest-session",
            "version": 1,
            "method": "sessionOpen",
            "params": ["source": source, "capabilityToken": token],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let result = runProcess(
            executablePath: sidecarURL.path,
            arguments: ["rpc", "--root", rootURL.path, "--cmux", cliPath],
            environment: ProcessInfo.processInfo.environment,
            timeout: 15,
            stdinText: String(decoding: requestData, as: UTF8.self)
        )
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        if let error = response["error"] as? [String: Any],
           error["code"] as? String == "emptyDiff" {
            return ""
        }
        let opened = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(opened["type"] as? String, "sessionOpened")
        let value = try XCTUnwrap(opened["value"] as? [String: Any])
        let patchRef = try XCTUnwrap(value["patch"] as? [String: Any])
        let patchID = try XCTUnwrap(patchRef["id"] as? String)
        let patchURL = try XCTUnwrap(URL(string: patchID))
        let patch = try String(
            contentsOf: rootURL.appendingPathComponent(
                patchURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ),
            encoding: .utf8
        )
        if let sessionID = value["sessionId"] as? String {
            let close: [String: Any] = [
                "id": "xctest-session-close",
                "version": 1,
                "method": "sessionClose",
                "params": ["sessionId": sessionID, "capabilityToken": token],
            ]
            if let closeData = try? JSONSerialization.data(withJSONObject: close) {
                _ = runProcess(
                    executablePath: sidecarURL.path,
                    arguments: ["rpc", "--root", rootURL.path, "--cmux", cliPath],
                    environment: ProcessInfo.processInfo.environment,
                    timeout: 15,
                    stdinText: String(decoding: closeData, as: UTF8.self)
                )
            }
        }
        return patch
    }

    func resolvedDiffViewerHTMLFileURL(_ fileURL: URL, from params: [String: Any]) throws -> URL {
        var current = fileURL
        for _ in 0..<4 {
            let html = try String(contentsOf: current, encoding: .utf8)
            guard let redirectURL = Self.diffViewerRedirectURL(from: html) else {
                return current
            }
            current = try diffViewerHTMLFileURL(for: redirectURL, from: params)
        }
        return current
    }

    private static func diffViewerRedirectURL(from html: String) -> String? {
        let marker = "data-cmux-diff-redirect=\""
        guard let start = html.range(of: marker)?.upperBound else { return nil }
        let tail = html[start...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

extension CLINotifyProcessIntegrationRegressionTests {
    // Protects a test-owned DispatchGroup and duplicated listener FD lifecycle
    // driven by blocking Darwin socket calls on a background queue. The caller's
    // listener remains reusable while this object owns and joins its accept loop.
    private final class DeterministicMockSocketServer: @unchecked Sendable {
        private let lock = NSLock()
        private let group = DispatchGroup()
        private let handlerGroup = DispatchGroup()
        private let handlerQueue = DispatchQueue(
            label: "com.cmux.tests.cli-mock-socket.handler",
            qos: .userInitiated,
            attributes: .concurrent
        )
        private let listenerFD: Int32
        private let expectedConnections: Int
        private let state: MockSocketServerState
        private let strictConnectionCount: Bool
        private let fulfillWhen: (@Sendable (String) -> Bool)?
        private let handler: @Sendable (String) -> String?
        private let handled: XCTestExpectation?
        private let startedAt = Date()

        private var acceptedConnections = 0
        private var handledConnections = 0
        private var framedRequests = 0
        private var attemptedResponses = 0
        private var completedResponses = 0
        private var activeHandlers = 0
        private var activeClientFDs = Set<Int32>()
        private var observedMethods: [String] = []
        private var lastStage = "created"
        private var terminalFailure: String?
        private var terminalCompletionObserved = false
        private var listenerClosed = false
        private var acceptLoopFinished = false
        private var didFulfill = false
        private var isStopping = false

        init(
            listenerFD: Int32,
            expectedConnections: Int,
            state: MockSocketServerState,
            strictConnectionCount: Bool,
            handled: XCTestExpectation?,
            fulfillWhen: (@Sendable (String) -> Bool)?,
            handler: @escaping @Sendable (String) -> String?
        ) {
            let duplicatedListenerFD: Int32
            let duplicatedListenerErrno: Int32
            if listenerFD >= 0 {
                duplicatedListenerFD = Darwin.dup(listenerFD)
                duplicatedListenerErrno = errno
            } else {
                duplicatedListenerFD = -1
                duplicatedListenerErrno = EBADF
            }

            self.listenerFD = duplicatedListenerFD
            self.expectedConnections = max(1, expectedConnections)
            self.state = state
            self.strictConnectionCount = strictConnectionCount
            self.handled = handled
            self.fulfillWhen = fulfillWhen
            self.handler = handler
            if listenerFD < 0 {
                recordTerminalFailure(stage: "listener", detail: "invalid-fd")
            } else if duplicatedListenerFD < 0 {
                recordTerminalFailure(stage: "listener", detail: "dup-errno=\(duplicatedListenerErrno)")
            }
        }

        func start() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                self.runAcceptLoop()
                self.group.leave()
            }
        }

        func shutdownAndWait(recordIncomplete: Bool, file: StaticString = #filePath, line: UInt = #line) {
            requestStop(stage: "teardown")
            if group.wait(timeout: .now() + 2) == .timedOut {
                XCTFail("cli mock socket teardown timeout; \(safeDiagnostics())", file: file, line: line)
                return
            }
            if recordIncomplete && !isComplete {
                XCTFail("cli mock socket incomplete at teardown; \(safeDiagnostics())", file: file, line: line)
            }
        }

        private var isComplete: Bool {
            lock.lock()
            defer { lock.unlock() }
            let reachedConnectionCount = acceptedConnections == expectedConnections
                && handledConnections == expectedConnections
            return terminalFailure == nil
                && reachedConnectionCount
                && activeHandlers == 0
                && acceptLoopFinished
        }

        private func runAcceptLoop() {
            guard listenerFD >= 0 else {
                finishAcceptLoop()
                fulfillHandledIfCompleteOrFailed()
                return
            }

            while true {
                lock.lock()
                let shouldStop = isStopping
                    || terminalFailure != nil
                    || acceptedConnections >= expectedConnections
                lock.unlock()
                if shouldStop { break }

                recordStage("accept.wait")
                var clientAddr = sockaddr_un()
                var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                        Darwin.accept(listenerFD, sockaddrPtr, &clientAddrLen)
                    }
                }
                if clientFD < 0 {
                    let acceptErrno = errno
                    if acceptErrno == EINTR { continue }
                    if isStoppingSnapshot {
                        break
                    }
                    if Self.isListenerClosedAcceptErrno(acceptErrno) {
                        markListenerExternallyClosed()
                    } else {
                        recordTerminalFailure(stage: "accept", detail: "errno=\(acceptErrno)")
                    }
                    break
                }

                recordAcceptedConnection()
                startConnectionHandler(clientFD)
            }

            finishAcceptLoop()
            handlerGroup.wait()
            fulfillHandledIfCompleteOrFailed()
        }

        private var isStoppingSnapshot: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isStopping
        }

        private func startConnectionHandler(_ clientFD: Int32) {
            registerClientFD(clientFD)
            recordHandlerStarted()
            handlerGroup.enter()
            handlerQueue.async {
                self.handleConnection(clientFD)
                self.recordHandlerFinished()
                self.handlerGroup.leave()
            }
        }

        private func handleConnection(_ clientFD: Int32) {
            defer {
                unregisterClientFD(clientFD)
                Darwin.close(clientFD)
                recordHandledConnection()
            }

            recordStage("request.read")
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = Darwin.read(clientFD, &buffer, buffer.count)
                if count < 0 {
                    let readErrno = errno
                    if readErrno == EINTR { continue }
                    recordTerminalFailure(stage: "request.read", detail: "errno=\(readErrno)")
                    return
                }
                if count == 0 {
                    recordStage("connection.eof")
                    return
                }
                pending.append(buffer, count: count)

                while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                    let lineData = pending.subdata(in: 0..<newlineRange.lowerBound)
                    pending.removeSubrange(0...newlineRange.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else {
                        recordTerminalFailure(stage: "request.decode", detail: "invalid-utf8")
                        continue
                    }
                    state.append(line)
                    let method = Self.safeMethodName(from: line)
                    recordFramedRequest(method: method)

                    if fulfillWhen?(line) == true {
                        recordTerminalCompletion(stage: "request.fulfill-marker")
                    }

                    if Self.isOneWayFeedTelemetry(line) {
                        recordStage("request.one-way-feed")
                        continue
                    }

                    guard let responsePayload = handler(line) else {
                        continue
                    }
                    if !writeCompleteResponse(responsePayload, to: clientFD) {
                        return
                    }
                }
            }
        }

        private func writeCompleteResponse(_ responsePayload: String, to clientFD: Int32) -> Bool {
            recordResponseAttempt()
            var data = Data(responsePayload.utf8)
            data.append(0x0A)
            do {
                try data.withUnsafeBytes { rawBuffer in
                    guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                    var remaining = rawBuffer.count
                    var cursor = base
                    while remaining > 0 {
                        let written = Darwin.write(clientFD, cursor, remaining)
                        if written > 0 {
                            remaining -= written
                            cursor = cursor.advanced(by: written)
                        } else if written < 0 && errno == EINTR {
                            continue
                        } else {
                            throw NSError(domain: "cmux.tests.mock-socket", code: Int(errno), userInfo: nil)
                        }
                    }
                }
                recordResponseCompleted()
                return true
            } catch {
                let errorCode = (error as NSError).code
                recordTerminalFailure(stage: "response.write", detail: "errno=\(errorCode)")
                return false
            }
        }

        private func requestStop(stage: String) {
            let shouldClose: Bool
            lock.lock()
            isStopping = true
            lastStage = stage
            shouldClose = !acceptLoopFinished
            lock.unlock()
            if shouldClose {
                closeListener()
            }
            shutdownActiveClientConnections()
        }

        private func closeListener() {
            lock.lock()
            let shouldClose = !listenerClosed && listenerFD >= 0
            if shouldClose {
                listenerClosed = true
            }
            lock.unlock()

            guard shouldClose else { return }
            _ = Darwin.shutdown(listenerFD, SHUT_RDWR)
            Darwin.close(listenerFD)
        }

        private func markListenerExternallyClosed() {
            lock.lock()
            listenerClosed = true
            lock.unlock()
        }

        private func fulfillHandledIfCompleteOrFailed() {
            let expectation: XCTestExpectation?
            lock.lock()
            let shouldFulfill = terminalFailure != nil
                || (acceptedConnections == expectedConnections
                    && handledConnections == expectedConnections
                    && activeHandlers == 0
                    && acceptLoopFinished)
            if didFulfill || !shouldFulfill {
                expectation = nil
            } else {
                didFulfill = true
                expectation = handled
            }
            lock.unlock()
            expectation?.fulfill()
        }

        private func finishAcceptLoop() {
            lock.lock()
            acceptLoopFinished = true
            if terminalFailure == nil,
               !isStopping,
               acceptedConnections != expectedConnections {
                terminalFailure = "connection-count"
                lastStage = "connection-count"
            }
            lock.unlock()
            closeListener()
        }

        private func recordAcceptedConnection() {
            lock.lock()
            acceptedConnections += 1
            lastStage = "connection.accepted"
            lock.unlock()
        }

        private func recordHandledConnection() {
            lock.lock()
            handledConnections += 1
            lastStage = "connection.closed"
            lock.unlock()
        }

        private func recordHandlerStarted() {
            lock.lock()
            activeHandlers += 1
            lastStage = "handler.started"
            lock.unlock()
        }

        private func recordHandlerFinished() {
            lock.lock()
            activeHandlers -= 1
            lastStage = "handler.finished"
            lock.unlock()
        }

        private func registerClientFD(_ clientFD: Int32) {
            lock.lock()
            activeClientFDs.insert(clientFD)
            lock.unlock()
        }

        private func unregisterClientFD(_ clientFD: Int32) {
            lock.lock()
            activeClientFDs.remove(clientFD)
            lock.unlock()
        }

        private func shutdownActiveClientConnections() {
            lock.lock()
            let fds = Array(activeClientFDs)
            lock.unlock()
            for fd in fds {
                _ = Darwin.shutdown(fd, SHUT_RDWR)
            }
        }

        private func recordFramedRequest(method: String) {
            lock.lock()
            framedRequests += 1
            observedMethods.append(method)
            lastStage = "request.framed"
            lock.unlock()
        }

        private func recordResponseAttempt() {
            lock.lock()
            attemptedResponses += 1
            lastStage = "response.write"
            lock.unlock()
        }

        private func recordResponseCompleted() {
            lock.lock()
            completedResponses += 1
            lastStage = "response.complete"
            lock.unlock()
        }

        private func recordStage(_ stage: String) {
            lock.lock()
            lastStage = stage
            lock.unlock()
        }

        private func recordTerminalFailure(stage: String, detail: String) {
            lock.lock()
            terminalFailure = "\(stage):\(detail)"
            lastStage = stage
            lock.unlock()
        }

        private func recordTerminalCompletion(stage: String) {
            lock.lock()
            terminalCompletionObserved = true
            lastStage = stage
            lock.unlock()
        }

        /// Returns timeout diagnostics that intentionally exclude raw request
        /// payloads, transcripts, command text, secrets, full session ids, and
        /// provider identifiers. Keep this summary to lifecycle state and method
        /// names only so failing hook tests cannot leak private user content.
        private func safeDiagnostics() -> String {
            lock.lock()
            let elapsed = Date().timeIntervalSince(startedAt)
            let methods = observedMethods.joined(separator: ",")
            let summary = [
                "stage=\(lastStage)",
                "expectedConnections=\(expectedConnections)",
                "acceptedConnections=\(acceptedConnections)",
                "handledConnections=\(handledConnections)",
                "activeHandlers=\(activeHandlers)",
                "framedRequests=\(framedRequests)",
                "methods=[\(methods)]",
                "responses=\(completedResponses)/\(attemptedResponses)",
                "strictConnectionCount=\(strictConnectionCount)",
                "terminalCompletionObserved=\(terminalCompletionObserved)",
                "listenerClosed=\(listenerClosed)",
                "acceptLoopFinished=\(acceptLoopFinished)",
                "terminalFailure=\(terminalFailure ?? "none")",
                "elapsed=\(String(format: "%.3f", elapsed))s",
            ].joined(separator: " ")
            lock.unlock()
            return summary
        }

        private static func safeMethodName(from line: String) -> String {
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                return "non-json"
            }
            guard let method = payload["method"] as? String else {
                return "missing-method"
            }
            return method
        }

        private static func isOneWayFeedTelemetry(_ line: String) -> Bool {
            guard let data = line.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                  payload["id"] == nil,
                  payload["method"] as? String == "feed.push",
                  let params = payload["params"] as? [String: Any],
                  let waitTimeout = params["wait_timeout_seconds"] as? NSNumber else {
                return false
            }
            return waitTimeout.doubleValue == 0
        }

        private static func isListenerClosedAcceptErrno(_ errnoValue: Int32) -> Bool {
            errnoValue == EBADF || errnoValue == EINVAL || errnoValue == ENOTSOCK || errnoValue == ECONNABORTED
        }
    }

    func startMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int = 1,
        strictConnectionCount: Bool = false,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String
    ) -> XCTestExpectation {
        startMockServerAllowingNoResponse(
            listenerFD: listenerFD,
            state: state,
            connectionCount: connectionCount,
            strictConnectionCount: strictConnectionCount,
            fulfillWhen: fulfillWhen
        ) { line in
            handler(line)
        }
    }

    func startMockServerAllowingNoResponse(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int = 1,
        strictConnectionCount: Bool = false,
        fulfillWhen: (@Sendable (String) -> Bool)? = nil,
        handler: @escaping @Sendable (String) -> String?
    ) -> XCTestExpectation {
        let handled = expectation(description: "cli mock socket handled")
        let server = DeterministicMockSocketServer(
            listenerFD: listenerFD,
            expectedConnections: connectionCount,
            state: state,
            strictConnectionCount: strictConnectionCount,
            handled: handled,
            fulfillWhen: fulfillWhen,
            handler: handler
        )
        server.start()
        addTeardownBlock {
            server.shutdownAndWait(recordIncomplete: true)
        }
        return handled
    }

    func startDetachedMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        connectionCount: Int = 1,
        handler: @escaping @Sendable (String) -> String
    ) {
        let server = DeterministicMockSocketServer(
            listenerFD: listenerFD,
            expectedConnections: connectionCount,
            state: state,
            strictConnectionCount: false,
            handled: nil,
            fulfillWhen: nil
        ) { line in
            handler(line)
        }
        server.start()
        addTeardownBlock {
            server.shutdownAndWait(recordIncomplete: false)
        }
    }

    func startAgentHookMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        surfaceId: String,
        connectionCount: Int
    ) -> XCTestExpectation {
        startMockServer(listenerFD: listenerFD, state: state, connectionCount: connectionCount) { line in
            self.agentHookMockResponse(line: line, surfaceId: surfaceId)
        }
    }

    func startDetachedAgentHookMockServer(
        listenerFD: Int32,
        state: MockSocketServerState,
        surfaceId: String,
        connectionCount: Int
    ) {
        startDetachedMockServer(listenerFD: listenerFD, state: state, connectionCount: connectionCount) { line in
            self.agentHookMockResponse(line: line, surfaceId: surfaceId)
        }
    }

    func assertSSHPTYAttachOmitsSurfaceArgument(
        _ script: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            script.contains(#"ssh-pty-attach --wait --workspace "$cmux_ssh_pty_workspace_id" --surface"#),
            script,
            file: file,
            line: line
        )
    }

    private func agentHookMockResponse(line: String, surfaceId: String) -> String {
        guard let payload = jsonObject(line) else {
            return "OK"
        }
        guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
            return malformedRequestResponse(id: payload["id"] as? String, raw: line)
        }
        switch method {
        case "surface.list":
            return surfaceListResponse(id: id, surfaceId: surfaceId)
        case "feed.push":
            return v2Response(id: id, ok: true, result: [:])
        default:
            return v2Response(id: id, ok: false, error: ["code": "unrecognized_method", "message": "unexpected method: \(method)"])
        }
    }
}
