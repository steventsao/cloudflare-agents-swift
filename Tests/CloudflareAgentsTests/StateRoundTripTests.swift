import XCTest
@testable import CloudflareAgents

/// Thread-safe box for capturing a single value across concurrency boundaries
actor CapturedValue<T: Sendable> {
    var value: T?
    func set(_ v: T) { value = v }
}

/// Network-level state round-trip tests — parity with cloudflare/agents TS SDK
/// Covers: setState → server stateError, multiple rapid client setStates,
/// initial state on connect handshake, RPC with mixed arg types.
final class StateRoundTripTests: XCTestCase {

    struct CountState: Codable, Sendable, Equatable {
        let count: Int
    }

    // MARK: - setState rejected by server sends stateError back to client

    func testSetStateRejectedByServerFiresStateError() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Server rejects any state update with a stateError
        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
            conn.startEchoing(handler: { incoming in
                guard let json = try? JSONSerialization.jsonObject(with: incoming.data(using: .utf8)!) as? [String: Any],
                      let type_ = json["type"] as? String, type_ == "cf_agent_state" else { return nil }
                // Server rejects the state change (readonly connection)
                return """
                {"type":"cf_agent_state_error","error":"Connection is readonly"}
                """
            })
        }

        let client = AgentClient<CountState>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        let errorExpectation = expectation(description: "stateError callback")
        let capturedError = CapturedValue<String>()

        await client.onError { error in
            if let agentErr = error as? AgentError, case .rpcFailed(let msg) = agentErr {
                Task { await capturedError.set(msg) }
            }
            errorExpectation.fulfill()
        }

        await client.connect()
        await client.waitForReady()

        // Client sends a state update
        try await client.setState(CountState(count: 99))

        await fulfillment(of: [errorExpectation], timeout: 2.0)

        let errorMsg = await capturedError.value
        XCTAssertEqual(errorMsg, "Connection is readonly")

        await client.disconnect()
    }

    // MARK: - Multiple rapid client setStates sent in order

    func testMultipleClientSetStatesSentInOrder() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        var receivedCounts: [Int] = []
        let allReceived = expectation(description: "received 3 state updates")
        allReceived.expectedFulfillmentCount = 3

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
            conn.startEchoing(handler: { incoming in
                guard let json = try? JSONSerialization.jsonObject(with: incoming.data(using: .utf8)!) as? [String: Any],
                      let type_ = json["type"] as? String, type_ == "cf_agent_state",
                      let state = json["state"] as? [String: Any],
                      let count = state["count"] as? Int else { return nil }
                receivedCounts.append(count)
                allReceived.fulfill()
                return nil
            })
        }

        let client = AgentClient<CountState>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        await client.connect()
        await client.waitForReady()

        // Fire 3 rapid state updates
        try await client.setState(CountState(count: 1))
        try await client.setState(CountState(count: 2))
        try await client.setState(CountState(count: 3))

        await fulfillment(of: [allReceived], timeout: 2.0)

        // Server should receive all 3 in order
        XCTAssertEqual(receivedCounts, [1, 2, 3])

        // Local state should reflect the last update
        let final = await client.state
        XCTAssertEqual(final?.count, 3)

        await client.disconnect()
    }

    // MARK: - Initial state delivered in connect handshake

    func testInitialStateFromServerOnConnect() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Server sends identity + state as part of the connect handshake (like the TS SDK does)
        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
            conn.send("""
            {"type":"cf_agent_state","state":{"count":42}}
            """)
        }

        let client = AgentClient<CountState>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        let stateExpectation = expectation(description: "initial state received")
        let capturedSource = CapturedValue<StateSource>()

        await client.onStateUpdate { _, source in
            Task {
                await capturedSource.set(source)
                stateExpectation.fulfill()
            }
        }

        await client.connect()
        await fulfillment(of: [stateExpectation], timeout: 2.0)

        let state = await client.state
        XCTAssertEqual(state?.count, 42)
        let source = await capturedSource.value
        XCTAssertEqual(source, .server)

        await client.disconnect()
    }

    // MARK: - RPC with mixed argument types

    func testRPCCallWithMixedArgTypes() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        var receivedArgs: [Any]?

        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let data = incoming.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type_ = json["type"] as? String, type_ == "rpc",
                      let id = json["id"] as? String else { return nil }
                receivedArgs = json["args"] as? [Any]
                return """
                {"type":"rpc","id":"\(id)","success":true,"result":"ok"}
                """
            })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Call with string, int, bool, and dict args
        let result = try await client.call("configure", args: [
            "name",
            42,
            true,
            ["key": "value"]
        ])

        XCTAssertEqual(result?.value as? String, "ok")

        // Verify server received all arg types
        XCTAssertNotNil(receivedArgs)
        XCTAssertEqual(receivedArgs?.count, 4)
        XCTAssertEqual(receivedArgs?[0] as? String, "name")
        XCTAssertEqual(receivedArgs?[1] as? Int, 42)
        XCTAssertEqual(receivedArgs?[2] as? Bool, true)
        let dict = receivedArgs?[3] as? [String: String]
        XCTAssertEqual(dict?["key"], "value")

        await client.disconnect()
    }

    func testRPCCallWithArrayArg() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let data = incoming.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type_ = json["type"] as? String, type_ == "rpc",
                      let id = json["id"] as? String,
                      let args = json["args"] as? [Any],
                      let firstArg = args.first as? [Any] else { return nil }
                return """
                {"type":"rpc","id":"\(id)","success":true,"result":\(firstArg.count)}
                """
            })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Pass an array as a single arg
        let result = try await client.call("processItems", args: [
            AnyCodable(["a", "b", "c"] as [Any])
        ])

        XCTAssertEqual(result?.value as? Int, 3)

        await client.disconnect()
    }

    // MARK: - RPC with complex nested result

    func testRPCCallReturnsNestedObject() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let data = incoming.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type_ = json["type"] as? String, type_ == "rpc",
                      let id = json["id"] as? String else { return nil }
                return """
                {"type":"rpc","id":"\(id)","success":true,"result":{"name":"test","nested":{"count":5},"tags":["a","b"]}}
                """
            })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        let result = try await client.call("getDetails", args: [])

        let dict = result?.value as? [String: Any]
        XCTAssertEqual(dict?["name"] as? String, "test")

        let nested = dict?["nested"] as? [String: Any]
        XCTAssertEqual(nested?["count"] as? Int, 5)

        let tags = dict?["tags"] as? [Any]
        XCTAssertEqual(tags?.count, 2)

        await client.disconnect()
    }

    // MARK: - State update after reconnect delivers fresh state

    func testStateUpdateAfterReconnectDeliversFreshState() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        var connectNumber = 0
        server.onConnect = { conn in
            connectNumber += 1
            let count = connectNumber * 100
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
            conn.send("""
            {"type":"cf_agent_state","state":{"count":\(count)}}
            """)
        }

        let client = AgentClient<CountState>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        // First connection: state should be 100
        await client.connect()
        try await Task.sleep(nanoseconds: 300_000_000)
        let state1 = await client.state
        XCTAssertEqual(state1?.count, 100)

        // Disconnect, reconnect: state should be 200
        await client.disconnect()
        await client.connect()
        try await Task.sleep(nanoseconds: 300_000_000)
        let state2 = await client.state
        XCTAssertEqual(state2?.count, 200)

        await client.disconnect()
    }
}
