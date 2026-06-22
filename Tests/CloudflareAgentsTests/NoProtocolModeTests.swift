import XCTest
@testable import CloudflareAgents

/// Group 4: No-protocol mode
/// Query param protocol=false suppresses identity/state messages from server.
/// Client should still be able to do RPC. Tests verify client behavior in
/// no-protocol mode, where the SDK is used headlessly / without state sync.
final class NoProtocolModeTests: XCTestCase {

    struct CountState: Codable, Sendable { let count: Int }

    // MARK: - URL contains protocol=false query param

    func testNoProtocolURLContainsQueryParam() async {
        let options = AgentClient<CountState>.Options(
            agent: "ChatAgent",
            name: "room",
            host: "https://example.com",
            query: ["protocol": "false"]
        )
        let client = AgentClient<CountState>(options: options)
        let url = await client.baseURL
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let queryItems = components.queryItems ?? []
        let protocolItem = queryItems.first(where: { $0.name == "protocol" })
        XCTAssertEqual(protocolItem?.value, "false")
    }

    // MARK: - No-protocol server does not send identity/state

    func testNoProtocolServerNeverSendsIdentityOrState() async throws {
        // Mock server that mirrors the CF agent no-protocol behavior:
        // it does NOT send identity/state/mcp_servers — just echoes RPCs.
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Server only handles RPC, never sends protocol messages
        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let json = try? JSONSerialization.jsonObject(with: incoming.data(using: .utf8)!) as? [String: Any],
                      let type_ = json["type"] as? String, type_ == "rpc",
                      let id = json["id"] as? String else { return nil }
                return """
                {"type":"rpc","id":"\(id)","success":true,"result":"ok"}
                """
            })
        }

        let client = AgentClient<CountState>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)",
            query: ["protocol": "false"]
        ))

        let recorder = NoProtocolEventRecorder()

        await client.onIdentity { _, _ in Task { await recorder.recordIdentity() } }
        await client.onStateUpdate { _, _ in Task { await recorder.recordState() } }

        await client.connect()

        // Give time for any unwanted protocol messages
        try await Task.sleep(nanoseconds: 300_000_000) // 300ms

        // In no-protocol mode, server never sends these
        let events = await recorder.snapshot()
        XCTAssertFalse(events.identityReceived, "Should NOT receive identity in no-protocol mode")
        XCTAssertFalse(events.stateReceived, "Should NOT receive state in no-protocol mode")

        // But RPC should still work
        let result = try await client.call("getState", args: [])
        XCTAssertEqual(result?.value as? String, "ok")

        await client.disconnect()
    }

    func testNoProtocolClientNeverBecomesIdentified() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Server sends nothing on connect (no-protocol mode)
        server.onConnect = { _ in }

        let client = AgentClient<CountState>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)",
            query: ["protocol": "false"]
        ))

        await client.connect()
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        let identified = await client.identified
        XCTAssertFalse(identified, "Client should not be identified in no-protocol mode")

        let connState = await client.connectionState
        // Should be .connected but NOT .identified
        switch connState {
        case .connected:
            break // Expected
        case .identified:
            XCTFail("Should not reach .identified state in no-protocol mode")
        default:
            XCTFail("Unexpected state: \(connState)")
        }

        await client.disconnect()
    }

    func testNoProtocolRPCCallSucceeds() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let json = try? JSONSerialization.jsonObject(with: incoming.data(using: .utf8)!) as? [String: Any],
                      let type_ = json["type"] as? String, type_ == "rpc",
                      let id = json["id"] as? String else { return nil }
                return """
                {"type":"rpc","id":"\(id)","success":true,"result":{"count":0}}
                """
            })
        }

        let client = AgentClient<CountState>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)",
            query: ["protocol": "false"]
        ))

        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        let result = try await client.call("getState", args: [])

        // Result should be a dictionary
        let dict = result?.value as? [String: Any]
        XCTAssertEqual(dict?["count"] as? Int, 0)

        await client.disconnect()
    }

    // MARK: - readonly mode (protocol=true but readonly=true)

    func testReadonlyModeURLContainsQueryParam() async {
        let options = AgentClient<CountState>.Options(
            agent: "ChatAgent",
            name: "room",
            host: "https://example.com",
            query: ["readonly": "true"]
        )
        let client = AgentClient<CountState>(options: options)
        let url = await client.baseURL
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let queryItems = components.queryItems ?? []
        let item = queryItems.first(where: { $0.name == "readonly" })
        XCTAssertEqual(item?.value, "true")
    }

    func testReadonlyAndNoProtocolCombined() async {
        let options = AgentClient<CountState>.Options(
            agent: "ChatAgent",
            name: "room",
            host: "https://example.com",
            query: ["protocol": "false", "readonly": "true"]
        )
        let client = AgentClient<CountState>(options: options)
        let url = await client.baseURL
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let queryItems = Set(components.queryItems?.map { "\($0.name)=\($0.value!)" } ?? [])
        XCTAssertTrue(queryItems.contains("protocol=false"))
        XCTAssertTrue(queryItems.contains("readonly=true"))
    }
}

private actor NoProtocolEventRecorder {
    private var identityReceived = false
    private var stateReceived = false

    func recordIdentity() {
        identityReceived = true
    }

    func recordState() {
        stateReceived = true
    }

    func snapshot() -> (identityReceived: Bool, stateReceived: Bool) {
        (identityReceived, stateReceived)
    }
}
