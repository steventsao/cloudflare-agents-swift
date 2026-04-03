import XCTest
@testable import CloudflareAgents

/// Group 2: RPC round-trip
/// Encode request, decode success/error responses, streaming chunks with done:true/false
final class RPCRoundTripTests: XCTestCase {

    // MARK: - RPC success round-trip via mock server

    func testRPCCallSuccessResult() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Server echoes back RPC success responses
        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let json = try? JSONSerialization.jsonObject(with: incoming.data(using: .utf8)!) as? [String: Any],
                      let type_ = json["type"] as? String, type_ == "rpc",
                      let id = json["id"] as? String else { return nil }
                return """
                {"type":"rpc","id":"\(id)","success":true,"result":42}
                """
            })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        let result = try await client.call("increment", args: [])
        XCTAssertEqual(result?.value as? Int, 42)

        await client.disconnect()
    }

    func testRPCCallErrorResult() async throws {
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
                {"type":"rpc","id":"\(id)","success":false,"error":"Connection is readonly"}
                """
            })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        do {
            _ = try await client.call("increment", args: [])
            XCTFail("Expected error to be thrown")
        } catch let error as AgentError {
            if case .rpcFailed(let msg) = error {
                XCTAssertEqual(msg, "Connection is readonly")
            } else {
                XCTFail("Expected rpcFailed, got \(error)")
            }
        }

        await client.disconnect()
    }

    func testRPCCallWithStringArgs() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Server reflects args back as result
        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let json = try? JSONSerialization.jsonObject(with: incoming.data(using: .utf8)!) as? [String: Any],
                      let type_ = json["type"] as? String, type_ == "rpc",
                      let id = json["id"] as? String,
                      let args = json["args"] as? [String] else { return nil }
                let joined = args.joined(separator: ",")
                return """
                {"type":"rpc","id":"\(id)","success":true,"result":"\(joined)"}
                """
            })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        let result = try await client.call("join", args: ["hello", "world"])
        XCTAssertEqual(result?.value as? String, "hello,world")

        await client.disconnect()
    }

    func testRPCNilResult() async throws {
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
                {"type":"rpc","id":"\(id)","success":true}
                """
            })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        let result = try await client.call("doSomething", args: [])
        XCTAssertNil(result)

        await client.disconnect()
    }

    // MARK: - Multiple concurrent RPC calls

    func testConcurrentRPCCallsResolveCorrectly() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Server responds to each RPC with the method name as result
        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let json = try? JSONSerialization.jsonObject(with: incoming.data(using: .utf8)!) as? [String: Any],
                      let type_ = json["type"] as? String, type_ == "rpc",
                      let id = json["id"] as? String,
                      let method = json["method"] as? String else { return nil }
                return """
                {"type":"rpc","id":"\(id)","success":true,"result":"\(method)"}
                """
            })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Fire 3 concurrent calls
        async let r1 = client.call("methodA", args: [])
        async let r2 = client.call("methodB", args: [])
        async let r3 = client.call("methodC", args: [])

        let (v1, v2, v3) = try await (r1, r2, r3)
        XCTAssertEqual(v1?.value as? String, "methodA")
        XCTAssertEqual(v2?.value as? String, "methodB")
        XCTAssertEqual(v3?.value as? String, "methodC")

        await client.disconnect()
    }

    // MARK: - Streaming RPC chunks (done: false / done: true)

    func testRPCStreamingChunks() async throws {
        // Streaming is currently resolved at the done:true chunk (last chunk wins)
        // This test verifies the RPCResponse model and server can send done:false chunks
        // followed by a done:true final chunk.
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Server sends 3 chunks then final
        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let json = try? JSONSerialization.jsonObject(with: incoming.data(using: .utf8)!) as? [String: Any],
                      let type_ = json["type"] as? String, type_ == "rpc",
                      let id = json["id"] as? String else { return nil }

                // Send intermediate chunks via a background task
                DispatchQueue.global().async {
                    conn.send("""
                    {"type":"rpc","id":"\(id)","success":true,"result":"chunk1","done":false}
                    """)
                    conn.send("""
                    {"type":"rpc","id":"\(id)","success":true,"result":"chunk2","done":false}
                    """)
                    conn.send("""
                    {"type":"rpc","id":"\(id)","success":true,"result":"complete","done":true}
                    """)
                }
                return nil // handled async
            })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        // The current client resolves on done:true with the final result
        let result = try await client.call("stream", args: [])
        XCTAssertEqual(result?.value as? String, "complete")

        await client.disconnect()
    }
}

// MARK: - Extension on MockWSConnection for echo-handler pattern

extension MockWSConnection {
    /// Start receiving messages and calling `handler` for each one.
    /// If handler returns a non-nil string, send it back.
    func startEchoing(handler: @escaping (String) -> String?) {
        self.echoHandler = handler
    }
}
