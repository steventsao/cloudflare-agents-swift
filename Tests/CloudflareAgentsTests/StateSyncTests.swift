import XCTest
@testable import CloudflareAgents

/// Group 3: State sync
/// - client.setState sends cf_agent_state JSON over WS
/// - server cf_agent_state broadcast updates client's local state + fires onStateUpdate
final class StateSyncTests: XCTestCase {

    struct CountState: Codable, Sendable, Equatable {
        let count: Int
    }

    // MARK: - setState sends correct JSON

    func testSetStateSendsJSONToServer() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        var receivedMessages: [String] = []
        let messageExpectation = expectation(description: "state message received by server")

        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                receivedMessages.append(incoming)
                if incoming.contains("cf_agent_state") {
                    messageExpectation.fulfill()
                }
                return nil
            })
        }

        let client = AgentClient<CountState>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await client.setState(CountState(count: 7))

        await fulfillment(of: [messageExpectation], timeout: 2.0)

        // Verify the message sent contains the state
        let stateMessages = receivedMessages.filter { $0.contains("cf_agent_state") }
        XCTAssertFalse(stateMessages.isEmpty)

        let msgData = stateMessages.last!.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: msgData) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "cf_agent_state")
        let state = json["state"] as? [String: Any]
        XCTAssertEqual(state?["count"] as? Int, 7)

        await client.disconnect()
    }

    func testSetStateUpdatesLocalStateOptimistically() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        struct EmptyS: Codable, Sendable {}
        // Use CountState
        let client = AgentClient<CountState>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await client.setState(CountState(count: 42))

        // Local state should update immediately (optimistic)
        let state = await client.state
        XCTAssertEqual(state?.count, 42)

        await client.disconnect()
    }

    func testSetStateFiresOnStateUpdateCallbackWithClientSource() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        let client = AgentClient<CountState>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))

        let recorder = StateUpdateRecorder<CountState>()
        let updateExpectation = expectation(description: "onStateUpdate called")

        await client.onStateUpdate { state, source in
            Task {
                await recorder.record(state: state, source: source)
                updateExpectation.fulfill()
            }
        }

        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await client.setState(CountState(count: 99))

        await fulfillment(of: [updateExpectation], timeout: 2.0)

        let update = await recorder.snapshot()
        XCTAssertEqual(update.state?.count, 99)
        XCTAssertEqual(update.source, .client)

        await client.disconnect()
    }

    // MARK: - Server state broadcast updates local state

    func testServerStateBroadcastUpdatesLocalState() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Server will send a state broadcast after connect
        server.onConnect = { conn in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                conn.send("""
                {"type":"cf_agent_state","state":{"count":55}}
                """)
            }
        }

        let client = AgentClient<CountState>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))

        let recorder = StateUpdateRecorder<CountState>()
        let updateExpectation = expectation(description: "state update from server")

        await client.onStateUpdate { state, source in
            Task {
                await recorder.record(state: state, source: source)
                updateExpectation.fulfill()
            }
        }

        await client.connect()

        await fulfillment(of: [updateExpectation], timeout: 2.0)

        let update = await recorder.snapshot()
        XCTAssertEqual(update.state?.count, 55)
        XCTAssertEqual(update.source, .server)

        let localState = await client.state
        XCTAssertEqual(localState?.count, 55)

        await client.disconnect()
    }

    func testMultipleServerStateBroadcastsUpdateLocalState() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                conn.send("""
                {"type":"cf_agent_state","state":{"count":1}}
                """)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                conn.send("""
                {"type":"cf_agent_state","state":{"count":2}}
                """)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                conn.send("""
                {"type":"cf_agent_state","state":{"count":3}}
                """)
            }
        }

        let client = AgentClient<CountState>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))

        let recorder = IntHistoryRecorder()
        let done = expectation(description: "received 3 state updates")
        done.expectedFulfillmentCount = 3

        await client.onStateUpdate { state, _ in
            Task {
                await recorder.append(state.count)
                done.fulfill()
            }
        }

        await client.connect()
        await fulfillment(of: [done], timeout: 2.0)

        let stateHistory = await recorder.values()
        XCTAssertEqual(stateHistory, [1, 2, 3])

        let final = await client.state
        XCTAssertEqual(final?.count, 3)

        await client.disconnect()
    }

    // MARK: - State error from server

    func testServerStateErrorFiresOnError() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                conn.send("""
                {"type":"cf_agent_state_error","error":"Connection is readonly"}
                """)
            }
        }

        let client = AgentClient<CountState>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))

        let recorder = StringRecorder()
        let errorExpectation = expectation(description: "error received")

        await client.onError { error in
            Task {
                if let agentError = error as? AgentError,
                   case .rpcFailed(let msg) = agentError {
                    await recorder.set(msg)
                }
                errorExpectation.fulfill()
            }
        }

        await client.connect()
        await fulfillment(of: [errorExpectation], timeout: 2.0)

        let errorMessage = await recorder.value()
        XCTAssertEqual(errorMessage, "Connection is readonly")

        await client.disconnect()
    }
}

private actor StateUpdateRecorder<State: Sendable> {
    private var state: State?
    private var source: StateSource?

    func record(state: State, source: StateSource) {
        self.state = state
        self.source = source
    }

    func snapshot() -> (state: State?, source: StateSource?) {
        (state, source)
    }
}

private actor IntHistoryRecorder {
    private var storage: [Int] = []

    func append(_ value: Int) {
        storage.append(value)
    }

    func values() -> [Int] {
        storage
    }
}

private actor StringRecorder {
    private var storage: String?

    func set(_ value: String) {
        storage = value
    }

    func value() -> String? {
        storage
    }
}
