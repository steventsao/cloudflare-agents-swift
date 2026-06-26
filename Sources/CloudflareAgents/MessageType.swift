import Foundation

/// Wire protocol message types matching cloudflare/agents TypeScript SDK
public enum MessageType: String, Codable, Sendable {
    case identity = "cf_agent_identity"
    case state = "cf_agent_state"
    case stateError = "cf_agent_state_error"
    case mcpServers = "cf_agent_mcp_servers"
    case mcpEvent = "cf_mcp_agent_event"
    case session = "cf_agent_session"
    case sessionError = "cf_agent_session_error"
    case rpc = "rpc"
    /// ai-chat protocol
    case chatRequest = "cf_agent_use_chat_request"
    case chatResponse = "cf_agent_use_chat_response"
    case chatMessages = "cf_agent_chat_messages"
    case chatClear = "cf_agent_chat_clear"
    case chatRequestCancel = "cf_agent_chat_request_cancel"
    case streamResuming = "cf_agent_stream_resuming"
    case streamResumeAck = "cf_agent_stream_resume_ack"
    case streamResumeRequest = "cf_agent_stream_resume_request"
    case streamResumeNone = "cf_agent_stream_resume_none"
    case streamPending = "cf_agent_stream_pending"
    case toolResult = "cf_agent_tool_result"
    case toolApproval = "cf_agent_tool_approval"
    case messageUpdated = "cf_agent_message_updated"
    case chatRecovering = "cf_agent_chat_recovering"
}

/// Identity message sent by server on connect
public struct IdentityMessage: Codable, Sendable {
    public let type: MessageType
    public let name: String
    public let agent: String
}

/// State broadcast from server or state update from client
public struct StateMessage<State: Codable & Sendable>: Codable, Sendable {
    public let type: MessageType
    public let state: State
}

/// State error from server (e.g., readonly connection tried to mutate)
public struct StateErrorMessage: Codable, Sendable {
    public let type: MessageType
    public let error: String
}

/// RPC request from client to server
public struct RPCRequest: Codable, Sendable {
    public let type: MessageType
    public let id: String
    public let method: String
    public let args: [AnyCodable]

    public init(method: String, args: [AnyCodable] = []) {
        self.type = .rpc
        self.id = UUID().uuidString.lowercased()
        self.method = method
        self.args = args
    }
}

/// RPC response from server
public struct RPCResponse: Codable, Sendable {
    public let type: MessageType
    public let id: String
    public let success: Bool
    public let result: AnyCodable?
    public let error: String?
    /// For streaming responses
    public let done: Bool?
}

/// MCP server info within a McpServersMessage
public struct McpServerInfo: Codable, Sendable {
    public let name: String
    public let url: String?
    public init(name: String, url: String? = nil) {
        self.name = name
        self.url = url
    }
}

/// MCP servers list broadcast from server on connect
public struct McpServersMessage: Codable, Sendable {
    public let type: MessageType
    public let servers: [McpServerInfo]
}

/// Chat request sent by client (ai-chat protocol).
///
/// Mirrors the JS `useAgentChat` transport frame: the encoded request payload
/// is wrapped in a `RequestInit`-shaped object under the `init` key. The
/// cloudflare/agents server reads `data.init.method === "POST"` and then
/// `const { body } = data.init` (see ai-chat `ws-chat-transport.ts` and
/// `AIChatAgent.onMessage`), so the body MUST live at `init.body`, not at the
/// top level.
public struct ChatRequest: Codable, Sendable {
    /// `RequestInit`-shaped wrapper carrying the HTTP method and encoded body.
    public struct RequestInit: Codable, Sendable {
        public let method: String
        public let body: String

        public init(method: String = "POST", body: String) {
            self.method = method
            self.body = body
        }
    }

    public let type: MessageType
    public let id: String
    /// Encoded RequestInit (JSON string of the request lives in `requestInit.body`).
    public let requestInit: RequestInit

    public init(id: String = UUID().uuidString.lowercased(), body: String, method: String = "POST") {
        self.type = .chatRequest
        self.id = id
        self.requestInit = RequestInit(method: method, body: body)
    }

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case requestInit = "init"
    }
}

/// Chat response chunk from server (ai-chat protocol)
public struct ChatResponse: Codable, Sendable {
    public let type: MessageType
    public let id: String
    public let body: String
    public let done: Bool
    public let error: Bool?
    public let continuation: Bool?
    public let replay: Bool?
}

/// Cancel an in-flight chat request.
public struct ChatRequestCancelMessage: Codable, Sendable {
    public let type: MessageType
    public let id: String

