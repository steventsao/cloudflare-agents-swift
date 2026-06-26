import XCTest
@testable import CloudflareAgents

/// Tests for AIChatAgent protocol: cf_agent_chat_messages, cf_agent_use_chat_request,
/// cf_agent_use_chat_response, cf_agent_chat_clear
final class ChatProtocolTests: XCTestCase {

    struct EmptyS: Codable, Sendable {}

    // MARK: - ChatRequest encode

    func testChatRequestEncode() throws {
        let req = ChatRequest(id: "req-1", body: "{\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}")
        let data = try JSONEncoder().encode(req)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "cf_agent_use_chat_request")
        XCTAssertEqual(json["id"] as? String, "req-1")
        // Body must be wrapped in `init` (RequestInit) — the cloudflare/agents
        // server reads `data.init.method` / `data.init.body`, never a top-level body.
        XCTAssertNil(json["body"], "body must not be at the top level")
        let initObj = try XCTUnwrap(json["init"] as? [String: Any])
        XCTAssertEqual(initObj["method"] as? String, "POST")
        XCTAssertTrue((initObj["body"] as? String)?.contains("hello") == true)
    }

    func testChatRequestAutoId() throws {
        let req = ChatRequest(body: "{}")
        XCTAssertFalse(req.id.isEmpty)
        XCTAssertEqual(req.type, .chatRequest)
        XCTAssertEqual(req.requestInit.method, "POST")
        XCTAssertEqual(req.requestInit.body, "{}")
    }

    /// The encoded frame must contain exactly `{ type, id, init: { method, body } }`
    /// and round-trip back to the same values — this is the contract the
    /// cloudflare/agents server (`data.init.method` / `data.init.body`) relies on.
    func testChatRequestExactFrameAndRoundTrip() throws {
        let payload = "{\"messages\":[{\"id\":\"user-1\",\"role\":\"user\",\"parts\":[{\"type\":\"text\",\"text\":\"hi\"}]}]}"
        let req = ChatRequest(id: "req-9", body: payload)
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(json.keys), ["type", "id", "init"], "frame must have exactly type/id/init")
        let initObj = try XCTUnwrap(json["init"] as? [String: Any])
        XCTAssertEqual(Set(initObj.keys), ["method", "body"])
        XCTAssertEqual(initObj["method"] as? String, "POST")
        XCTAssertEqual(initObj["body"] as? String, payload)

        // Decoding back through the `init` CodingKey must restore the body verbatim.
        let decoded = try JSONDecoder().decode(ChatRequest.self, from: data)
        XCTAssertEqual(decoded.id, "req-9")
        XCTAssertEqual(decoded.type, .chatRequest)
        XCTAssertEqual(decoded.requestInit.method, "POST")
        XCTAssertEqual(decoded.requestInit.body, payload)
    }

    // MARK: - ChatResponse decode

    func testChatResponseDecode() throws {
        let json = """
        {"type":"cf_agent_use_chat_response","id":"req-1","body":"Hello","done":false}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ChatResponse.self, from: json)
        XCTAssertEqual(resp.type, .chatResponse)
        XCTAssertEqual(resp.id, "req-1")
        XCTAssertEqual(resp.body, "Hello")
        XCTAssertFalse(resp.done)
        XCTAssertNil(resp.error)
    }

    func testChatResponseDecodeWithAllFields() throws {
        let json = """
        {"type":"cf_agent_use_chat_response","id":"req-2","body":"chunk","done":true,"error":false,"continuation":true,"replay":false}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(ChatResponse.self, from: json)
        XCTAssertTrue(resp.done)
        XCTAssertEqual(resp.error, false)
        XCTAssertEqual(resp.continuation, true)
        XCTAssertEqual(resp.replay, false)
    }

    // MARK: - Current chat protocol control frames

    func testChatRequestCancelEncode() throws {
        let cancel = ChatRequestCancelMessage(id: "req-1")
        let data = try JSONEncoder().encode(cancel)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["type"] as? String, "cf_agent_chat_request_cancel")
        XCTAssertEqual(json["id"] as? String, "req-1")
    }

    func testChatStreamResumeAckRoundTrip() throws {
        let ack = ChatStreamResumeAckMessage(id: "req-2")
        let data = try JSONEncoder().encode(ack)
        let decoded = try JSONDecoder().decode(ChatStreamResumeAckMessage.self, from: data)

        XCTAssertEqual(decoded.type, .streamResumeAck)
        XCTAssertEqual(decoded.id, "req-2")
    }

    func testChatNoPayloadControlMessagesDecode() throws {
        let controlTypes: [(MessageType, String)] = [
            (.streamResuming, "cf_agent_stream_resuming"),
            (.streamResumeRequest, "cf_agent_stream_resume_request"),
            (.streamResumeNone, "cf_agent_stream_resume_none"),
            (.streamPending, "cf_agent_stream_pending"),
            (.messageUpdated, "cf_agent_message_updated"),
            (.chatRecovering, "cf_agent_chat_recovering"),
        ]

        for (expectedType, wireType) in controlTypes {
            let data = #"{"type":"\#(wireType)"}"#.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(ChatControlMessage.self, from: data)
            XCTAssertEqual(decoded.type, expectedType)
        }
    }

    func testChatStreamPendingFrameIncludesOptionalId() throws {
        let withID = #"{"type":"cf_agent_stream_pending","id":"req-1"}"#.data(using: .utf8)!
        let decodedWithID = try JSONDecoder().decode(ChatStreamPendingMessage.self, from: withID)

        XCTAssertEqual(decodedWithID.type, .streamPending)
        XCTAssertEqual(decodedWithID.id, "req-1")

        let withoutID = #"{"type":"cf_agent_stream_pending"}"#.data(using: .utf8)!
        let decodedWithoutID = try JSONDecoder().decode(ChatStreamPendingMessage.self, from: withoutID)

        XCTAssertEqual(decodedWithoutID.type, .streamPending)
        XCTAssertNil(decodedWithoutID.id)
    }

    func testChatToolResultRoundTrip() throws {
        let result = ChatToolResultMessage(
            toolCallId: "tc-1",
            toolName: "getWeather",
            output: ["temp": 72, "unit": "f"],
            state: "output-available",
            autoContinue: true,
            clientTools: [
                ChatClientToolSchema(
                    name: "pickCity",
                    description: "Choose a city",
                    parameters: ["type": "object"]
                )
            ]
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ChatToolResultMessage.self, from: data)

        XCTAssertEqual(decoded.type, .toolResult)
        XCTAssertEqual(decoded.toolCallId, "tc-1")
        XCTAssertEqual(decoded.toolName, "getWeather")
        XCTAssertEqual(decoded.state, "output-available")
        XCTAssertEqual(decoded.autoContinue, true)
        XCTAssertEqual(decoded.clientTools?.first?.name, "pickCity")
        let output = try XCTUnwrap(decoded.output?.value as? [String: Any])
        XCTAssertEqual(output["temp"] as? Int, 72)
        XCTAssertEqual(output["unit"] as? String, "f")
    }

    func testChatToolApprovalRoundTrip() throws {
        let approval = ChatToolApprovalMessage(toolCallId: "tc-2", approved: true, autoContinue: false)
        let data = try JSONEncoder().encode(approval)
        let decoded = try JSONDecoder().decode(ChatToolApprovalMessage.self, from: data)

        XCTAssertEqual(decoded.type, .toolApproval)
        XCTAssertEqual(decoded.toolCallId, "tc-2")
        XCTAssertTrue(decoded.approved)
        XCTAssertEqual(decoded.autoContinue, false)
    }

    // MARK: - sendChatRequest sends correct JSON over WS

    func testSendChatRequestSendsToServer() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!
        let messageExpectation = expectation(description: "server received chat request")
        let captured = CapturedJSON()

        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                if let data = incoming.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["type"] as? String == "cf_agent_use_chat_request" {
                    Task { await captured.set(json) }
                    messageExpectation.fulfill()
                }
                return nil
            })
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "chat-agent", name: "room",
            host: "ws://localhost:\(port)"
        ))

        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await client.sendChatRequest(body: "{\"messages\":[]}", id: "test-req-1")

        await fulfillment(of: [messageExpectation], timeout: 2.0)

        let json = await captured.value
        XCTAssertEqual(json?["type"] as? String, "cf_agent_use_chat_request")
        XCTAssertEqual(json?["id"] as? String, "test-req-1")
        // Wire format must match the JS useAgentChat transport: { init: { method, body } }
        XCTAssertNil(json?["body"], "body must be nested under init, not top-level")
        let initObj = try XCTUnwrap(json?["init"] as? [String: Any])
        XCTAssertEqual(initObj["method"] as? String, "POST")
        XCTAssertEqual(initObj["body"] as? String, "{\"messages\":[]}")

        await client.disconnect()
    }

    // MARK: - Client receives chat response chunks

    func testClientReceivesChatResponseChunks() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let data = incoming.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "cf_agent_use_chat_request",
                      let id = json["id"] as? String else { return nil }
                DispatchQueue.global().async {
                    conn.send("""
                    {"type":"cf_agent_use_chat_response","id":"\(id)","body":"Hel","done":false}
                    """)
                    conn.send("""
                    {"type":"cf_agent_use_chat_response","id":"\(id)","body":"lo!","done":true}
                    """)
                }
                return nil
            })
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "chat-agent", name: "room",
            host: "ws://localhost:\(port)"
        ))

        let chunks = ChatChunkCollector()
        let doneExpectation = expectation(description: "received done=true chunk")

        await client.onChatResponse { response in
            Task {
                await chunks.append(response)
                if response.done { doneExpectation.fulfill() }
            }
        }

        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await client.sendChatRequest(body: "{}", id: "stream-1")

        await fulfillment(of: [doneExpectation], timeout: 2.0)

        let items = await chunks.items
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].body, "Hel")
        XCTAssertFalse(items[0].done)
        XCTAssertEqual(items[1].body, "lo!")
        XCTAssertTrue(items[1].done)

        await client.disconnect()
    }

    // MARK: - Client receives chat messages broadcast

    func testClientReceivesChatMessagesBroadcast() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                conn.send("""
                {"type":"cf_agent_chat_messages","messages":[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}]}
                """)
            }
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "chat-agent", name: "room",
            host: "ws://localhost:\(port)"
        ))

        let msgExpectation = expectation(description: "chat messages received")
        let captured = CapturedChatMessages()

        await client.onChatMessages { messages in
            Task {
                await captured.set(messages)
                msgExpectation.fulfill()
            }
        }

        await client.connect()
        await fulfillment(of: [msgExpectation], timeout: 2.0)

        let messages = await captured.value
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[0]["role"] as? String, "user")
        XCTAssertEqual(messages?[0]["content"] as? String, "hi")
        XCTAssertEqual(messages?[1]["role"] as? String, "assistant")
        XCTAssertEqual(messages?[1]["content"] as? String, "hello")

        await client.disconnect()
    }

    // MARK: - clearChat sends correct message

    func testClearChatSendsToServer() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!
        let clearExpectation = expectation(description: "server received clear")

        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                if let data = incoming.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["type"] as? String == "cf_agent_chat_clear" {
                    clearExpectation.fulfill()
                }
                return nil
            })
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "chat-agent", name: "room",
            host: "ws://localhost:\(port)"
        ))

        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)
        try await client.clearChat()

        await fulfillment(of: [clearExpectation], timeout: 2.0)
        await client.disconnect()
    }

    // MARK: - Client receives chat clear from server

    func testClientReceivesChatClear() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                conn.send("""
                {"type":"cf_agent_chat_clear"}
                """)
            }
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "chat-agent", name: "room",
            host: "ws://localhost:\(port)"
        ))

        let clearExpectation = expectation(description: "chat clear received")
        await client.onChatClear { clearExpectation.fulfill() }

        await client.connect()
        await fulfillment(of: [clearExpectation], timeout: 2.0)
        await client.disconnect()
    }

    // MARK: - Full chat round trip

    func testFullChatRoundTrip() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_identity","name":"r","agent":"a"}
            """)
            conn.startEchoing(handler: { incoming in
                guard let data = incoming.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "cf_agent_use_chat_request",
                      let id = json["id"] as? String else { return nil }
                DispatchQueue.global().async {
                    conn.send("""
                    {"type":"cf_agent_use_chat_response","id":"\(id)","body":"Hi","done":false}
                    """)
                    conn.send("""
                    {"type":"cf_agent_use_chat_response","id":"\(id)","body":" there","done":true}
                    """)
                    conn.send("""
                    {"type":"cf_agent_chat_messages","messages":[{"role":"user","content":"hello"},{"role":"assistant","content":"Hi there"}]}
                    """)
                }
                return nil
            })
        }

        let client = AgentClient<EmptyS>(options: .init(
            agent: "a", name: "r",
            host: "ws://localhost:\(port)"
        ))

        let chunks = ChatChunkCollector()
        let messagesExpectation = expectation(description: "final messages broadcast")
        let captured = CapturedChatMessages()

        await client.onChatResponse { response in
            Task { await chunks.append(response) }
        }
        await client.onChatMessages { messages in
            Task {
                await captured.set(messages)
                messagesExpectation.fulfill()
            }
        }

        await client.connect()
        await client.waitForReady()
        try await client.sendChatRequest(body: "{}", id: "rnd-1")

        await fulfillment(of: [messagesExpectation], timeout: 2.0)

        let chunkItems = await chunks.items
        XCTAssertGreaterThanOrEqual(chunkItems.count, 2)

        let messages = await captured.value
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?[1]["content"] as? String, "Hi there")

        await client.disconnect()
    }
}

// MARK: - Thread-safe actors for test assertions

actor ChatChunkCollector {
    var items: [ChatResponse] = []
    func append(_ item: ChatResponse) { items.append(item) }
}

actor CapturedChatMessages {
    var value: [[String: Any]]?
    func set(_ v: [[String: Any]]) { value = v }
}

actor CapturedJSON {
    var value: [String: Any]?
    func set(_ v: [String: Any]) { value = v }
}
