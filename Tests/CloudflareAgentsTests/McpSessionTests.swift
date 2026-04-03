import XCTest
@testable import CloudflareAgents

/// Tests for MCP server list and session message handling
final class McpSessionTests: XCTestCase {

    struct EmptyS: Codable, Sendable {}

    // MARK: - MCP servers callback

    func testClientReceivesMcpServersList() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
            conn.send("""
            {"type":"cf_agent_mcp_servers","servers":[{"name":"my-mcp","url":"https://mcp.example.com"},{"name":"local-mcp"}]}
            """)
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        let mcpExpectation = expectation(description: "mcp servers received")
        let captured = CapturedMcpServers()

        await client.onMcpServers { servers in
            Task {
                await captured.set(servers)
                mcpExpectation.fulfill()
            }
        }

        await client.connect()
        await fulfillment(of: [mcpExpectation], timeout: 2.0)

        let servers = await captured.value
        XCTAssertEqual(servers?.count, 2)
        XCTAssertEqual(servers?[0].name, "my-mcp")
        XCTAssertEqual(servers?[0].url, "https://mcp.example.com")
        XCTAssertEqual(servers?[1].name, "local-mcp")
        XCTAssertNil(servers?[1].url)

        await client.disconnect()
    }

    func testClientReceivesEmptyMcpServersList() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_mcp_servers","servers":[]}
            """)
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        let mcpExpectation = expectation(description: "empty mcp servers received")
        let captured = CapturedMcpServers()

        await client.onMcpServers { servers in
            Task {
                await captured.set(servers)
                mcpExpectation.fulfill()
            }
        }

        await client.connect()
        await fulfillment(of: [mcpExpectation], timeout: 2.0)

        let servers = await captured.value
        XCTAssertEqual(servers?.count, 0)

        await client.disconnect()
    }

    // MARK: - MCP servers no longer surfaces as unhandled

    func testMcpServersDoesNotSurfaceAsUnhandled() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_mcp_servers","servers":[{"name":"test"}]}
            """)
            // Send a known-unhandled message after to verify routing
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                conn.send("""
                {"type":"custom_event","data":"test"}
                """)
            }
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        let unhandledExpectation = expectation(description: "unhandled message")
        let unhandled = UnhandledCollector()

        await client.onUnhandledMessage { msg in
            Task {
                await unhandled.append(msg)
                unhandledExpectation.fulfill()
            }
        }

        await client.connect()
        await fulfillment(of: [unhandledExpectation], timeout: 2.0)

        let messages = await unhandled.items
        // mcp_servers should NOT appear in unhandled
        let hasMcp = messages.contains { $0.contains("cf_agent_mcp_servers") }
        XCTAssertFalse(hasMcp, "MCP servers should be handled, not unhandled")
        // custom_event SHOULD appear in unhandled
        let hasCustom = messages.contains { $0.contains("custom_event") }
        XCTAssertTrue(hasCustom)

        await client.disconnect()
    }

    // MARK: - Session messages

    func testClientReceivesSessionMessage() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_session","sessionId":"sess-123","status":"active"}
            """)
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        let sessionExpectation = expectation(description: "session message received")
        let captured = CapturedSessionJSON()

        await client.onSession { json in
            Task {
                await captured.set(json)
                sessionExpectation.fulfill()
            }
        }

        await client.connect()
        await fulfillment(of: [sessionExpectation], timeout: 2.0)

        let json = await captured.value
        XCTAssertEqual(json?["sessionId"] as? String, "sess-123")
        XCTAssertEqual(json?["status"] as? String, "active")

        await client.disconnect()
    }

    func testClientReceivesSessionError() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_session_error","error":"Session expired"}
            """)
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        let errorExpectation = expectation(description: "session error received")
        let captured = CapturedString()

        await client.onSessionError { msg in
            Task {
                await captured.set(msg)
                errorExpectation.fulfill()
            }
        }

        await client.connect()
        await fulfillment(of: [errorExpectation], timeout: 2.0)

        let errorMsg = await captured.value
        XCTAssertEqual(errorMsg, "Session expired")

        await client.disconnect()
    }

    // MARK: - Full connect handshake: identity + state + mcp_servers

    func testFullProtocolHandshakeWithMcpServers() async throws {
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
            conn.send("""
            {"type":"cf_agent_mcp_servers","servers":[{"name":"tools","url":"https://tools.example.com"}]}
            """)
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        let mcpExpectation = expectation(description: "mcp servers in handshake")
        let captured = CapturedMcpServers()

        await client.onMcpServers { servers in
            Task {
                await captured.set(servers)
                mcpExpectation.fulfill()
            }
        }

        await client.connect()
        await client.waitForReady()
        await fulfillment(of: [mcpExpectation], timeout: 2.0)

        let identified = await client.identified
        XCTAssertTrue(identified)

        let servers = await captured.value
        XCTAssertEqual(servers?.count, 1)
        XCTAssertEqual(servers?[0].name, "tools")

        await client.disconnect()
    }
}

// MARK: - Thread-safe actors

actor CapturedMcpServers {
    var value: [McpServerInfo]?
    func set(_ v: [McpServerInfo]) { value = v }
}

actor CapturedSessionJSON {
    var value: [String: Any]?
    func set(_ v: [String: Any]) { value = v }
}

actor CapturedString {
    var value: String?
    func set(_ v: String) { value = v }
}

actor UnhandledCollector {
    var items: [String] = []
    func append(_ item: String) { items.append(item) }
}
