import XCTest
@testable import CloudflareAgents

final class NamingTests: XCTestCase {
    func testCamelCaseToKebabCaseMatchesUpstream() {
        let cases: [(String, String)] = [
            ("ChatAgent", "chat-agent"),
            ("MyAssistant", "my-assistant"),
            ("AIChatAgent", "a-i-chat-agent"),
            ("MCPServer", "m-c-p-server"),
            ("HTTPClient", "h-t-t-p-client"),
            ("SimpleBot", "simple-bot"),
            ("A", "a"),
            ("AB", "ab"),
            ("ThinkTestAgent", "think-test-agent"),
            ("SCREAMING_CASE", "screaming-case"),
            ("COUNTER_DO", "counter-do"),
        ]

        for (input, expected) in cases {
            XCTAssertEqual(camelCaseToKebabCase(input), expected, input)
        }
    }

    func testEncodeURIComponentMatchesJavaScript() {
        XCTAssertEqual(encodeURIComponent("chat/a"), "chat%2Fa")
        XCTAssertEqual(encodeURIComponent("space ü?%#"), "space%20%C3%BC%3F%25%23")
        XCTAssertEqual(encodeURIComponent("abc"), "abc")
        XCTAssertEqual(encodeURIComponent("a&b"), "a%26b")
        XCTAssertEqual(encodeURIComponent("!@$()*+-._~"), "!%40%24()*%2B-._~")
    }
}
