import XCTest
@testable import CloudflareAgents

/// Tests for `onIdentityChange` — mirrors the JS `AgentClient` behavior of
/// detecting when the server reports a *different* instance/agent on reconnect.
/// This happens with server-side routing (e.g. `basePath` + `getAgentByName`)
/// where the resolved instance depends on auth/session rather than the
/// client-supplied name.
///
/// These tests drive identity arrival deterministically via `waitForReady()`
/// (which resolves exactly when an identity frame is received) rather than
/// fixed sleeps, and record changes synchronously — `onIdentityChange` fires
/// synchronously inside the message handler, before `waitForReady()` returns.
final class IdentityChangeTests: XCTestCase {

    struct EmptyState: Codable, Sendable {}

    /// Build a server that sends a (possibly different) identity per connection,
    /// cycling through `identities` and holding the last value for further connects.
    private func identitySequenceServer(
        _ server: MockWSServer,
        identities: [(name: String, agent: String)]
    ) {
        let box = ConnectionIndexBox()
        server.onConnect = { conn in
            let idx = box.next()
            let identity = identities[min(idx, identities.count - 1)]
            conn.send("""
            {"type":"cf_agent_identity","name":"\(identity.name)","agent":"\(identity.agent)"}
            """)
        }
    }

    private func makeClient(agent: String, name: String, port: UInt16) -> AgentClient<EmptyState> {
        AgentClient<EmptyState>(options: .init(
            agent: agent, name: name, host: "ws://localhost:\(port)"
        ))
    }

    // MARK: - First identity must NOT fire a change

    func testFirstIdentityDoesNotFireChange() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }
        let port = server.port!

        identitySequenceServer(server, identities: [("room", "my-agent")])

        let client = makeClient(agent: "my-agent", name: "room", port: port)
        let recorder = IdentityChangeRecorder()
        await client.onIdentityChange { o, n, oa, na in recorder.record(o, n, oa, na) }

        await client.connect()
        await client.waitForReady()

        XCTAssertTrue(recorder.changes.isEmpty, "First identity must not fire onIdentityChange")

        await client.disconnect()
    }

    // MARK: - Same identity on reconnect must NOT fire a change

    func testSameIdentityOnReconnectDoesNotFireChange() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }
        let port = server.port!

        identitySequenceServer(server, identities: [("room", "my-agent"), ("room", "my-agent")])

        let client = makeClient(agent: "my-agent", name: "room", port: port)
        let recorder = IdentityChangeRecorder()
        await client.onIdentityChange { o, n, oa, na in recorder.record(o, n, oa, na) }

        await client.connect()
        await client.waitForReady()
        await client.disconnect()
        try await Task.sleep(nanoseconds: 50_000_000)
        await client.connect()
        await client.waitForReady()

        XCTAssertTrue(recorder.changes.isEmpty, "Identical identity on reconnect must not fire onIdentityChange")

        await client.disconnect()
    }

    // MARK: - Changed instance name fires a change

    func testChangedInstanceNameFiresChange() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }
        let port = server.port!

        identitySequenceServer(server, identities: [("room-a", "my-agent"), ("room-b", "my-agent")])

        let client = makeClient(agent: "my-agent", name: "room-a", port: port)
        let recorder = IdentityChangeRecorder()
        await client.onIdentityChange { o, n, oa, na in recorder.record(o, n, oa, na) }

        await client.connect()
        await client.waitForReady()
        await client.disconnect()
        try await Task.sleep(nanoseconds: 50_000_000)
        await client.connect()
        await client.waitForReady()

        let changes = recorder.changes
        XCTAssertEqual(changes.count, 1, "Changed instance name should fire exactly one change")
        XCTAssertEqual(changes.first?.oldName, "room-a")
        XCTAssertEqual(changes.first?.newName, "room-b")
        XCTAssertEqual(changes.first?.oldAgent, "my-agent")
        XCTAssertEqual(changes.first?.newAgent, "my-agent")

        await client.disconnect()
    }

    // MARK: - Changed agent class fires a change

    func testChangedAgentFiresChange() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }
        let port = server.port!

        identitySequenceServer(server, identities: [("room", "agent-one"), ("room", "agent-two")])

        let client = makeClient(agent: "agent-one", name: "room", port: port)
        let recorder = IdentityChangeRecorder()
        await client.onIdentityChange { o, n, oa, na in recorder.record(o, n, oa, na) }

        await client.connect()
        await client.waitForReady()
        await client.disconnect()
        try await Task.sleep(nanoseconds: 50_000_000)
        await client.connect()
        await client.waitForReady()

        let changes = recorder.changes
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes.first?.oldAgent, "agent-one")
        XCTAssertEqual(changes.first?.newAgent, "agent-two")
        XCTAssertEqual(changes.first?.oldName, "room")
        XCTAssertEqual(changes.first?.newName, "room")

        await client.disconnect()
    }
}

// MARK: - Test helpers

/// Thread-safe connection counter for the mock server's `onConnect` closure.
final class ConnectionIndexBox: @unchecked Sendable {
    private let lock = NSLock()
    private var index = -1
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        index += 1
        return index
    }
}

/// Lock-based (not actor) so `record` runs synchronously inside the
/// `onIdentityChange` closure — it must complete before `waitForReady()`
/// returns, which a `Task { await … }` hop would not guarantee.
final class IdentityChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(oldName: String, newName: String, oldAgent: String, newAgent: String)] = []
    func record(_ oldName: String, _ newName: String, _ oldAgent: String, _ newAgent: String) {
        lock.lock(); storage.append((oldName, newName, oldAgent, newAgent)); lock.unlock()
    }
    var changes: [(oldName: String, newName: String, oldAgent: String, newAgent: String)] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
