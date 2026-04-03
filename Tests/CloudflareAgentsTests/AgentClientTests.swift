import XCTest
@testable import CloudflareAgents

final class AgentClientTests: XCTestCase {
    func testCamelCaseToKebabCase() {
        // Matching JS: camelCaseToKebabCase("ChatAgent") -> "chat-agent"
        let options = AgentClient<EmptyState>.Options(
            agent: "ChatAgent",
            name: "my-room",
            host: "http://localhost:8787"
        )
        let client = AgentClient<EmptyState>(options: options)
        // agentName should be kebab-cased
        Task {
            let name = await client.agentName
            XCTAssertEqual(name, "chat-agent")
        }
    }

    func testURLConstructionStandard() async {
        let options = AgentClient<EmptyState>.Options(
            agent: "ChatAgent",
            name: "my-room",
            host: "https://example.com"
        )
        let client = AgentClient<EmptyState>(options: options)
        let url = await client.baseURL
        // Should be: wss://example.com/agents/chat-agent/my-room
        XCTAssertEqual(url.absoluteString, "wss://example.com/agents/chat-agent/my-room")
    }

    func testURLConstructionBasePath() async {
        let options = AgentClient<EmptyState>.Options(
            agent: "ChatAgent",
            name: "my-room",
            host: "https://example.com",
            basePath: "user"
        )
        let client = AgentClient<EmptyState>(options: options)
        let url = await client.baseURL
        XCTAssertEqual(url.absoluteString, "wss://example.com/user")
    }

    func testURLConstructionWithPath() async {
        let options = AgentClient<EmptyState>.Options(
            agent: "ChatAgent",
            name: "my-room",
            host: "http://localhost:8787",
            path: "settings"
        )
        let client = AgentClient<EmptyState>(options: options)
        let url = await client.baseURL
        XCTAssertEqual(url.absoluteString, "ws://localhost:8787/agents/chat-agent/my-room/settings")
    }

    func testURLConstructionDefaultName() async {
        let options = AgentClient<EmptyState>.Options(
            agent: "MyAgent",
            host: "https://api.example.com"
        )
        let client = AgentClient<EmptyState>(options: options)
        let url = await client.baseURL
        XCTAssertEqual(url.absoluteString, "wss://api.example.com/agents/my-agent/default")
    }

    func testURLConstructionWithQuery() async {
        let options = AgentClient<EmptyState>.Options(
            agent: "ChatAgent",
            name: "room",
            host: "https://example.com",
            query: ["protocol": "false", "readonly": "true"]
        )
        let client = AgentClient<EmptyState>(options: options)
        let url = await client.baseURL
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let queryItems = Set(components.queryItems?.map { "\($0.name)=\($0.value!)" } ?? [])
        XCTAssertTrue(queryItems.contains("protocol=false"))
        XCTAssertTrue(queryItems.contains("readonly=true"))
    }

    func testInitialState() async {
        let options = AgentClient<EmptyState>.Options(
            agent: "TestAgent",
            host: "http://localhost"
        )
        let client = AgentClient<EmptyState>(options: options)
        let state = await client.state
        let identified = await client.identified
        let connState = await client.connectionState

        XCTAssertNil(state)
        XCTAssertFalse(identified)
        if case .disconnected = connState {} else {
            XCTFail("Expected disconnected state")
        }
    }

    func testWebSocketRequestPreservesCustomHeaders() async {
        let options = AgentClient<EmptyState>.Options(
            agent: "DispatchAgent",
            name: "user_123",
            host: "https://api.example.com",
            query: ["role": "desktop"],
            headers: [
                "Authorization": "Bearer test-key",
                "User-Agent": "MyApp/1.0",
            ]
        )
        let client = AgentClient<EmptyState>(options: options)
        let request = await client.makeWebSocketRequest()

        XCTAssertEqual(request.url?.absoluteString, "wss://api.example.com/agents/dispatch-agent/user_123?role=desktop")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "MyApp/1.0")
    }
}

struct EmptyState: Codable, Sendable, Equatable {}
