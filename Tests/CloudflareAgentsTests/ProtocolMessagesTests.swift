import XCTest
import Network
@testable import CloudflareAgents

/// Group 1: Protocol messages
/// On WS connect, server sends identity + state + mcp_servers messages.
/// Tests parse all three message types received by AgentClient.
final class ProtocolMessagesTests: XCTestCase {

    // MARK: - McpServersMessage decode

    func testMcpServersMessageDecode() throws {
        let json = """
        {"type":"cf_agent_mcp_servers","servers":[{"name":"my-mcp","url":"https://mcp.example.com"}]}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(McpServersMessage.self, from: json)
        XCTAssertEqual(msg.type, .mcpServers)
        XCTAssertEqual(msg.servers.count, 1)
        XCTAssertEqual(msg.servers[0].name, "my-mcp")
        XCTAssertEqual(msg.servers[0].url, "https://mcp.example.com")
    }

    func testMcpServersMessageDecodeEmpty() throws {
        let json = """
        {"type":"cf_agent_mcp_servers","servers":[]}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(McpServersMessage.self, from: json)
        XCTAssertEqual(msg.type, .mcpServers)
        XCTAssertTrue(msg.servers.isEmpty)
    }

    // MARK: - Mock server integration: client receives identity + state + mcp_servers on connect

    func testClientReceivesProtocolMessagesOnConnect() async throws {
        // Build a mock WS server that sends identity, state, mcp_servers on connect
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Prepare the three protocol messages the server will send
        let identityJSON = """
        {"type":"cf_agent_identity","name":"test-room","agent":"chat-agent"}
        """
        let stateJSON = """
        {"type":"cf_agent_state","state":{"count":0}}
        """
        let mcpJSON = """
        {"type":"cf_agent_mcp_servers","servers":[]}
        """
        server.onConnect = { conn in
            conn.send(identityJSON)
            conn.send(stateJSON)
            conn.send(mcpJSON)
        }

        struct CountState: Codable, Sendable { let count: Int }

        let options = AgentClient<CountState>.Options(
            agent: "chat-agent",
            name: "test-room",
            host: "ws://localhost:\(port)"
        )
        let client = AgentClient<CountState>(options: options)

        let recorder = ProtocolMessageRecorder<CountState>()
        let protocolExpectation = expectation(description: "identity and state received")
        protocolExpectation.expectedFulfillmentCount = 2

        await client.onIdentity { name, agent in
            Task {
                await recorder.recordIdentity(name: name, agent: agent)
                protocolExpectation.fulfill()
            }
        }

        await client.onStateUpdate { state, source in
            Task {
                await recorder.recordState(state, source: source)
                protocolExpectation.fulfill()
            }
        }

        await client.connect()

        await fulfillment(of: [protocolExpectation], timeout: 2.0)

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.identityName, "test-room")
        XCTAssertEqual(snapshot.identityAgent, "chat-agent")
        XCTAssertEqual(snapshot.state?.count, 0)
        XCTAssertEqual(snapshot.source, .server)

        // Verify client.identified is true and state is set
        let identified = await client.identified
        let state = await client.state
        XCTAssertTrue(identified)
        XCTAssertEqual(state?.count, 0)

        await client.disconnect()
    }

    func testClientConnectionStateBecomesIdentified() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"my-instance","agent":"my-agent"}
            """)
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "my-agent",
            name: "my-instance",
            host: "ws://localhost:\(port)"
        ))

        await client.connect()
        try await Task.sleep(nanoseconds: 300_000_000)

        let state = await client.connectionState
        if case .identified(let name, let agent) = state {
            XCTAssertEqual(name, "my-instance")
            XCTAssertEqual(agent, "my-agent")
        } else {
            XCTFail("Expected .identified, got \(state)")
        }

        await client.disconnect()
    }

    func testWaitForReadyReturnsAfterIdentity() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Server sends identity after a short delay
        server.onConnect = { conn in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                conn.send("""
                {"type":"cf_agent_identity","name":"r","agent":"a"}
                """)
            }
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "a",
            name: "r",
            host: "ws://localhost:\(port)"
        ))

        await client.connect()

        // waitForReady should return only after identity is received
        await client.waitForReady()

        let identified = await client.identified
        XCTAssertTrue(identified)

        await client.disconnect()
    }

    func testClientSurfacesUnhandledCustomMessages() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.send("""
            {"type":"task.queued","task":{"id":"task_123","text":"hello from dispatch","status":"queued"}}
            """)
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "dispatch-agent",
            name: "my-instance",
            host: "ws://localhost:\(port)"
        ))

        let messageExpectation = expectation(description: "Unhandled message received")
        let recorder = StringMessageRecorder()

        await client.onUnhandledMessage { message in
            Task {
                await recorder.set(message)
                messageExpectation.fulfill()
            }
        }

        await client.connect()
        await fulfillment(of: [messageExpectation], timeout: 2.0)

        let received = await recorder.value()
        XCTAssertTrue(received?.contains("\"type\":\"task.queued\"") == true)
        XCTAssertTrue(received?.contains("\"id\":\"task_123\"") == true)

        await client.disconnect()
    }
}

private actor ProtocolMessageRecorder<State: Sendable> {
    private var identityName: String?
    private var identityAgent: String?
    private var state: State?
    private var source: StateSource?

    func recordIdentity(name: String, agent: String) {
        identityName = name
        identityAgent = agent
    }

    func recordState(_ state: State, source: StateSource) {
        self.state = state
        self.source = source
    }

    func snapshot() -> (identityName: String?, identityAgent: String?, state: State?, source: StateSource?) {
        (identityName, identityAgent, state, source)
    }
}

private actor StringMessageRecorder {
    private var storage: String?

    func set(_ value: String) {
        storage = value
    }

    func value() -> String? {
        storage
    }
}

// MARK: - Mock WebSocket Server using Network framework

/// A simple WebSocket server for testing — accepts one or more connections,
/// calls `onConnect` with a `MockWSConnection` to send messages, and echos
/// incoming messages back if `echo` is true.
final class MockWSServer: @unchecked Sendable {
    var port: UInt16?
    var onConnect: ((MockWSConnection) -> Void)?
    var echo: Bool = false

    private var listener: NWListener?
    private var connections: [MockWSConnection] = []
    private let queue = DispatchQueue(label: "mock-ws-server")

    func start() async throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let wsConn = MockWSConnection(connection: conn, queue: self.queue)
            self.connections.append(wsConn)
            wsConn.start()
            self.onConnect?(wsConn)
        }

        // Use continuation to wait until listener is ready
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                case .failed(let error):
                    cont.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }

        if let p = listener.port?.rawValue {
            self.port = p
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }
}

final class MockWSConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    var echoHandler: ((String) -> String?)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.start(queue: queue)
        receiveLoop()
    }

    func send(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "ws-text",
            metadata: [metadata]
        )
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    func cancel() {
        connection.cancel()
    }

    func close(code: NWProtocolWebSocket.CloseCode, reason: String? = nil) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code
        let context = NWConnection.ContentContext(
            identifier: "ws-close",
            metadata: [metadata]
        )
        connection.send(
            content: reason?.data(using: .utf8),
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            }
        )
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self else { return }
            if let data, let text = String(data: data, encoding: .utf8) {
                if let response = self.echoHandler?(text) {
                    self.send(response)
                }
            }
            if error == nil {
                self.receiveLoop()
            }
        }
    }
}
