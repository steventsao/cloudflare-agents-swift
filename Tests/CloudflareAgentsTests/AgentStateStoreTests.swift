import XCTest
@testable import CloudflareAgents

@MainActor
final class AgentStateStoreTests: XCTestCase {
    struct CountState: Codable, Sendable, Equatable {
        let count: Int
    }

    actor CountRecorder {
        private var storage: [Int] = []

        func append(_ count: Int) {
            storage.append(count)
        }

        func values() -> [Int] {
            storage
        }
    }

    func testConnectMirrorsIdentityAndInitialState() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"room","agent":"test-agent"}
            """)
            conn.send("""
            {"type":"cf_agent_state","state":{"count":4}}
            """)
        }

        let store = AgentStateStore<CountState>(options: .init(
            agent: "TestAgent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))

        await store.connect()
        try await waitUntil("store mirrors identity and state") {
            store.identity == AgentIdentity(name: "room", agent: "test-agent") &&
                store.state == CountState(count: 4)
        }

        XCTAssertTrue(store.identified)
        XCTAssertEqual(store.connectionState, .identified(name: "room", agent: "test-agent"))
        XCTAssertEqual(store.lastStateSource, .server)

        await store.disconnect()
    }

    func testSetStateUpdatesStoreAndSendsFrame() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        let recorder = CountRecorder()
        let receivedState = expectation(description: "server received state update")

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"room","agent":"test-agent"}
            """)
            conn.startEchoing { incoming in
                guard let data = incoming.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = json["type"] as? String,
                      type == "cf_agent_state",
                      let state = json["state"] as? [String: Any],
                      let count = state["count"] as? Int
                else { return nil }

                Task { await recorder.append(count) }
                receivedState.fulfill()
                return nil
            }
        }

        let store = AgentStateStore<CountState>(options: .init(
            agent: "TestAgent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))

        await store.connect()
        await store.waitForReady()
        try await store.setState(CountState(count: 9))

        await fulfillment(of: [receivedState], timeout: 2.0)

        XCTAssertEqual(store.state, CountState(count: 9))
        XCTAssertEqual(store.lastStateSource, .client)
        let recordedValues = await recorder.values()
        XCTAssertEqual(recordedValues, [9])

        await store.disconnect()
    }

    func testCallPassesThroughToClient() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        server.onConnect = { conn in
            conn.startEchoing { incoming in
                guard let data = incoming.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = json["type"] as? String,
                      type == "rpc",
                      let id = json["id"] as? String,
                      let args = json["args"] as? [Int]
                else { return nil }

                let sum = args.reduce(0, +)
                return """
                {"type":"rpc","id":"\(id)","success":true,"result":\(sum)}
                """
            }
        }

        let store = AgentStateStore<CountState>(options: .init(
            agent: "TestAgent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))

        await store.connect()
        let result = try await store.call("add", args: [2, 3], timeout: 2.0)

        XCTAssertEqual(result?.value as? Int, 5)

        await store.disconnect()
    }

    func testStateErrorMirrorsIntoStore() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"room","agent":"test-agent"}
            """)
            conn.startEchoing { incoming in
                guard let data = incoming.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = json["type"] as? String,
                      type == "cf_agent_state"
                else { return nil }

                return """
                {"type":"cf_agent_state_error","error":"Connection is readonly"}
                """
            }
        }

        let store = AgentStateStore<CountState>(options: .init(
            agent: "TestAgent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))

        await store.connect()
        await store.waitForReady()
        try await store.setState(CountState(count: 1))

        try await waitUntil("store mirrors state error") {
            store.lastStateError == "Connection is readonly"
        }

        XCTAssertNotNil(store.lastError)

        store.clearError()
        XCTAssertNil(store.lastError)
        XCTAssertNil(store.lastStateError)

        await store.disconnect()
    }

    func testStateErrorRollsBackStoreAndClearsOnFreshServerState() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"room","agent":"test-agent"}
            """)
            conn.send("""
            {"type":"cf_agent_state","state":{"count":1}}
            """)
            conn.startEchoing { incoming in
                guard let data = incoming.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = json["type"] as? String,
                      type == "cf_agent_state"
                else { return nil }

                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                    conn.send("""
                    {"type":"cf_agent_state","state":{"count":2}}
                    """)
                }
                return """
                {"type":"cf_agent_state_error","error":"State update rejected"}
                """
            }
        }

        let store = AgentStateStore<CountState>(options: .init(
            agent: "TestAgent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))

        await store.connect()
        await store.waitForReady()
        try await waitUntil("store receives initial server state") {
            store.state == CountState(count: 1)
        }

        try await store.setState(CountState(count: 99))

        try await waitUntil("store rolls back rejected optimistic state") {
            store.state == CountState(count: 1) &&
                store.lastStateSource == .server &&
                store.lastStateError == "State update rejected"
        }

        try await waitUntil("fresh server state clears rejection") {
            store.state == CountState(count: 2) &&
                store.lastStateSource == .server &&
                store.lastStateError == nil &&
                store.lastError == nil
        }

        await store.disconnect()
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2.0,
        predicate: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}
