import XCTest
import Network
@testable import CloudflareAgents

/// Thread-safe string collector for connection state transition tracking
actor TransitionCollector {
    var items: [String] = []
    func append(_ item: String) { items.append(item) }
    func reset() { items.removeAll() }
}

/// Thread-safe string collector for unhandled messages
actor MessageCollector {
    var items: [String] = []
    func append(_ item: String) { items.append(item) }
}

/// Network-level connection lifecycle tests — parity with cloudflare/agents TS SDK
/// Covers: state transitions, double-connect guard, disconnect cleanup,
/// auto-reconnect on server drop, malformed messages, binary frames.
final class ConnectionLifecycleTests: XCTestCase {

    struct EmptyS: Codable, Sendable {}

    // MARK: - Connection state transitions

    func testConnectionStateTransitionsOnConnect() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"room","agent":"my-agent"}
            """)
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))

        let collector = TransitionCollector()
        await client.onConnectionStateChange { state in
            Task {
                switch state {
                case .disconnected: await collector.append("disconnected")
                case .connecting: await collector.append("connecting")
                case .connected: await collector.append("connected")
                case .identified: await collector.append("identified")
                }
            }
        }

        // Pre-connect: disconnected
        let initial = await client.connectionState
        if case .disconnected = initial {} else { XCTFail("Expected disconnected") }

        await client.connect()
        try await Task.sleep(nanoseconds: 300_000_000)

        // Should see: connecting → connected → identified
        let transitions = await collector.items
        XCTAssertEqual(transitions, ["connecting", "connected", "identified"],
                       "State transitions: \(transitions)")
    }

    func testConnectionStateTransitionsOnDisconnect() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        let collector = TransitionCollector()
        await client.onConnectionStateChange { state in
            Task {
                switch state {
                case .disconnected: await collector.append("disconnected")
                case .connecting: await collector.append("connecting")
                case .connected: await collector.append("connected")
                case .identified: await collector.append("identified")
                }
            }
        }

        await client.connect()
        try await Task.sleep(nanoseconds: 300_000_000)

        await collector.reset() // reset — only care about disconnect transition
        await client.disconnect()
        try await Task.sleep(nanoseconds: 100_000_000) // let Task in callback settle

        let transitions = await collector.items
        // At least one "disconnected" transition must fire; may see >1 if WS close
        // races with explicit disconnect (both paths emit disconnected)
        XCTAssertFalse(transitions.isEmpty, "Should have at least one disconnected transition")
        XCTAssertTrue(transitions.allSatisfy { $0 == "disconnected" },
                      "All post-disconnect transitions should be 'disconnected', got: \(transitions)")
    }

    // MARK: - Double-connect guard

    func testConnectWhileAlreadyConnectedIsNoOp() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        var connectCount = 0
        server.onConnect = { conn in
            connectCount += 1
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        await client.connect()
        try await Task.sleep(nanoseconds: 200_000_000)

        // Second connect should be a no-op (guard webSocketTask == nil)
        await client.connect()
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(connectCount, 1, "Second connect should not open a new WS connection")

        await client.disconnect()
    }

    // MARK: - Disconnect cleanup

    func testDisconnectCleansUpAllInternalState() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
            conn.send("""
            {"type":"cf_agent_state","state":{}}
            """)
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        await client.connect()
        try await Task.sleep(nanoseconds: 300_000_000)

        // Verify connected state
        let identifiedBefore = await client.identified
        XCTAssertTrue(identifiedBefore)

        await client.disconnect()

        // After disconnect: identified=false, connectionState=disconnected
        let identifiedAfter = await client.identified
        let connState = await client.connectionState
        XCTAssertFalse(identifiedAfter)
        if case .disconnected = connState {} else {
            XCTFail("Expected disconnected after disconnect, got \(connState)")
        }
    }

    // MARK: - Auto-reconnect on server drop

    func testAutoReconnectOnServerDrop() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        let identityCounter = Counter()
        var connections: [MockWSConnection] = []

        server.onConnect = { conn in
            connections.append(conn)
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
            Task { await identityCounter.increment() }
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        // Enable auto-reconnect with fast backoff for testing
        await client.setAutoReconnect(true, maxDelay: 0.2)

        await client.connect()
        try await Task.sleep(nanoseconds: 300_000_000)

        let count1 = await identityCounter.value
        XCTAssertEqual(count1, 1)

        // Server drops connection
        connections.first?.cancel()

        // Wait for auto-reconnect to fire
        try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s

        let count2 = await identityCounter.value
        XCTAssertGreaterThanOrEqual(count2, 2, "Should have auto-reconnected after server drop")

        let identified = await client.identified
        XCTAssertTrue(identified, "Should be identified after auto-reconnect")

        await client.disconnect()
    }

    // MARK: - Malformed message resilience

    func testMalformedMessageDoesNotCrash() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            // Send garbage first
            conn.send("this is not json at all")
            conn.send("{invalid json{{{")
            conn.send("{}")                              // valid JSON but no type field
            conn.send("{\"type\":\"unknown_type\"}")     // unknown type
            // Then send valid identity to prove client is still alive
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        let unhandledCollector = MessageCollector()
        await client.onUnhandledMessage { msg in
            Task { await unhandledCollector.append(msg) }
        }

        await client.connect()
        try await Task.sleep(nanoseconds: 500_000_000)

        // Client should still be alive and identified
        let identified = await client.identified
        XCTAssertTrue(identified, "Client should survive malformed messages")

        // The unknown_type message should surface via onUnhandledMessage
        let unhandled = await unhandledCollector.items
        let hasUnknown = unhandled.contains { $0.contains("unknown_type") }
        XCTAssertTrue(hasUnknown, "Unknown type should surface as unhandled")

        await client.disconnect()
    }

    func testEmptyTypeFieldIgnored() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.send("{\"type\":\"\",\"data\":\"test\"}")
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        await client.connect()
        try await Task.sleep(nanoseconds: 300_000_000)

        let identified = await client.identified
        XCTAssertTrue(identified, "Client should survive empty type field")

        await client.disconnect()
    }

    // MARK: - Error callback on connection failure

    func testTerminalCloseCodeClassifierMatchesUpstream() {
        XCTAssertTrue(isTerminalCloseCode(1008))
        XCTAssertTrue(isTerminalCloseCode(4000))
        XCTAssertTrue(isTerminalCloseCode(4999))

        XCTAssertFalse(isTerminalCloseCode(1000))
        XCTAssertFalse(isTerminalCloseCode(1001))
        XCTAssertFalse(isTerminalCloseCode(3999))
        XCTAssertFalse(isTerminalCloseCode(5000))
    }

    func testErrorCallbackFiresOnConnectionLoss() async throws {
        let server = MockWSServer()
        try await server.start()
        let port = server.port!

        var serverConn: MockWSConnection?
        server.onConnect = { conn in
            serverConn = conn
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        let errorExpectation = expectation(description: "error callback fired")
        await client.onError { _ in
            errorExpectation.fulfill()
        }

        await client.connect()
        try await Task.sleep(nanoseconds: 300_000_000)

        // Server forcibly drops the connection
        serverConn?.cancel()
        server.stop()

        await fulfillment(of: [errorExpectation], timeout: 3.0)

        await client.disconnect()
    }

    func testShouldReconnectOnCloseCanSuppressNonTerminalReconnect() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!
        let connectCounter = Counter()

        server.onConnect = { conn in
            Task { await connectCounter.increment() }
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                conn.close(code: .protocolCode(.goingAway), reason: "restart")
            }
        }

        let captured = CapturedCloseEvent()
        let closeExpectation = expectation(description: "close classified")
        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)",
            shouldReconnectOnClose: { event in
                Task { await captured.set(event) }
                closeExpectation.fulfill()
                return false
            }
        ))

        await client.setAutoReconnect(true, maxDelay: 0.1)
        await client.connect()
        await fulfillment(of: [closeExpectation], timeout: 3.0)

        try await Task.sleep(nanoseconds: 500_000_000)

        let event = await captured.value
        XCTAssertEqual(event?.code, 1001)
        XCTAssertEqual(event?.reason, "restart")
        let connectionCount = await connectCounter.value
        XCTAssertEqual(connectionCount, 1, "custom close classifier should suppress reconnect")
        let connectionError = await client.connectionError
        XCTAssertNil(connectionError, "non-terminal closes should not report AgentConnectionError")

        await client.disconnect()
    }

    func testTerminalCloseReportsConnectionErrorAndDoesNotReconnect() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!
        let connectCounter = Counter()

        server.onConnect = { conn in
            Task { await connectCounter.increment() }
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                conn.close(code: .protocolCode(.policyViolation), reason: "policy")
            }
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        await client.setAutoReconnect(true, maxDelay: 0.1)

        let errorExpectation = expectation(description: "terminal connection error reported")
        let captured = CapturedConnectionError()
        await client.onConnectionError { error in
            Task { await captured.set(error) }
            errorExpectation.fulfill()
        }

        await client.connect()
        await fulfillment(of: [errorExpectation], timeout: 3.0)

        try await Task.sleep(nanoseconds: 500_000_000)

        let error = await captured.value
        XCTAssertEqual(error?.name, "AgentConnectionError")
        XCTAssertEqual(error?.code, 1008)
        XCTAssertEqual(error?.reason, "policy")
        let clientConnectionError = await client.connectionError
        XCTAssertNotNil(clientConnectionError)
        let connectionCount = await connectCounter.value
        XCTAssertEqual(connectionCount, 1, "terminal closes must not auto-reconnect")

        do {
            _ = try await client.call("add", args: [1, 2], timeout: 0.1)
            XCTFail("Expected calls after terminal close to throw")
        } catch AgentError.connectionClosed {
            // Expected.
        } catch {
            XCTFail("Expected connectionClosed after terminal close, got \(error)")
        }

        await client.disconnect()
    }
}

actor CapturedConnectionError {
    var value: AgentConnectionError?
    func set(_ error: AgentConnectionError) { value = error }
}

actor CapturedCloseEvent {
    var value: AgentConnectionCloseEvent?
    func set(_ event: AgentConnectionCloseEvent) { value = event }
}
