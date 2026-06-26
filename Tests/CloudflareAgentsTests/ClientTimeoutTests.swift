import XCTest
@testable import CloudflareAgents

/// Group 6: Client timeout
/// RPC calls with a timeout parameter should reject with AgentError.timeout after N seconds.
final class ClientTimeoutTests: XCTestCase {

    // MARK: - Timeout fires when server never responds

    func testCallWithTimeoutRejectsWhenServerNeverResponds() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Server receives the RPC but never replies
        server.onConnect = { conn in
            conn.startEchoing(handler: { _ in nil })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        let start = Date()
        do {
            _ = try await client.call("slowMethod", args: [], timeout: 0.2)
            XCTFail("Expected timeout error")
        } catch let error as AgentError {
            if case .timeout(let method, let seconds) = error {
                XCTAssertEqual(method, "slowMethod")
                XCTAssertEqual(seconds, 0.2, accuracy: 0.05)
            } else {
                XCTFail("Expected .timeout, got \(error)")
            }
        }

        let elapsed = Date().timeIntervalSince(start)
        // Should have timed out around 0.2 seconds, not instantly and not too slow
        XCTAssertGreaterThan(elapsed, 0.15)
        XCTAssertLessThan(elapsed, 1.0)

        await client.disconnect()
    }

    func testCallWithTimeoutSucceedsWhenServerRespondsInTime() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Server responds quickly (after 50ms)
        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let json = try? JSONSerialization.jsonObject(with: incoming.data(using: .utf8)!) as? [String: Any],
                      let type_ = json["type"] as? String, type_ == "rpc",
                      let id = json["id"] as? String else { return nil }
                // Respond after a short delay
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    conn.send("""
                    {"type":"rpc","id":"\(id)","success":true,"result":"fast"}
                    """)
                }
                return nil
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

        // Timeout is 1 second, server responds in 50ms — should succeed
        let result = try await client.call("fastMethod", args: [], timeout: 1.0)
        XCTAssertEqual(result?.value as? String, "fast")

        await client.disconnect()
    }

    func testDefaultCallTimeoutRejectsWhenServerNeverResponds() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.startEchoing(handler: { _ in nil })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)",
            defaultCallTimeout: 0.2
        ))
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        do {
            _ = try await client.call("slowByDefault", args: [])
            XCTFail("Expected default timeout error")
        } catch let error as AgentError {
            guard case .timeout(let method, let seconds) = error else {
                return XCTFail("Expected .timeout, got \(error)")
            }
            XCTAssertEqual(method, "slowByDefault")
            XCTAssertEqual(seconds, 0.2, accuracy: 0.05)
        }

        await client.disconnect()
    }

    func testDefaultCallTimeoutCanBeDisabled() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.startEchoing(handler: { _ in nil })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)",
            defaultCallTimeout: 0
        ))
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        let captured = CapturedTimeoutError()
        let callTask = Task {
            do {
                _ = try await client.call("waitUntilDisconnect", args: [])
            } catch {
                await captured.set(error)
            }
        }

        try await Task.sleep(nanoseconds: 250_000_000)
        let pendingError = await captured.value
        XCTAssertNil(pendingError, "Disabled default timeout should keep the call pending")

        await client.disconnect()
        await callTask.value

        let error = await captured.value
        guard let agentError = error as? AgentError, case .connectionClosed = agentError else {
            return XCTFail("Expected disconnect to reject the pending call, got \(String(describing: error))")
        }
    }

    func testExplicitZeroTimeoutDisablesTimeout() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.startEchoing(handler: { _ in nil })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)",
            defaultCallTimeout: 0.1
        ))
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        let captured = CapturedTimeoutError()
        let callTask = Task {
            do {
                _ = try await client.call("explicitlyNoTimeout", args: [], timeout: 0)
            } catch {
                await captured.set(error)
            }
        }

        try await Task.sleep(nanoseconds: 250_000_000)
        let pendingError = await captured.value
        XCTAssertNil(pendingError, "Explicit timeout 0 should disable the timeout")

        await client.disconnect()
        await callTask.value

        let error = await captured.value
        guard let agentError = error as? AgentError, case .connectionClosed = agentError else {
            return XCTFail("Expected disconnect to reject the pending call, got \(String(describing: error))")
        }
    }

    func testCallWithZeroTimeoutRejectsImmediately() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        server.onConnect = { conn in
            conn.startEchoing(handler: { _ in nil })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Timeout near-zero
        do {
            _ = try await client.call("method", args: [], timeout: 0.001)
            XCTFail("Expected timeout")
        } catch is AgentError {
            // Expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }

        await client.disconnect()
    }

    // MARK: - Timeout error description

    func testTimeoutErrorDescription() {
        let err = AgentError.timeout(method: "myMethod", seconds: 5.0)
        XCTAssertTrue(err.errorDescription?.contains("myMethod") ?? false)
        XCTAssertTrue(err.errorDescription?.contains("5.0") ?? false)
    }

    // MARK: - Multiple calls, only the slow one times out

    func testOnlySlowCallTimesOut() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Server: responds to "fast" immediately, never responds to "slow"
        server.onConnect = { conn in
            conn.startEchoing(handler: { incoming in
                guard let json = try? JSONSerialization.jsonObject(with: incoming.data(using: .utf8)!) as? [String: Any],
                      let type_ = json["type"] as? String, type_ == "rpc",
                      let id = json["id"] as? String,
                      let method = json["method"] as? String else { return nil }
                if method == "fast" {
                    return """
                    {"type":"rpc","id":"\(id)","success":true,"result":"done"}
                    """
                }
                return nil // slow: never respond
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

        // Fast call succeeds
        let fastResult = try await client.call("fast", args: [], timeout: 2.0)
        XCTAssertEqual(fastResult?.value as? String, "done")

        // Slow call times out
        do {
            _ = try await client.call("slow", args: [], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch let err as AgentError {
            if case .timeout(let method, _) = err {
                XCTAssertEqual(method, "slow")
            } else {
                XCTFail("Expected .timeout, got \(err)")
            }
        }

        await client.disconnect()
    }

    // MARK: - Disconnect cancels pending calls

    func testDisconnectRejectsPendingCalls() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }

        let port = server.port!

        // Server never responds
        server.onConnect = { conn in
            conn.startEchoing(handler: { _ in nil })
        }

        struct EmptyS: Codable, Sendable {}
        let client = AgentClient<EmptyS>(options: .init(
            agent: "my-agent",
            name: "room",
            host: "ws://localhost:\(port)"
        ))
        await client.connect()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Start a call (no timeout) that will never get a response
        var callError: Error?
        let callTask = Task {
            do {
                _ = try await client.call("neverReturns", args: [])
            } catch {
                callError = error
            }
        }

        // Let the call be in-flight
        try await Task.sleep(nanoseconds: 100_000_000)

        // Disconnect should reject the pending call
        await client.disconnect()

        // Wait for the call task to complete
        await callTask.value

        XCTAssertNotNil(callError, "Pending call should have been rejected on disconnect")
        if let agentErr = callError as? AgentError, case .connectionClosed = agentErr {
            // Expected
        } else {
            XCTFail("Expected connectionClosed error, got \(String(describing: callError))")
        }
    }
}

private actor CapturedTimeoutError {
    private(set) var value: Error?

    func set(_ error: Error) {
        value = error
    }
}
