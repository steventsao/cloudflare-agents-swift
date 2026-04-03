import XCTest
@testable import CloudflareAgents

final class MessageTypeTests: XCTestCase {
    func testMessageTypeRawValues() {
        // Must match cloudflare/agents TypeScript MessageType enum exactly
        XCTAssertEqual(MessageType.identity.rawValue, "cf_agent_identity")
        XCTAssertEqual(MessageType.state.rawValue, "cf_agent_state")
        XCTAssertEqual(MessageType.stateError.rawValue, "cf_agent_state_error")
        XCTAssertEqual(MessageType.mcpServers.rawValue, "cf_agent_mcp_servers")
        XCTAssertEqual(MessageType.mcpEvent.rawValue, "cf_mcp_agent_event")
        XCTAssertEqual(MessageType.session.rawValue, "cf_agent_session")
        XCTAssertEqual(MessageType.sessionError.rawValue, "cf_agent_session_error")
        XCTAssertEqual(MessageType.rpc.rawValue, "rpc")
    }

    func testIdentityMessageDecode() throws {
        let json = """
        {"type":"cf_agent_identity","name":"my-room","agent":"chat-agent"}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(IdentityMessage.self, from: json)
        XCTAssertEqual(msg.type, .identity)
        XCTAssertEqual(msg.name, "my-room")
        XCTAssertEqual(msg.agent, "chat-agent")
    }

    func testStateMessageRoundTrip() throws {
        struct TestState: Codable, Sendable, Equatable {
            let count: Int
        }

        let original = StateMessage(type: .state, state: TestState(count: 42))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StateMessage<TestState>.self, from: data)
        XCTAssertEqual(decoded.type, .state)
        XCTAssertEqual(decoded.state, original.state)
    }

    func testRPCRequestEncode() throws {
        let request = RPCRequest(method: "incrementCount", args: [])
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["type"] as? String, "rpc")
        XCTAssertEqual(json["method"] as? String, "incrementCount")
        XCTAssertNotNil(json["id"] as? String)
        XCTAssertEqual((json["args"] as? [Any])?.count, 0)
    }

    func testRPCRequestWithArgs() throws {
        let request = RPCRequest(method: "addServer", args: ["my-server", "https://example.com"])
        let data = try JSONEncoder().encode(request)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["method"] as? String, "addServer")
        let args = json["args"] as? [String]
        XCTAssertEqual(args?.count, 2)
        XCTAssertEqual(args?[0], "my-server")
        XCTAssertEqual(args?[1], "https://example.com")
    }

    func testRPCResponseDecodeSuccess() throws {
        let json = """
        {"type":"rpc","id":"abc-123","success":true,"result":42}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(RPCResponse.self, from: json)
        XCTAssertEqual(response.type, .rpc)
        XCTAssertEqual(response.id, "abc-123")
        XCTAssertTrue(response.success)
        XCTAssertNil(response.error)
    }

    func testRPCResponseDecodeError() throws {
        let json = """
        {"type":"rpc","id":"abc-456","success":false,"error":"Connection is readonly"}
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(RPCResponse.self, from: json)
        XCTAssertFalse(response.success)
        XCTAssertEqual(response.error, "Connection is readonly")
    }

    func testRPCResponseDecodeStreaming() throws {
        // Non-final chunk
        let chunk = """
        {"type":"rpc","id":"stream-1","success":true,"result":"partial","done":false}
        """.data(using: .utf8)!
        let chunkMsg = try JSONDecoder().decode(RPCResponse.self, from: chunk)
        XCTAssertEqual(chunkMsg.done, false)

        // Final chunk
        let final = """
        {"type":"rpc","id":"stream-1","success":true,"result":"complete","done":true}
        """.data(using: .utf8)!
        let finalMsg = try JSONDecoder().decode(RPCResponse.self, from: final)
        XCTAssertEqual(finalMsg.done, true)
    }

    func testStateErrorMessageDecode() throws {
        let json = """
        {"type":"cf_agent_state_error","error":"Connection is readonly"}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(StateErrorMessage.self, from: json)
        XCTAssertEqual(msg.type, .stateError)
        XCTAssertEqual(msg.error, "Connection is readonly")
    }

    func testAnyCodableTypes() throws {
        // String
        let s: AnyCodable = "hello"
        let sData = try JSONEncoder().encode(s)
        let sDecoded = try JSONDecoder().decode(AnyCodable.self, from: sData)
        XCTAssertEqual(sDecoded.value as? String, "hello")

        // Int
        let i: AnyCodable = 42
        let iData = try JSONEncoder().encode(i)
        let iDecoded = try JSONDecoder().decode(AnyCodable.self, from: iData)
        XCTAssertEqual(iDecoded.value as? Int, 42)

        // Bool
        let b: AnyCodable = true
        let bData = try JSONEncoder().encode(b)
        let bDecoded = try JSONDecoder().decode(AnyCodable.self, from: bData)
        XCTAssertEqual(bDecoded.value as? Bool, true)

        // Null
        let n: AnyCodable = nil
        let nData = try JSONEncoder().encode(n)
        let nStr = String(data: nData, encoding: .utf8)
        XCTAssertEqual(nStr, "null")

        // Array
        let a: AnyCodable = ["one", "two"]
        let aData = try JSONEncoder().encode(a)
        let aDecoded = try JSONDecoder().decode(AnyCodable.self, from: aData)
        XCTAssertEqual((aDecoded.value as? [Any])?.count, 2)
    }
}