    public init(id: String) {
        self.type = .chatRequestCancel
        self.id = id
    }
}

/// A stream resume acknowledgement for resumable chat streams.
public struct ChatStreamResumeAckMessage: Codable, Sendable {
    public let type: MessageType
    public let id: String

    public init(id: String) {
        self.type = .streamResumeAck
        self.id = id
    }
}

/// A stream-pending hint for resumable chat handshakes.
public struct ChatStreamPendingMessage: Codable, Sendable {
    public let type: MessageType
    public let id: String?

    public init(id: String? = nil) {
        self.type = .streamPending
        self.id = id
    }
}

/// A no-payload chat protocol control frame.
public struct ChatControlMessage: Codable, Sendable {
    public let type: MessageType

    public init(type: MessageType) {
        self.type = type
    }
}

/// Wire-format client tool schema used by the chat protocol.
public struct ChatClientToolSchema: Codable, Sendable {
    public let name: String
    public let description: String?
    public let parameters: AnyCodable?

    public init(name: String, description: String? = nil, parameters: AnyCodable? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Result returned by a client-side tool invocation.
public struct ChatToolResultMessage: Codable, Sendable {
    public let type: MessageType
    public let toolCallId: String
    public let toolName: String?
    public let output: AnyCodable?
    public let state: String?
    public let errorText: String?
    public let autoContinue: Bool?
    public let clientTools: [ChatClientToolSchema]?

    public init(
        toolCallId: String,
        toolName: String? = nil,
        output: AnyCodable? = nil,
        state: String? = nil,
        errorText: String? = nil,
        autoContinue: Bool? = nil,
        clientTools: [ChatClientToolSchema]? = nil
    ) {
        self.type = .toolResult
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.output = output
        self.state = state
        self.errorText = errorText
        self.autoContinue = autoContinue
        self.clientTools = clientTools
    }
}

/// Approval response for a tool call that requires human confirmation.
public struct ChatToolApprovalMessage: Codable, Sendable {
    public let type: MessageType
    public let toolCallId: String
    public let approved: Bool
    public let autoContinue: Bool?

    public init(toolCallId: String, approved: Bool, autoContinue: Bool? = nil) {
        self.type = .toolApproval
        self.toolCallId = toolCallId
        self.approved = approved
        self.autoContinue = autoContinue
    }
}

/// Type-erased Codable wrapper for arbitrary JSON values
public struct AnyCodable: Codable, Sendable, ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public let value: Any & Sendable

    public init(_ value: Any & Sendable) { self.value = value }
    public init(stringLiteral value: String) { self.value = value }
    public init(integerLiteral value: Int) { self.value = value }
    public init(floatLiteral value: Double) { self.value = value }
    public init(booleanLiteral value: Bool) { self.value = value }
    public init(nilLiteral: ()) { self.value = NSNull() }
    public init(arrayLiteral elements: AnyCodable...) { self.value = elements.map(\.value) }
    public init(dictionaryLiteral elements: (String, AnyCodable)...) {
        self.value = Dictionary(uniqueKeysWithValues: elements.map { ($0.0, $0.1.value) })
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode([AnyCodable].self) { value = v.map(\.value) }
        else if let v = try? container.decode([String: AnyCodable].self) {
            value = v.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    /// Create AnyCodable from any JSON-compatible value (handles primitives and containers).
    public static func fromJSONObject(_ value: Any) -> AnyCodable? {
        switch value {
        case is NSNull: return AnyCodable(NSNull() as any Sendable)
        case let v as Bool: return AnyCodable(v)
        case let v as Int: return AnyCodable(v)
        case let v as Double: return AnyCodable(v)
        case let v as String: return AnyCodable(v)
        case let v as [Any]:
            // Encode array as JSON then decode
            if let data = try? JSONSerialization.data(withJSONObject: v),
               let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data) {
                return decoded
            }
            return nil
        case let v as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: v),
               let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data) {
                return decoded
            }
            return nil
        default:
            // Try number bridging (NSNumber)
            if let n = value as? NSNumber {
                // Distinguish bool vs numeric via ObjC type encoding
                let type_ = String(cString: n.objCType)
                if type_ == "c" || type_ == "B" { return AnyCodable(n.boolValue) }
                if n.doubleValue == Double(n.intValue) { return AnyCodable(n.intValue) }
                return AnyCodable(n.doubleValue)
            }
            return nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull: try container.encodeNil()
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [Any]: try container.encode(v.map { AnyCodable($0 as any Sendable) })
        case let v as [String: Any]: try container.encode(v.mapValues { AnyCodable($0 as any Sendable) })
        default: throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Unsupported type"))
        }
    }
}
