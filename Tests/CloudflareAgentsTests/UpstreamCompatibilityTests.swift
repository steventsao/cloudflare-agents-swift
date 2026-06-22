import XCTest
@testable import CloudflareAgents

/// Optional integration tests against cloudflare/agents' own Wrangler test worker.
///
/// These are skipped unless CF_AGENTS_TEST_WORKER_URL is set, for example:
/// CF_AGENTS_TEST_WORKER_URL=http://127.0.0.1:18787 swift test --filter UpstreamCompatibilityTests
final class UpstreamCompatibilityTests: XCTestCase {
    struct TestState: Codable, Sendable, Equatable {
        let count: Int
        let items: [String]
        let lastUpdated: String?
    }

    struct CallableState: Codable, Sendable, Equatable {
        let value: Int
    }

    struct CountState: Codable, Sendable, Equatable {
        let count: Int
    }

    private func workerURL() throws -> String {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["CF_AGENTS_TEST_WORKER_URL"], !url.isEmpty else {
            throw XCTSkip("Set CF_AGENTS_TEST_WORKER_URL to run upstream Cloudflare Agents compatibility tests")
        }
        return url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func room(_ suffix: String = "") -> String {
        let id = UUID().uuidString.lowercased()
        return suffix.isEmpty ? "swift-\(id)" : "swift-\(suffix)-\(id)"
    }

    func testIdentityAndInitialStateFromUpstreamWorker() async throws {
        let host = try workerURL()
        let client = AgentClient<TestState>(options: .init(
            agent: "TestStateAgent",
            name: room("identity"),
            host: host
        ))

        let identityExpectation = expectation(description: "identity received")
        let stateExpectation = expectation(description: "initial state received")
        stateExpectation.assertForOverFulfill = false

        await client.onIdentity { name, agent in
            XCTAssertTrue(name.hasPrefix("swift-identity-"))
            XCTAssertEqual(agent, "test-state-agent")
            identityExpectation.fulfill()
        }
        await client.onStateUpdate { state, source in
            XCTAssertEqual(state, TestState(count: 0, items: [], lastUpdated: nil))
            XCTAssertEqual(source, .server)
            stateExpectation.fulfill()
        }

        await client.connect()
        await fulfillment(of: [identityExpectation, stateExpectation], timeout: 5.0)

        let identified = await client.identified
        let currentState = await client.state
        XCTAssertTrue(identified)
        XCTAssertEqual(currentState, TestState(count: 0, items: [], lastUpdated: nil))

        await client.disconnect()
    }

    func testStateUpdateRoundTripsThroughUpstreamWorker() async throws {
        let host = try workerURL()
        let instanceName = room("state")
        let client = AgentClient<TestState>(options: .init(
            agent: "TestStateAgent",
            name: instanceName,
            host: host
        ))

        let expected = TestState(count: 7, items: ["swift"], lastUpdated: "2026-06-02T00:00:00Z")

        await client.connect()
        await client.waitForReady()
        try await client.setState(expected)

        let persisted = try await eventuallyFetchState(
            from: "\(host)/agents/test-state-agent/\(instanceName)/state",
            expectedCount: expected.count
        )
        XCTAssertEqual(persisted, expected)

        await client.disconnect()
    }

    func testCallableRPCAndStreamingFinalChunkAgainstUpstreamWorker() async throws {
        let host = try workerURL()
        let client = AgentClient<CallableState>(options: .init(
            agent: "TestCallableAgent",
            name: room("rpc"),
            host: host
        ))

        await client.connect()
        await client.waitForReady()

        let sum = try await client.call("add", args: [2, 3])
        XCTAssertEqual(sum?.value as? Int, 5)

        let final = try await client.call("streamNumbers", args: [3], timeout: 5.0)
        XCTAssertEqual(final?.value as? Int, 3)

        do {
            _ = try await client.call("throwError", args: ["swift failure"], timeout: 5.0)
            XCTFail("Expected upstream RPC error")
        } catch let error as AgentError {
            guard case .rpcFailed(let message) = error else {
                XCTFail("Expected rpcFailed, got \(error)")
                await client.disconnect()
                return
            }
            XCTAssertEqual(message, "swift failure")
        }

        await client.disconnect()
    }

    func testStreamingChunksArriveFromUpstreamWorker() async throws {
        let host = try workerURL()
        let client = AgentClient<CallableState>(options: .init(
            agent: "TestCallableAgent",
            name: room("stream"),
            host: host
        ))

        await client.connect()
        await client.waitForReady()

        let collector = StringChunkCollector()
        // streamNumbers(n) streams intermediate chunks and resolves with n.
        let final = try await client.call("streamNumbers", args: [3], timeout: 5.0) { chunk in
            collector.append(chunk.map { "\($0.value)" })
        }
        XCTAssertEqual(final?.value as? Int, 3)

        let chunks = collector.values
        XCTAssertFalse(chunks.isEmpty, "Expected at least one streaming chunk from the upstream worker")

        await client.disconnect()
    }

    func testNoProtocolConnectionSuppressesHandshakeButKeepsRPC() async throws {
        let host = try workerURL()
        let client = AgentClient<CountState>(options: .init(
            agent: "TestProtocolMessagesAgent",
            name: room("no-protocol"),
            host: host,
            query: ["protocol": "false"]
        ))

        await client.connect()
        try await Task.sleep(nanoseconds: 250_000_000)

        let identified = await client.identified
        let currentState = await client.state
        XCTAssertFalse(identified)
        XCTAssertNil(currentState)

        let state = try await client.call("getState", args: [], timeout: 5.0)
        let object = try XCTUnwrap(state?.value as? [String: Any])
        XCTAssertEqual(object["count"] as? Int, 0)

        await client.disconnect()
    }

    func testBasePathConnectionUsesServerIdentity() async throws {
        let host = try workerURL()
        let client = AgentClient<TestState>(options: .init(
            agent: "TestStateAgent",
            name: "ignored-client-name",
            host: host,
            basePath: "user"
        ))

        let identityExpectation = expectation(description: "basePath identity received")
        await client.onIdentity { name, agent in
            XCTAssertEqual(name, "auth-user")
            XCTAssertEqual(agent, "test-state-agent")
            identityExpectation.fulfill()
        }

        await client.connect()
        await fulfillment(of: [identityExpectation], timeout: 5.0)

        await client.disconnect()
    }

    private func eventuallyFetchState(from urlString: String, expectedCount: Int) async throws -> TestState {
        let deadline = Date().addingTimeInterval(5.0)
        var lastState: TestState?

        while Date() < deadline {
            guard let url = URL(string: urlString) else {
                throw URLError(.badURL)
            }
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode
            XCTAssertEqual(status, 200)

            struct StateResponse: Codable {
                let state: TestState
            }

            let decoded = try JSONDecoder().decode(StateResponse.self, from: data)
            lastState = decoded.state
            if decoded.state.count == expectedCount {
                return decoded.state
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }

        return try XCTUnwrap(lastState, "No state response received from upstream Worker")
    }
}
