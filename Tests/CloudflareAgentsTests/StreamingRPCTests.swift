import XCTest
@testable import CloudflareAgents

/// Tests for the public streaming RPC API: `call(method:args:timeout:onChunk:)`.
/// Mirrors the JS client's `call(method, args, { stream: { onChunk, onDone, onError } })`:
/// intermediate `done: false` responses go to `onChunk`, the terminal response
/// resolves the call (JS `onDone`), and failures throw (JS `onError`).
final class StreamingRPCTests: XCTestCase {

    struct EmptyS: Codable, Sendable {}

    private func makeClient(port: UInt16) -> AgentClient<EmptyS> {
        AgentClient<EmptyS>(options: .init(
            agent: "my-agent", name: "room", host: "ws://localhost:\(port)"
        ))
    }

    // MARK: - Chunks delivered in order, then the call resolves with the final result

    func testStreamingCallDeliversChunksThenResolves() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }
        let port = server.port!

        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let json = try? JSONSerialization.jsonObject(with: incoming.data(using: .utf8)!) as? [String: Any],
                      json["type"] as? String == "rpc",
                      let id = json["id"] as? String else { return nil }
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
                return nil
            })
        }

        let client = makeClient(port: port)
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        let collector = StringChunkCollector()
        let result = try await client.call("streamNumbers", args: []) { chunk in
            collector.append(chunk?.value as? String)
        }

        // The terminal (done:true) result resolves the call; it is NOT delivered to onChunk.
        XCTAssertEqual(result?.value as? String, "complete")

        // Messages are processed in receive order, so by the time the done:true
        // response resolves this call, both intermediate chunks were delivered.
        let chunks = collector.values
        XCTAssertEqual(chunks, ["chunk1", "chunk2"], "onChunk receives only intermediate done:false chunks, in order")

        await client.disconnect()
    }

    // MARK: - Non-streaming response resolves without ever calling onChunk

    func testNonStreamingResponseDoesNotCallOnChunk() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }
        let port = server.port!

        // No `done` field => non-streaming response.
        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let json = try? JSONSerialization.jsonObject(with: incoming.data(using: .utf8)!) as? [String: Any],
                      json["type"] as? String == "rpc",
                      let id = json["id"] as? String else { return nil }
                return """
                {"type":"rpc","id":"\(id)","success":true,"result":42}
                """
            })
        }

        let client = makeClient(port: port)
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        let chunkFlag = BoolFlag()
        let result = try await client.call("getValue", args: []) { _ in
            chunkFlag.set()
        }

        XCTAssertEqual(result?.value as? Int, 42)
        XCTAssertFalse(chunkFlag.value, "Non-streaming response must not invoke onChunk")

        await client.disconnect()
    }

    // MARK: - Error response throws (JS onError)

    func testStreamingCallErrorThrows() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }
        let port = server.port!

        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let json = try? JSONSerialization.jsonObject(with: incoming.data(using: .utf8)!) as? [String: Any],
                      json["type"] as? String == "rpc",
                      let id = json["id"] as? String else { return nil }
                return """
                {"type":"rpc","id":"\(id)","success":false,"error":"stream blew up"}
                """
            })
        }

        let client = makeClient(port: port)
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        do {
            _ = try await client.call("badStream", args: []) { _ in }
            XCTFail("Expected streaming call to throw")
        } catch let error as AgentError {
            guard case .rpcFailed(let msg) = error else {
                return XCTFail("Expected rpcFailed, got \(error)")
            }
            XCTAssertEqual(msg, "stream blew up")
        }

        await client.disconnect()
    }

    // MARK: - Timeout fires when no terminal chunk arrives

    func testStreamingCallTimesOutWhenNeverDone() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }
        let port = server.port!

        // Server sends an intermediate chunk but never the done:true terminal.
        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let json = try? JSONSerialization.jsonObject(with: incoming.data(using: .utf8)!) as? [String: Any],
                      json["type"] as? String == "rpc",
                      let id = json["id"] as? String else { return nil }
                DispatchQueue.global().async {
                    conn.send("""
                    {"type":"rpc","id":"\(id)","success":true,"result":"partial","done":false}
                    """)
                }
                return nil
            })
        }

        let client = makeClient(port: port)
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        let collector = StringChunkCollector()
        do {
            _ = try await client.call("hangingStream", args: [], timeout: 0.3) { chunk in
                collector.append(chunk?.value as? String)
            }
            XCTFail("Expected timeout")
        } catch let error as AgentError {
            guard case .timeout(let method, _) = error else {
                return XCTFail("Expected .timeout, got \(error)")
            }
            XCTAssertEqual(method, "hangingStream")
        }

        // The intermediate chunk should still have been delivered before the timeout.
        let chunks = collector.values
        XCTAssertEqual(chunks, ["partial"])

        await client.disconnect()
    }
}

// MARK: - Test helpers

/// Lock-based (not actor) so appends inside the synchronous `onChunk` closure
/// happen in message-receive order — `handleMessage` calls `onChunk` serially,
/// so a synchronous append deterministically preserves chunk order. Routing
/// through an actor via `Task { await … }` would not guarantee FIFO ordering.
final class StringChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ value: String?) {
        guard let value else { return }
        lock.lock(); storage.append(value); lock.unlock()
    }
    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

final class BoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
