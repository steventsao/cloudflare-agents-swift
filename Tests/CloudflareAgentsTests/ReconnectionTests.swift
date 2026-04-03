import XCTest
@testable import CloudflareAgents

/// Group 5: Reconnection
/// Client should auto-reconnect (like PartySocket) and re-receive identity on each connection.
final class ReconnectionTests: XCTestCase {

    struct EmptyState: Codable, Sendable {}

    // MARK: - Manual reconnect receives identity again

    func testManualReconnectReceivesIdentityAgain() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        var connectCount = 0
        server.onConnect = { conn in
            connectCount += 1
            conn.send("""
            {"type":"cf_agent_identity","name":"room","agent":"my-agent"}
            """)
        }

        let client = AgentClient<EmptyState>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))

        let identityCountActor = Counter()
        await client.onIdentity { _, _ in Task { await identityCountActor.increment() } }

        // First connection
        await client.connect()
        try await Task.sleep(nanoseconds: 200_000_000)

        let count1 = await identityCountActor.value
        XCTAssertEqual(count1, 1)
        let identified1 = await client.identified
        XCTAssertTrue(identified1)

        // Disconnect and reconnect
        await client.disconnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        let identifiedAfterDisconnect = await client.identified
        XCTAssertFalse(identifiedAfterDisconnect)

        await client.connect()
        try await Task.sleep(nanoseconds: 200_000_000)

        let count2 = await identityCountActor.value
        XCTAssertEqual(count2, 2, "Should receive identity again after reconnect")
        let identified2 = await client.identified
        XCTAssertTrue(identified2)
        XCTAssertEqual(connectCount, 2)

        await client.disconnect()
    }

    func testReconnectResetsIdentifiedFlag() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        struct CountState: Codable, Sendable { let count: Int }

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_state","state":{"count":10}}
            """)
        }

        let client = AgentClient<CountState>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))

        await client.connect()
        try await Task.sleep(nanoseconds: 200_000_000)

        let stateBeforeDisconnect = await client.state
        XCTAssertEqual(stateBeforeDisconnect?.count, 10)

        await client.disconnect()

        // After disconnect, identified should be false
        let identified = await client.identified
        XCTAssertFalse(identified)
    }

    func testAutoReconnectFlagCanBeSet() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"room","agent":"my-agent"}
            """)
        }

        let client = AgentClient<EmptyState>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))

        // Enable auto-reconnect
        await client.setAutoReconnect(true, maxDelay: 0.1)

        let autoReconnect = await client.autoReconnectEnabled
        XCTAssertTrue(autoReconnect)

        // Can disable it too
        await client.setAutoReconnect(false)
        let disabled = await client.autoReconnectEnabled
        XCTAssertFalse(disabled)
    }

    func testAutoReconnectEnabledByDefault() async {
        let client = AgentClient<EmptyState>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:9999"
        ))
        let enabled = await client.autoReconnectEnabled
        XCTAssertFalse(enabled, "Auto-reconnect should be disabled by default")
    }

    // MARK: - waitForReady after manual reconnect

    func testWaitForReadyAfterReconnect() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                conn.send("""
                {"type":"cf_agent_identity","name":"r","agent":"a"}
                """)
            }
        }

        let client = AgentClient<EmptyState>(options: .init(
            agent: "a",
            name: "r",
            host: "ws://localhost:\(port)"
        ))

        // First connect cycle
        await client.connect()
        await client.waitForReady()
        let id1 = await client.identified
        XCTAssertTrue(id1)

        // Disconnect resets identified
        await client.disconnect()
        let idAfterDisconnect = await client.identified
        XCTAssertFalse(idAfterDisconnect)

        // Second connect cycle — waitForReady should work again
        await client.connect()
        await client.waitForReady()
        let id2 = await client.identified
        XCTAssertTrue(id2)

        await client.disconnect()
    }
}

// MARK: - Counter actor for concurrent counting

actor Counter {
    var value: Int = 0
    func increment() { value += 1 }
}
