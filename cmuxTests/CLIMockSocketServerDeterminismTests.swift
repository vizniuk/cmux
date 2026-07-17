import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testMockSocketServerWaitsForAllExpectedConnectionsAndDoesNotLeakWorker() throws {
        let socketPath = makeSocketPath("deterministic-lifetime")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = MockSocketServerState()
        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 2
        ) { line in
            "server-one:\(line)"
        }

        let firstResponse = try cliMockSocketRoundTrip(
            socketPath: socketPath,
            requestFragments: ["first-request\n"]
        )
        XCTAssertEqual(firstResponse, "server-one:first-request\n")

        let earlyResult = XCTWaiter().wait(for: [serverHandled], timeout: 0.25)
        if earlyResult == .completed {
            let leakedResponse = try cliMockSocketRoundTrip(
                socketPath: socketPath,
                requestFragments: ["second-request\n"]
            )
            XCTFail(
                "Mock server completed after 1/2 expected connections; a later request still reached the completed server and received \(leakedResponse.debugDescription)."
            )
            return
        }
        XCTAssertEqual(earlyResult, .timedOut)

        let secondResponse = try cliMockSocketRoundTrip(
            socketPath: socketPath,
            requestFragments: ["second-request\n"]
        )
        XCTAssertEqual(secondResponse, "server-one:second-request\n")
        XCTAssertEqual(XCTWaiter().wait(for: [serverHandled], timeout: 2), .completed)
        XCTAssertEqual(state.snapshot(), ["first-request", "second-request"])
    }

    func testMockSocketServerReadsSplitRequestLineBeforeHandling() throws {
        let socketPath = makeSocketPath("deterministic-read")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = MockSocketServerState()
        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 1
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  payload["method"] as? String == "surface.list" else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.surfaceListResponse(id: id, surfaceId: "surface-from-split-request")
        }

        let response = try cliMockSocketRoundTrip(
            socketPath: socketPath,
            requestFragments: [
                #"{"id":"split-read","version":1,"m"#,
                #"ethod":"surface.list","params":{}}"#,
                "\n",
            ]
        )
        XCTAssertEqual(XCTWaiter().wait(for: [serverHandled], timeout: 2), .completed)
        XCTAssertEqual(state.snapshot().count, 1)

        let responseData = try XCTUnwrap(response.data(using: .utf8))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        XCTAssertEqual(payload["id"] as? String, "split-read")
        XCTAssertEqual(payload["ok"] as? Bool, true)
        let result = try XCTUnwrap(payload["result"] as? [String: Any])
        let surfaces = try XCTUnwrap(result["surfaces"] as? [[String: Any]])
        XCTAssertEqual(surfaces.first?["id"] as? String, "surface-from-split-request")
    }

    func testMockSocketServerHandlesMultipleLinesOnOneConnection() throws {
        let socketPath = makeSocketPath("deterministic-lines")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = MockSocketServerState()
        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 1
        ) { line in
            "ack:\(line)"
        }

        let responses = try cliMockSocketRoundTrips(
            socketPath: socketPath,
            requestFragments: ["first-line\nsecond-line\n"],
            expectedResponseLineCount: 2
        )
        XCTAssertEqual(responses, "ack:first-line\nack:second-line\n")
        XCTAssertEqual(XCTWaiter().wait(for: [serverHandled], timeout: 2), .completed)
        XCTAssertEqual(state.snapshot(), ["first-line", "second-line"])
    }

    func testMockSocketServerAcknowledgesContentFreeHookCommand() throws {
        let socketPath = makeSocketPath("deterministic-ack")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = MockSocketServerState()
        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 1
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return "OK"
            }
            return self.v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected_json", "message": "unexpected method: \(method)"]
            )
        }

        let response = try cliMockSocketRoundTrip(
            socketPath: socketPath,
            requestFragments: ["clear_notifications --tab=workspace:1 --panel=surface:1\n"]
        )
        XCTAssertEqual(response, "OK\n")
        XCTAssertEqual(XCTWaiter().wait(for: [serverHandled], timeout: 2), .completed)
        XCTAssertEqual(state.snapshot(), ["clear_notifications --tab=workspace:1 --panel=surface:1"])
    }

    func testClaudePredecessorThenStaleStopSequenceDoesNotLoseMockSocketCompletion() throws {
        try testClaudeSessionStartRecordIsNotRestorableUntilPrompt()
        try testClaudeStaleStopFromClosedPaneStaysStaleWhenSurfaceResolutionFallsBack()
    }

    private func cliMockSocketRoundTrip(
        socketPath: String,
        requestFragments: [String]
    ) throws -> String {
        try cliMockSocketRoundTrips(
            socketPath: socketPath,
            requestFragments: requestFragments,
            expectedResponseLineCount: 1
        )
    }

    private func cliMockSocketRoundTrips(
        socketPath: String,
        requestFragments: [String],
        expectedResponseLineCount: Int
    ) throws -> String {
        let clientFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(clientFD, 0)
        defer { Darwin.close(clientFD) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(socketPath.utf8)
        XCTAssertLessThan(utf8.count, maxPathLength)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { buffer in
                for index in 0..<utf8.count {
                    buffer[index] = CChar(bitPattern: utf8[index])
                }
                buffer[utf8.count] = 0
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(clientFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connectResult, 0)

        for fragment in requestFragments {
            try cliMockWriteAll(Data(fragment.utf8), to: clientFD)
        }

        var response = Data()
        var responseLines = 0
        var buffer = [UInt8](repeating: 0, count: 4096)
        while responseLines < expectedResponseLineCount {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: "cmux.tests.mock-socket", code: Int(errno), userInfo: [
                    NSLocalizedDescriptionKey: "failed to read mock socket response",
                ])
            }
            if count == 0 { break }
            response.append(buffer, count: count)
            responseLines = response.reduce(0) { partial, byte in
                partial + (byte == 0x0A ? 1 : 0)
            }
        }
        return String(data: response, encoding: .utf8) ?? ""
    }

    private func cliMockWriteAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var remaining = rawBuffer.count
            var cursor = base
            while remaining > 0 {
                let written = Darwin.write(fd, cursor, remaining)
                if written > 0 {
                    remaining -= written
                    cursor = cursor.advanced(by: written)
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    throw NSError(domain: "cmux.tests.mock-socket", code: Int(errno), userInfo: [
                        NSLocalizedDescriptionKey: "failed to write mock socket request",
                    ])
                }
            }
        }
    }
}
