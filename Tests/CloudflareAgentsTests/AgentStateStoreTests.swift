import XCTest
import Network
@testable import CloudflareAgents

@MainActor
final class AgentStateStoreTests: XCTestCase {
    struct CountState: Codable, Sendable, Equatable {
        let count: Int
    }

    struct RoomState: Codable, Sendable, Equatable {
        let room: String
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

    func testMultipleStoresMirrorIndependentUseAgentInstances() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        let recorder = RoomRecorder()
        var connectCount = 0
        var connections: [String: MockWSConnection] = [:]

        server.onConnect = { conn in
            connectCount += 1
            let side = connectCount == 1 ? "left" : "right"
            let room = "\(side)-room"
            let initialCount = side == "left" ? 10 : 20
            connections[side] = conn

            conn.send("""
            {"type":"cf_agent_identity","name":"\(room)","agent":"counter-agent"}
            """)
            conn.send("""
            {"type":"cf_agent_state","state":{"room":"\(side)","count":\(initialCount)}}
            """)
            conn.startEchoing { incoming in
                guard let data = incoming.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = json["type"] as? String,
                      type == "cf_agent_state",
                      let state = json["state"] as? [String: Any],
                      let stateRoom = state["room"] as? String,
                      let count = state["count"] as? Int
                else { return nil }

                Task { await recorder.record(connectionRoom: side, stateRoom: stateRoom, count: count) }
                return nil
            }
        }

        let left = AgentStateStore<RoomState>(options: .init(
            agent: "CounterAgent",
            name: "left-room",
            host: "ws://localhost:\(port)"
        ))
        let right = AgentStateStore<RoomState>(options: .init(
            agent: "CounterAgent",
            name: "right-room",
            host: "ws://localhost:\(port)"
        ))
        let fixture = MultiUseAgentFixture(left: left, right: right)

        await left.connect()
        try await waitUntil("left store receives its identity and state") {
            left.identity == AgentIdentity(name: "left-room", agent: "counter-agent") &&
                left.state == RoomState(room: "left", count: 10)
        }

        await right.connect()
        try await waitUntil("right store receives its identity and state") {
            right.identity == AgentIdentity(name: "right-room", agent: "counter-agent") &&
                right.state == RoomState(room: "right", count: 20)
        }

        XCTAssertEqual(fixture.instanceSummary, "left-room:left=10 | right-room:right=20")
        XCTAssertEqual(fixture.totalCount, 30)

        try await left.setState(RoomState(room: "left", count: 11))
        try await right.setState(RoomState(room: "right", count: 21))

        try await waitUntil("both optimistic writes stay scoped to their own store") {
            left.state == RoomState(room: "left", count: 11) &&
                right.state == RoomState(room: "right", count: 21)
        }

        let expectedRecords: Set<RoomRecord> = [
            RoomRecord(connectionRoom: "left", stateRoom: "left", count: 11),
            RoomRecord(connectionRoom: "right", stateRoom: "right", count: 21),
        ]
        try await waitUntilAsync("server receives each store update on its own connection") {
            Set(await recorder.records()) == expectedRecords
        }

        let recordedRecords = Set(await recorder.records())
        XCTAssertEqual(recordedRecords, expectedRecords)

        connections["left"]?.send("""
        {"type":"cf_agent_state","state":{"room":"left","count":12}}
        """)

        try await waitUntil("server update for one store does not overwrite the other") {
            left.state == RoomState(room: "left", count: 12) &&
                left.lastStateSource == .server &&
                right.state == RoomState(room: "right", count: 21) &&
                right.lastStateSource == .client
        }

        XCTAssertEqual(fixture.instanceSummary, "left-room:left=12 | right-room:right=21")
        XCTAssertEqual(fixture.totalCount, 33)

        await left.disconnect()
        await right.disconnect()
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

    func testTerminalConnectionErrorMirrorsIntoStore() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"room","agent":"test-agent"}
            """)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                conn.close(code: .protocolCode(.policyViolation), reason: "policy")
            }
        }

        let store = AgentStateStore<CountState>(options: .init(
            agent: "TestAgent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))

        await store.connect()

        try await waitUntil("store mirrors terminal connection error") {
            store.connectionError?.code == 1008 &&
                store.connectionError?.reason == "policy" &&
                store.lastError is AgentConnectionError
        }

        store.clearError()
        XCTAssertNil(store.connectionError)
        XCTAssertNil(store.lastError)

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

    private func waitUntilAsync(
        _ description: String,
        timeout: TimeInterval = 2.0,
        predicate: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }
}

private struct RoomRecord: Hashable, Sendable {
    let connectionRoom: String
    let stateRoom: String
    let count: Int
}

private actor RoomRecorder {
    private var storage: [RoomRecord] = []

    func record(connectionRoom: String, stateRoom: String, count: Int) {
        storage.append(RoomRecord(
            connectionRoom: connectionRoom,
            stateRoom: stateRoom,
            count: count
        ))
    }

    func records() -> [RoomRecord] {
        storage
    }
}

@MainActor
private struct MultiUseAgentFixture {
    let left: AgentStateStore<AgentStateStoreTests.RoomState>
    let right: AgentStateStore<AgentStateStoreTests.RoomState>

    var instanceSummary: String {
        "\(label(for: left)) | \(label(for: right))"
    }

    var totalCount: Int {
        (left.state?.count ?? 0) + (right.state?.count ?? 0)
    }

    private func label(for store: AgentStateStore<AgentStateStoreTests.RoomState>) -> String {
        let room = store.identity?.name ?? "?"
        let stateRoom = store.state?.room ?? "?"
        let count = store.state?.count ?? -1
        return "\(room):\(stateRoom)=\(count)"
    }
}
