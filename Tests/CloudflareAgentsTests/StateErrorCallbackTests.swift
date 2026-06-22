import XCTest
@testable import CloudflareAgents

/// Tests for `onStateError` — mirrors the JS client's `onStateUpdateError`.
/// When the server rejects a state mutation (e.g. a readonly connection), the
/// client surfaces the error message via `onStateError` and re-broadcasts the
/// last authoritative server snapshot so observers can reconcile.
final class StateErrorCallbackTests: XCTestCase {

    struct CountState: Codable, Sendable, Equatable { let count: Int }

    func testStateErrorFiresOnStateErrorCallback() async throws {
        let server = MockWSServer()
        try await server.start()
        defer { server.stop() }
        let port = server.port!

        server.onConnect = { conn in
            conn.send("""
            {"type":"cf_agent_state","state":{"count":7}}
            """)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                conn.send("""
                {"type":"cf_agent_state_error","error":"Connection is readonly"}
                """)
            }
        }

        let client = AgentClient<CountState>(options: .init(
            agent: "my-agent", name: "room", host: "ws://localhost:\(port)"
        ))

        let stateErrorRecorder = StateErrorRecorder()
        let stateErrorExp = expectation(description: "onStateError fired")
        let genericErrorExp = expectation(description: "onError fired")

        await client.onStateError { message in
            Task {
                await stateErrorRecorder.setStateError(message)
                stateErrorExp.fulfill()
            }
        }
        await client.onError { error in
            Task {
                if let agentError = error as? AgentError, case .rpcFailed(let msg) = agentError {
                    await stateErrorRecorder.setGenericError(msg)
                }
                genericErrorExp.fulfill()
            }
        }

        await client.connect()
        await fulfillment(of: [stateErrorExp, genericErrorExp], timeout: 2.0)

        let recorded = await stateErrorRecorder.snapshot()
        XCTAssertEqual(recorded.stateError, "Connection is readonly")
        // Parity is preserved: the generic onError still receives the same message.
        XCTAssertEqual(recorded.genericError, "Connection is readonly")

        // The last server snapshot is retained as the reconciled state.
        let state = await client.state
        XCTAssertEqual(state?.count, 7)

        await client.disconnect()
    }
}

actor StateErrorRecorder {
    private var stateError: String?
    private var genericError: String?
    func setStateError(_ value: String) { stateError = value }
    func setGenericError(_ value: String) { genericError = value }
    func snapshot() -> (stateError: String?, genericError: String?) { (stateError, genericError) }
}
