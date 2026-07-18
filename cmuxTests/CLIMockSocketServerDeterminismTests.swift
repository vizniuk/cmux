import XCTest
import Darwin
import Dispatch

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
            connectionCount: 2,
            strictConnectionCount: true
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

    func testOneWayFeedDoesNotCompleteServerBeforeControlConnection() throws {
        let socketPath = makeSocketPath("feed-not-terminal")
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
            self.claudeStyleResponse(line: line, surfaceId: "surface-feed-not-terminal")
        }

        let feedFD = try cliMockConnect(socketPath: socketPath)
        try cliMockWriteAll(Data(oneWayFeedPushLine().utf8), to: feedFD)
        Darwin.close(feedFD)

        let earlyResult = XCTWaiter().wait(for: [serverHandled], timeout: 0.25)
        if earlyResult == .completed {
            XCTFail("One-way feed.push completed the whole mock server before the expected control connection was accepted.")
            return
        }
        XCTAssertEqual(earlyResult, .timedOut)

        let controlResponse = try cliMockSocketRoundTrip(
            socketPath: socketPath,
            requestFragments: [surfaceListLine(id: "control-after-feed")]
        )
        XCTAssertTrue(controlResponse.contains(#""id":"control-after-feed""#), controlResponse)
        XCTAssertEqual(observedMethods(in: state), ["feed.push", "surface.list"])
    }

    func testEOFOnOneConnectionDoesNotCompleteServerBeforeExpectedConnectionCount() throws {
        let socketPath = makeSocketPath("eof-not-terminal")
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
            "ack:\(line)"
        }

        Darwin.close(try cliMockConnect(socketPath: socketPath))

        let earlyResult = XCTWaiter().wait(for: [serverHandled], timeout: 0.25)
        if earlyResult == .completed {
            XCTFail("EOF on the first accepted connection completed the whole mock server before the expected second connection.")
            return
        }
        XCTAssertEqual(earlyResult, .timedOut)

        let response = try cliMockSocketRoundTrip(
            socketPath: socketPath,
            requestFragments: ["second-request\n"]
        )
        XCTAssertEqual(response, "ack:second-request\n")
        XCTAssertEqual(state.snapshot(), ["second-request"])
    }

    func testMockSocketServerTreatsZeroExpectedConnectionsAsNoTrafficContract() throws {
        let socketPath = makeSocketPath("zero-traffic")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = MockSocketServerState()
        let server = startMockServerObservingTraffic(
            listenerFD: listenerFD,
            state: state,
            requiredConnections: 0
        ) { line in
            XCTFail("Zero-traffic mock socket accepted unexpected method \(self.jsonObject(line)?["method"] as? String ?? "non-json")")
            return nil
        }

        let snapshot = server.shutdownAndWait()
        XCTAssertEqual(snapshot.expectedConnections, 0, snapshot.diagnostics)
        XCTAssertEqual(snapshot.acceptedConnections, 0, snapshot.diagnostics)
        XCTAssertEqual(snapshot.handledConnections, 0, snapshot.diagnostics)
        XCTAssertEqual(state.snapshot(), [])
    }

    func testMockSocketServerCompletesRequiredControlWhenOptionalFeedIsAbsent() throws {
        let socketPath = makeSocketPath("optional-feed-absent")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = MockSocketServerState()
        let server = startMockServerObservingTraffic(
            listenerFD: listenerFD,
            state: state,
            requiredConnections: 1,
            optionalConnections: 1
        ) { line in
            self.claudeStyleResponse(line: line, surfaceId: "surface-optional-feed-absent")
        }

        let response = try cliMockSocketRoundTrip(
            socketPath: socketPath,
            requestFragments: [surfaceListLine(id: "required-control")]
        )
        XCTAssertTrue(response.contains(#""id":"required-control""#), response)
        let snapshot = server.shutdownAndWait()
        XCTAssertEqual(snapshot.acceptedConnections, 1, snapshot.diagnostics)
        XCTAssertEqual(snapshot.handledConnections, 1, snapshot.diagnostics)
        XCTAssertEqual(snapshot.methodCounts["surface.list"] ?? 0, 1, snapshot.diagnostics)
        XCTAssertEqual(snapshot.methodCounts["feed.push"] ?? 0, 0, snapshot.diagnostics)
        XCTAssertEqual(observedMethods(in: state), ["surface.list"])
    }

    func testMockSocketServerObservesForbiddenFeedAbsenceWithoutPolling() throws {
        let socketPath = makeSocketPath("forbidden-feed-absent")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = MockSocketServerState()
        let server = startMockServerObservingTraffic(
            listenerFD: listenerFD,
            state: state,
            requiredConnections: 1,
            optionalConnections: 1
        ) { line in
            self.claudeStyleResponse(line: line, surfaceId: "surface-forbidden-feed-absent")
        }

        let response = try cliMockSocketRoundTrips(
            socketPath: socketPath,
            requestFragments: [
                surfaceListLine(id: "forbidden-control"),
                surfaceResumeSetLine(id: "forbidden-resume"),
            ],
            expectedResponseLineCount: 2
        )
        XCTAssertTrue(response.contains(#""id":"forbidden-control""#), response)
        XCTAssertTrue(response.contains(#""id":"forbidden-resume""#), response)
        let snapshot = server.shutdownAndWait()
        XCTAssertEqual(snapshot.acceptedConnections, 1, snapshot.diagnostics)
        XCTAssertEqual(snapshot.handledConnections, 1, snapshot.diagnostics)
        XCTAssertEqual(snapshot.methodCounts["surface.list"] ?? 0, 1, snapshot.diagnostics)
        XCTAssertEqual(snapshot.methodCounts["surface.resume.set"] ?? 0, 1, snapshot.diagnostics)
        XCTAssertFalse(observedMethods(in: state).contains("feed.push"))
    }

    func testClaudeStyleTwoConnectionProtocolCompletesAfterBothHandlersFinish() throws {
        let socketPath = makeSocketPath("claude-two")
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
            self.claudeStyleResponse(line: line, surfaceId: "surface-claude-two")
        }

        let controlFD = try cliMockConnect(socketPath: socketPath)
        defer { Darwin.close(controlFD) }

        try cliMockWriteAll(Data(surfaceListLine(id: "surface-list").utf8), to: controlFD)
        let surfaceListResponse = try cliMockReadResponse(from: controlFD)
        XCTAssertTrue(surfaceListResponse.contains(#""id":"surface-list""#), surfaceListResponse)

        let feedFD = try cliMockConnect(socketPath: socketPath)
        try cliMockWriteAll(Data(oneWayFeedPushLine().utf8), to: feedFD)
        Darwin.close(feedFD)

        try cliMockWriteAll(Data(surfaceResumeSetLine(id: "resume-set").utf8), to: controlFD)
        let resumeResponse = try cliMockReadResponse(from: controlFD)
        XCTAssertTrue(resumeResponse.contains(#""id":"resume-set""#), resumeResponse)

        Darwin.shutdown(controlFD, SHUT_RDWR)
        XCTAssertEqual(XCTWaiter().wait(for: [serverHandled], timeout: 2), .completed)
        assertClaudeStyleMethodContract(in: state)
    }

    func testClaudeStyleTwoConnectionProtocolCompletesWhenFeedArrivesFirst() throws {
        let socketPath = makeSocketPath("claude-feed-first")
        let listenerFD = try bindUnixSocket(at: socketPath)
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = MockSocketServerState()
        let feedObserved = DispatchSemaphore(value: 0)
        let serverHandled = startMockServer(
            listenerFD: listenerFD,
            state: state,
            connectionCount: 2,
            fulfillWhen: { line in
                if self.jsonObject(line)?["method"] as? String == "feed.push" {
                    feedObserved.signal()
                }
                return false
            }
        ) { line in
            self.claudeStyleResponse(line: line, surfaceId: "surface-feed-first")
        }

        let feedFD = try cliMockConnect(socketPath: socketPath)
        var feedFDOpen = true
        defer {
            if feedFDOpen {
                Darwin.close(feedFD)
            }
        }
        try cliMockWriteAll(Data(oneWayFeedPushLine().utf8), to: feedFD)
        XCTAssertEqual(
            feedObserved.wait(timeout: .now() + 2),
            .success,
            "Feed frame must be observed before the control connection starts."
        )

        let controlFD = try cliMockConnect(socketPath: socketPath)
        defer { Darwin.close(controlFD) }
        Darwin.close(feedFD)
        feedFDOpen = false

        try cliMockWriteAll(Data(surfaceListLine(id: "feed-first-list").utf8), to: controlFD)
        let surfaceListResponse = try cliMockReadResponse(from: controlFD)
        XCTAssertTrue(surfaceListResponse.contains(#""id":"feed-first-list""#), surfaceListResponse)

        try cliMockWriteAll(Data(surfaceResumeSetLine(id: "feed-first-resume").utf8), to: controlFD)
        let resumeResponse = try cliMockReadResponse(from: controlFD)
        XCTAssertTrue(resumeResponse.contains(#""id":"feed-first-resume""#), resumeResponse)

        Darwin.shutdown(controlFD, SHUT_RDWR)
        XCTAssertEqual(XCTWaiter().wait(for: [serverHandled], timeout: 2), .completed)
        XCTAssertEqual(observedMethods(in: state).first, "feed.push")
        assertClaudeStyleMethodContract(in: state)
    }

    func testConcurrentMockSocketServersRemainIsolatedWhileHandlersOverlap() throws {
        let socketPathA = makeSocketPath("concurrent-isolation-a")
        let socketPathB = makeSocketPath("concurrent-isolation-b")
        XCTAssertNotEqual(socketPathA, socketPathB)

        let listenerFDA = try bindUnixSocket(at: socketPathA)
        let listenerFDB = try bindUnixSocket(at: socketPathB)
        defer {
            Darwin.close(listenerFDA)
            Darwin.close(listenerFDB)
            unlink(socketPathA)
            unlink(socketPathB)
        }

        let stateA = MockSocketServerState()
        let stateB = MockSocketServerState()
        let handlerAEntered = DispatchSemaphore(value: 0)
        let handlerBEntered = DispatchSemaphore(value: 0)
        let releaseOverlappingHandlers = DispatchSemaphore(value: 0)

        let serverA = startMockServerObservingTraffic(
            listenerFD: listenerFDA,
            state: stateA,
            requiredConnections: 1
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                XCTFail("Server A received a malformed isolation request")
                return self.malformedRequestResponse(id: self.jsonObject(line)?["id"] as? String, raw: line)
            }
            guard id == "server-a-1", method == "isolation.alpha" else {
                XCTFail("Server A received an unexpected isolation identifier or method")
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected isolation request"]
                )
            }

            handlerAEntered.signal()
            guard releaseOverlappingHandlers.wait(timeout: .now() + 2) == .success else {
                XCTFail("Server A handler was not released after both handlers overlapped")
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "barrier_timeout", "message": "isolation barrier timed out"]
                )
            }
            return self.v2Response(id: id, ok: true, result: ["server": "a"])
        }

        let serverB = startMockServerObservingTraffic(
            listenerFD: listenerFDB,
            state: stateB,
            requiredConnections: 2
        ) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                XCTFail("Server B received a malformed isolation request")
                return self.malformedRequestResponse(id: self.jsonObject(line)?["id"] as? String, raw: line)
            }

            switch (id, method) {
            case ("server-b-1", "isolation.beta.first"):
                handlerBEntered.signal()
                guard releaseOverlappingHandlers.wait(timeout: .now() + 2) == .success else {
                    XCTFail("Server B handler was not released after both handlers overlapped")
                    return self.v2Response(
                        id: id,
                        ok: false,
                        error: ["code": "barrier_timeout", "message": "isolation barrier timed out"]
                    )
                }
                return self.v2Response(id: id, ok: true, result: ["server": "b", "sequence": 1])
            case ("server-b-2", "isolation.beta.second"):
                return self.v2Response(id: id, ok: true, result: ["server": "b", "sequence": 2])
            default:
                XCTFail("Server B received an unexpected isolation identifier or method")
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unrecognized_method", "message": "unexpected isolation request"]
                )
            }
        }

        let clientACompleted = expectation(description: "server A client completed")
        let firstClientBCompleted = expectation(description: "server B first client completed")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { clientACompleted.fulfill() }
            do {
                let response = try self.cliMockSocketRoundTrip(
                    socketPath: socketPathA,
                    requestFragments: [#"{"id":"server-a-1","version":1,"method":"isolation.alpha","params":{}}"# + "\n"]
                )
                XCTAssertTrue(response.contains(#""id":"server-a-1""#), response)
            } catch {
                XCTFail("Server A client failed: \(error.localizedDescription)")
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { firstClientBCompleted.fulfill() }
            do {
                let response = try self.cliMockSocketRoundTrip(
                    socketPath: socketPathB,
                    requestFragments: [#"{"id":"server-b-1","version":1,"method":"isolation.beta.first","params":{}}"# + "\n"]
                )
                XCTAssertTrue(response.contains(#""id":"server-b-1""#), response)
            } catch {
                XCTFail("Server B first client failed: \(error.localizedDescription)")
            }
        }

        let handlerAOverlapResult = handlerAEntered.wait(timeout: .now() + 2)
        let handlerBOverlapResult = handlerBEntered.wait(timeout: .now() + 2)
        releaseOverlappingHandlers.signal()
        releaseOverlappingHandlers.signal()
        XCTAssertEqual(handlerAOverlapResult, .success, "Server A handler must enter the overlap barrier")
        XCTAssertEqual(handlerBOverlapResult, .success, "Server B handler must enter before either handler is released")
        wait(for: [clientACompleted, firstClientBCompleted], timeout: 2)

        let snapshotA = serverA.shutdownAndWait()
        XCTAssertGreaterThanOrEqual(fcntl(listenerFDA, F_GETFD), 0, "Server A must not close the caller-owned listener")
        XCTAssertGreaterThanOrEqual(fcntl(listenerFDB, F_GETFD), 0, "Server A shutdown must not close server B's caller-owned listener")

        let secondResponseB = try cliMockSocketRoundTrip(
            socketPath: socketPathB,
            requestFragments: [#"{"id":"server-b-2","version":1,"method":"isolation.beta.second","params":{}}"# + "\n"]
        )
        XCTAssertTrue(secondResponseB.contains(#""id":"server-b-2""#), secondResponseB)
        let snapshotB = serverB.shutdownAndWait()
        XCTAssertGreaterThanOrEqual(fcntl(listenerFDB, F_GETFD), 0, "Server B must not close the caller-owned listener")

        XCTAssertEqual(snapshotA.expectedConnections, 1, snapshotA.diagnostics)
        XCTAssertEqual(snapshotA.optionalConnections, 0, snapshotA.diagnostics)
        XCTAssertEqual(snapshotA.acceptedConnections, 1, snapshotA.diagnostics)
        XCTAssertEqual(snapshotA.handledConnections, 1, snapshotA.diagnostics)
        XCTAssertEqual(snapshotA.activeHandlers, 0, snapshotA.diagnostics)
        XCTAssertEqual(snapshotA.framedRequests, 1, snapshotA.diagnostics)
        XCTAssertEqual(snapshotA.methods, ["isolation.alpha"], snapshotA.diagnostics)
        XCTAssertEqual(snapshotA.methodCounts, ["isolation.alpha": 1], snapshotA.diagnostics)
        XCTAssertEqual(snapshotA.attemptedResponses, 1, snapshotA.diagnostics)
        XCTAssertEqual(snapshotA.completedResponses, 1, snapshotA.diagnostics)
        XCTAssertNil(snapshotA.terminalFailure, snapshotA.diagnostics)
        XCTAssertTrue(snapshotA.listenerClosed, snapshotA.diagnostics)
        XCTAssertTrue(snapshotA.acceptLoopFinished, snapshotA.diagnostics)

        XCTAssertEqual(snapshotB.expectedConnections, 2, snapshotB.diagnostics)
        XCTAssertEqual(snapshotB.optionalConnections, 0, snapshotB.diagnostics)
        XCTAssertEqual(snapshotB.acceptedConnections, 2, snapshotB.diagnostics)
        XCTAssertEqual(snapshotB.handledConnections, 2, snapshotB.diagnostics)
        XCTAssertEqual(snapshotB.activeHandlers, 0, snapshotB.diagnostics)
        XCTAssertEqual(snapshotB.framedRequests, 2, snapshotB.diagnostics)
        XCTAssertEqual(snapshotB.methods, ["isolation.beta.first", "isolation.beta.second"], snapshotB.diagnostics)
        XCTAssertEqual(snapshotB.methodCounts, ["isolation.beta.first": 1, "isolation.beta.second": 1], snapshotB.diagnostics)
        XCTAssertEqual(snapshotB.attemptedResponses, 2, snapshotB.diagnostics)
        XCTAssertEqual(snapshotB.completedResponses, 2, snapshotB.diagnostics)
        XCTAssertNil(snapshotB.terminalFailure, snapshotB.diagnostics)
        XCTAssertTrue(snapshotB.listenerClosed, snapshotB.diagnostics)
        XCTAssertTrue(snapshotB.acceptLoopFinished, snapshotB.diagnostics)

        let requestsA = stateA.snapshot().compactMap(jsonObject)
        let requestsB = stateB.snapshot().compactMap(jsonObject)
        XCTAssertEqual(requestsA.compactMap { $0["id"] as? String }, ["server-a-1"])
        XCTAssertEqual(requestsA.compactMap { $0["method"] as? String }, ["isolation.alpha"])
        XCTAssertEqual(requestsB.compactMap { $0["id"] as? String }, ["server-b-1", "server-b-2"])
        XCTAssertEqual(requestsB.compactMap { $0["method"] as? String }, ["isolation.beta.first", "isolation.beta.second"])
    }

    func testClaudePredecessorThenStaleStopSequenceDoesNotLoseMockSocketCompletion() throws {
        try testClaudeSessionStartRecordIsNotRestorableUntilPrompt()
        try testClaudeStaleStopFromClosedPaneStaysStaleWhenSurfaceResolutionFallsBack()
    }

    func testClaudeStaleStopThenPredecessorSequenceDoesNotLoseMockSocketCompletion() throws {
        try testClaudeStaleStopFromClosedPaneStaysStaleWhenSurfaceResolutionFallsBack()
        try testClaudeSessionStartRecordIsNotRestorableUntilPrompt()
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
        let clientFD = try cliMockConnect(socketPath: socketPath)
        defer { Darwin.close(clientFD) }

        for fragment in requestFragments {
            try cliMockWriteAll(Data(fragment.utf8), to: clientFD)
        }

        return try cliMockReadResponse(
            from: clientFD,
            expectedResponseLineCount: expectedResponseLineCount
        )
    }

    private func cliMockConnect(socketPath: String) throws -> Int32 {
        let clientFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(clientFD, 0)

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(socketPath.utf8)
        XCTAssertLessThan(utf8.count, maxPathLength)
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
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
        guard connectResult == 0 else {
            let connectErrno = errno
            Darwin.close(clientFD)
            throw NSError(domain: "cmux.tests.mock-socket", code: Int(connectErrno), userInfo: [
                NSLocalizedDescriptionKey: "failed to connect to mock socket",
            ])
        }
        return clientFD
    }

    private func cliMockReadResponse(
        from clientFD: Int32,
        expectedResponseLineCount: Int = 1
    ) throws -> String {
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

    private func claudeStyleResponse(line: String, surfaceId: String) -> String {
        guard let payload = jsonObject(line) else {
            return "OK"
        }
        guard let id = payload["id"] as? String, let method = payload["method"] as? String else {
            return malformedRequestResponse(id: payload["id"] as? String, raw: line)
        }
        switch method {
        case "surface.list":
            return surfaceListResponse(id: id, surfaceId: surfaceId)
        case "surface.resume.set":
            return v2Response(id: id, ok: true, result: ["resume_binding": [:]])
        default:
            return v2Response(
                id: id,
                ok: false,
                error: ["code": "unexpected_method", "message": "unexpected method: \(method)"]
            )
        }
    }

    private func observedMethods(in state: MockSocketServerState) -> [String] {
        state.snapshot().map { line in
            guard let payload = jsonObject(line),
                  let method = payload["method"] as? String else {
                return "non-json"
            }
            return method
        }
    }

    private func assertClaudeStyleMethodContract(
        in state: MockSocketServerState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let methods = observedMethods(in: state)
        let methodCounts = Dictionary(grouping: methods, by: { $0 }).mapValues(\.count)
        XCTAssertEqual(methodCounts["surface.list"], 1, "Expected one surface.list frame, saw \(methods)", file: file, line: line)
        XCTAssertEqual(methodCounts["surface.resume.set"], 1, "Expected one surface.resume.set frame, saw \(methods)", file: file, line: line)
        XCTAssertEqual(methodCounts["feed.push"], 1, "Expected one feed.push frame, saw \(methods)", file: file, line: line)
        XCTAssertEqual(
            Set(methods),
            Set(["surface.list", "surface.resume.set", "feed.push"]),
            "Unexpected method sequence \(methods)",
            file: file,
            line: line
        )

        // `feed.push` is handled on an independent one-way connection, so this
        // test intentionally does not constrain where it appears relative to
        // the control connection. The two response-requiring control frames are
        // written on one socket, so their relative order remains deterministic.
        let surfaceListIndex = methods.firstIndex(of: "surface.list")
        let resumeSetIndex = methods.firstIndex(of: "surface.resume.set")
        XCTAssertNotNil(surfaceListIndex, "Missing surface.list in \(methods)", file: file, line: line)
        XCTAssertNotNil(resumeSetIndex, "Missing surface.resume.set in \(methods)", file: file, line: line)
        if let surfaceListIndex, let resumeSetIndex {
            XCTAssertLessThan(
                surfaceListIndex,
                resumeSetIndex,
                "surface.resume.set must follow surface.list on the control connection; saw \(methods)",
                file: file,
                line: line
            )
        }
    }

    private func surfaceListLine(id: String) -> String {
        #"{"id":"\#(id)","version":1,"method":"surface.list","params":{}}"# + "\n"
    }

    private func surfaceResumeSetLine(id: String) -> String {
        #"{"id":"\#(id)","version":1,"method":"surface.resume.set","params":{"sessionId":"synthetic-session"}}"# + "\n"
    }

    private func oneWayFeedPushLine() -> String {
        #"{"version":1,"method":"feed.push","params":{"wait_timeout_seconds":0,"hook_event_name":"SyntheticHook"}}"# + "\n"
    }
}
