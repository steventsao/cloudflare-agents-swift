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

/// Chat request sent by client (ai-chat protocol)
public struct ChatRequest: Codable, Sendable {
    public let type: MessageType
    public let id: String
    /// Encoded RequestInit body (JSON string of the request)
    public let body: String

    public init(id: String = UUID().uuidString.lowercased(), body: String) {
        self.type = .chatRequest
        self.id = id
        self.body = body
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
