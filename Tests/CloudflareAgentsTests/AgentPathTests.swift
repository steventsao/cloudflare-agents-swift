import XCTest
@testable import CloudflareAgents

/// Parity tests against cloudflare/agents `buildAgentPath` / `buildAgentUrl` (v0.21.0).
final class AgentPathTests: XCTestCase {
    func testRequiresRootIdentity() {
        XCTAssertThrowsError(try buildAgentPath([])) { error in
            XCTAssertEqual(error as? AgentPathError, .emptyPath)
        }
    }

    func testBuildsCanonicalRootFirstNestedPath() throws {
        let pathname = try buildAgentPath(
            [
                AgentPathStep(className: "Inbox", name: "user-123"),
                AgentPathStep(className: "ChatAgent", name: "chat/a"),
            ],
            options: .init(leafPath: "/callbacks/job")
        )
        XCTAssertEqual(
            pathname,
            "/agents/inbox/user-123/sub/chat-agent/chat%2Fa/callbacks/job"
        )
    }

    func testPreservesRootLeafPathname() throws {
        XCTAssertEqual(
            try buildAgentPath(
                [AgentPathStep(className: "Inbox", name: "user-123")],
                options: .init(leafPath: "/")
            ),
            "/agents/inbox/user-123/"
        )
        XCTAssertEqual(
            try buildAgentPath(
                [
                    AgentPathStep(className: "Inbox", name: "user-123"),
                    AgentPathStep(className: "Chat", name: "chat-456"),
                ],
                options: .init(leafPath: "/")
            ),
            "/agents/inbox/user-123/sub/chat/chat-456/"
        )
    }

    func testPreservesLiteralPercentRootName() throws {
        XCTAssertEqual(
            try buildAgentPath([AgentPathStep(className: "Inbox", name: "user%2F123")]),
            "/agents/inbox/user%2F123"
        )
    }

    func testEncodesChildNames() throws {
        XCTAssertEqual(
            try buildAgentPath([
                AgentPathStep(className: "Inbox", name: "user-123"),
                AgentPathStep(className: "Chat", name: "space ü?%#"),
            ]),
            "/agents/inbox/user-123/sub/chat/space%20%C3%BC%3F%25%23"
        )
    }

    func testBuildAgentURLWithoutInheritingBasePathname() throws {
        let url = try buildAgentURL(
            origin: "https://app.example.com/",
            path: [AgentPathStep(className: "Inbox", name: "user-123")],
            options: .init(leafPath: "/webhooks/complete")
        )
        XCTAssertEqual(url.absoluteString, "https://app.example.com/agents/inbox/user-123/webhooks/complete")
    }

    func testRejectsNonRoutableRootNames() {
        let names = ["", ".", "..", "%2e", "%2e%2e", "has/slash", "has?query", "has#fragment", "has space", "ümlaut"]
        for name in names {
            XCTAssertThrowsError(
                try buildAgentPath([AgentPathStep(className: "Inbox", name: name)]),
                name
            )
        }
    }

    func testRejectsNonRoutableChildNames() {
        let names = ["", ".", "..", "has\0null"]
        for name in names {
            XCTAssertThrowsError(
                try buildAgentPath([
                    AgentPathStep(className: "Inbox", name: "user-123"),
                    AgentPathStep(className: "Chat", name: name),
                ]),
                name
            )
        }
    }

    func testRejectsNonRoutableClassNames() {
        for className in ["", ".", "..", "Has/Slash", "Has?Query", "Has#Fragment"] {
            XCTAssertThrowsError(
                try buildAgentPath([AgentPathStep(className: className, name: "user-123")]),
                className
            )
        }
    }

    func testRejectsReservedSubSeparatorIdentities() {
        XCTAssertThrowsError(try buildAgentPath([AgentPathStep(className: "Sub", name: "root")]))
        XCTAssertThrowsError(try buildAgentPath([AgentPathStep(className: "Inbox", name: "sub")]))
        XCTAssertThrowsError(
            try buildAgentPath([
                AgentPathStep(className: "Inbox", name: "user-123"),
                AgentPathStep(className: "Sub", name: "child"),
            ])
        )
    }

    func testSupportsDistinctRootBinding() throws {
        XCTAssertEqual(
            try buildAgentPath(
                [AgentPathStep(className: "CounterAgent", name: "user-123")],
                options: .init(rootBinding: "COUNTER_DO")
            ),
            "/agents/counter-do/user-123"
        )
    }

    func testSupportsMultiSegmentPrefix() throws {
        XCTAssertEqual(
            try buildAgentPath(
                [AgentPathStep(className: "Inbox", name: "user-123")],
                options: .init(prefix: "api/agents")
            ),
            "/api/agents/inbox/user-123"
        )
    }

    func testRejectsInvalidRoutingPrefixes() {
        for prefix in ["", "/agents", "agents/", "api//agents", "api/./agents", "api/../agents", "api/sub", "api?version=1"] {
            XCTAssertThrowsError(
                try buildAgentPath(
                    [AgentPathStep(className: "Inbox", name: "user-123")],
                    options: .init(prefix: prefix)
                ),
                prefix
            )
        }
    }

    func testRejectsInvalidLeafPaths() {
        for leafPath in ["/callback?code=test", "/callback#complete", "/api/../callback", "/callbacks//job", "/callbacks/", "/has space"] {
            XCTAssertThrowsError(
                try buildAgentPath(
                    [AgentPathStep(className: "Inbox", name: "user-123")],
                    options: .init(leafPath: leafPath)
                ),
                leafPath
            )
        }
    }

    func testBuildsWebSocketURL() throws {
        let url = try buildAgentURL(
            origin: "wss://app.example.com",
            path: [AgentPathStep(className: "Inbox", name: "user-123")]
        )
        XCTAssertEqual(url.absoluteString, "wss://app.example.com/agents/inbox/user-123")
    }

    func testRejectsInvalidOrigins() {
        for origin in [
            "ftp://app.example.com",
            "https://user:password@app.example.com",
            "https://app.example.com/deployment",
            "https://app.example.com/?version=1",
            "https://app.example.com/#fragment",
        ] {
            XCTAssertThrowsError(
                try buildAgentURL(
                    origin: origin,
                    path: [AgentPathStep(className: "Inbox", name: "user-123")]
                ),
                origin
            )
        }
    }

    func testUncheckedSubPathUsedByClientOptions() {
        XCTAssertEqual(
            AgentPath.buildSubAgentPathUnchecked(
                [AgentPathStep(className: "Chat", name: "abc")],
                leafPath: "settings"
            ),
            "sub/chat/abc/settings"
        )
    }
}
