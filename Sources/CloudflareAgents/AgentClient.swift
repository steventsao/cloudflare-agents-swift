import Foundation

/// Connection state
public enum AgentConnectionState: Sendable {
    case disconnected
    case connecting
    case connected
    case identified(name: String, agent: String)
}

/// Delegate for AgentClient events
public protocol AgentClientDelegate: AnyObject, Sendable {
    associatedtype State: Codable & Sendable

    func agentClient(_ client: AgentClient<State>, didChangeState: AgentConnectionState)
    func agentClient(_ client: AgentClient<State>, didReceiveIdentity name: String, agent: String)
    func agentClient(_ client: AgentClient<State>, didUpdateState state: State, source: StateSource)
    func agentClient(_ client: AgentClient<State>, didReceiveStateError error: String)
    func agentClient(_ client: AgentClient<State>, didReceiveError error: Error)
}

public enum StateSource: Sendable {
    case server
    case client
}

/// Swift client for Cloudflare Agents SDK — mirrors JS AgentClient
/// Connects via WebSocket, handles identity, state sync, and RPC calls
public actor AgentClient<State: Codable & Sendable> {
    public let agentName: String
    public let instanceName: String
    public let baseURL: URL

    public private(set) var connectionState: AgentConnectionState = .disconnected
    public private(set) var state: State?
    public private(set) var identified = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession
    private var pendingCalls: [String: CheckedContinuation<AnyCodable?, Error>] = [:]
    private var pendingStreamChunks: [String: (AnyCodable?) -> Void] = [:]
    private var onStateUpdate: (@Sendable (State, StateSource) -> Void)?
    private var onIdentity: (@Sendable (String, String) -> Void)?
    private var onUnhandledMessage: (@Sendable (String) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?
    private var onConnectionStateChange: (@Sendable (AgentConnectionState) -> Void)?
    private var onMcpServers: (@Sendable ([McpServerInfo]) -> Void)?
    private var onChatMessages: (@Sendable ([[String: Any]]) -> Void)?
    private var onChatResponse: (@Sendable (ChatResponse) -> Void)?
    private var onChatClear: (@Sendable () -> Void)?
    private var onSession: (@Sendable ([String: Any]) -> Void)?
    private var onSessionError: (@Sendable (String) -> Void)?
    private var receiveTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var previousName: String?
    private var previousAgent: String?

    /// Auto-reconnect configuration
    public private(set) var autoReconnectEnabled: Bool = false
    private var autoReconnectMaxDelay: TimeInterval = 30.0
    private var reconnectAttempt: Int = 0
    private var reconnectTask: Task<Void, Never>?

    /// URL path construction matching JS AgentClient
    /// Standard: /agents/{agent-name}/{instance-name}
    /// BasePath: /{basePath}
    public struct Options: Sendable {
        public let agent: String
        public let name: String
        public let host: String
        public let basePath: String?
        public let path: String?
        public let query: [String: String]?
        public let headers: [String: String]?

        public init(
            agent: String,
            name: String = "default",
            host: String,
            basePath: String? = nil,
            path: String? = nil,
            query: [String: String]? = nil,
            headers: [String: String]? = nil
        ) {
            self.agent = agent
            self.name = name
            self.host = host
            self.basePath = basePath
            self.path = path
            self.query = query
            self.headers = headers
        }
    }

    private let headers: [String: String]

    public init(options: Options) {
        self.agentName = Self.camelCaseToKebabCase(options.agent)
        self.instanceName = options.name
        self.headers = options.headers ?? [:]

        var urlString: String
        if let basePath = options.basePath {
            urlString = "\(options.host)/\(basePath)"
        } else {
            urlString = "\(options.host)/agents/\(self.agentName)/\(options.name)"
        }
        if let path = options.path {
            urlString += "/\(path)"
        }

        // Convert http(s) to ws(s) for WebSocket
        urlString = urlString
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")

        var components = URLComponents(string: urlString)!
        if let query = options.query {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }

        self.baseURL = components.url!
        self.session = URLSession(configuration: .default)
    }

    // MARK: - Lifecycle

    public func connect() {
        guard webSocketTask == nil else { return }
        connectionState = .connecting
        onConnectionStateChange?(.connecting)

        let task = session.webSocketTask(with: makeWebSocketRequest())
        webSocketTask = task
        task.resume()

        connectionState = .connected
        onConnectionStateChange?(.connected)

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    public func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        identified = false
        connectionState = .disconnected
        onConnectionStateChange?(.disconnected)

        // Reject pending calls
        for (_, continuation) in pendingCalls {
            continuation.resume(throwing: AgentError.connectionClosed)
        }
        pendingCalls.removeAll()
        pendingStreamChunks.removeAll()
    }

    /// Wait until identity is received from server
    public func waitForReady() async {
        if identified { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            readyContinuation = cont
        }
    }

    // MARK: - State

    public func setState(_ newState: State) throws {
        let message = StateMessage(type: .state, state: newState)
        let data = try JSONEncoder().encode(message)
        guard let json = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(json)) { _ in }
        self.state = newState
        onStateUpdate?(newState, .client)
    }

    // MARK: - RPC

    /// Call a method on the server agent
    public func call(_ method: String, args: [AnyCodable] = []) async throws -> AnyCodable? {
        let request = RPCRequest(method: method, args: args)
        let data = try JSONEncoder().encode(request)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AgentError.encodingFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingCalls[request.id] = continuation
            webSocketTask?.send(.string(json)) { [weak self] error in
                if let error {
                    Task { await self?.rejectCall(id: request.id, error: error) }
                }
            }
        }
    }

    /// Convenience: call with timeout
    public func call(_ method: String, args: [AnyCodable] = [], timeout: TimeInterval) async throws -> AnyCodable? {
        try await withThrowingTaskGroup(of: AnyCodable?.self) { group in
            group.addTask { try await self.call(method, args: args) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw AgentError.timeout(method: method, seconds: timeout)
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Callbacks

    public func onStateUpdate(_ handler: @escaping @Sendable (State, StateSource) -> Void) {
        self.onStateUpdate = handler
    }

    public func onIdentity(_ handler: @escaping @Sendable (String, String) -> Void) {
        self.onIdentity = handler
    }

    public func onError(_ handler: @escaping @Sendable (Error) -> Void) {
        self.onError = handler
    }

    public func onUnhandledMessage(_ handler: @escaping @Sendable (String) -> Void) {
        self.onUnhandledMessage = handler
    }

    public func onConnectionStateChange(_ handler: @escaping @Sendable (AgentConnectionState) -> Void) {
        self.onConnectionStateChange = handler
    }

    public func onMcpServers(_ handler: @escaping @Sendable ([McpServerInfo]) -> Void) {
        self.onMcpServers = handler
    }

    /// Called when server broadcasts the chat message list (AIChatAgent protocol)
    public func onChatMessages(_ handler: @escaping @Sendable ([[String: Any]]) -> Void) {
        self.onChatMessages = handler
    }

    /// Called for each streaming chat response chunk from server
    public func onChatResponse(_ handler: @escaping @Sendable (ChatResponse) -> Void) {
        self.onChatResponse = handler
    }

    /// Called when server clears the chat history
    public func onChatClear(_ handler: @escaping @Sendable () -> Void) {
        self.onChatClear = handler
    }

    /// Called when server sends a session message
    public func onSession(_ handler: @escaping @Sendable ([String: Any]) -> Void) {
        self.onSession = handler
    }

    /// Called when server sends a session error
    public func onSessionError(_ handler: @escaping @Sendable (String) -> Void) {
        self.onSessionError = handler
    }

    // MARK: - Chat (AIChatAgent protocol)

    /// Send a chat request to an AIChatAgent
    public func sendChatRequest(body: String, id: String = UUID().uuidString.lowercased()) throws {
        let request = ChatRequest(id: id, body: body)
        let data = try JSONEncoder().encode(request)
        guard let json = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(json)) { _ in }
    }

    /// Send a chat clear command
    public func clearChat() throws {
        let msg: [String: String] = ["type": MessageType.chatClear.rawValue]
        let data = try JSONSerialization.data(withJSONObject: msg)
        guard let json = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(json)) { _ in }
    }

    /// Enable/disable automatic reconnection with exponential backoff.
    /// - Parameters:
    ///   - enabled: Whether to auto-reconnect on unexpected disconnection.
    ///   - maxDelay: Maximum backoff delay in seconds (default 30s).
    public func setAutoReconnect(_ enabled: Bool, maxDelay: TimeInterval = 30.0) {
        self.autoReconnectEnabled = enabled
        self.autoReconnectMaxDelay = maxDelay
        if !enabled {
            reconnectTask?.cancel()
            reconnectTask = nil
        }
    }

    // MARK: - Internal

    private func receiveLoop() async {
        guard let ws = webSocketTask else { return }

        while !Task.isCancelled {
            do {
                let message = try await ws.receive()
                switch message {
                case .string(let text):
                    handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                webSocketTask = nil
                receiveTask = nil
                identified = false
                connectionState = .disconnected
                onConnectionStateChange?(.disconnected)
                if !Task.isCancelled {
                    onError?(error)
                    if autoReconnectEnabled {
                        scheduleReconnect()
                    }
                }
                break
            }
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let attempt = reconnectAttempt
        let maxDelay = autoReconnectMaxDelay
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            // Exponential backoff with jitter, capped at maxDelay
            let baseDelay = min(pow(2.0, Double(attempt)) * 0.1, maxDelay)
            let jitter = Double.random(in: 0...baseDelay * 0.1)
            let delay = baseDelay + jitter
            let ns = UInt64(delay * 1_000_000_000)
            try? await Task.sleep(nanoseconds: ns)
            guard !Task.isCancelled else { return }
            await self?.reconnect()
        }
    }

    private func reconnect() {
        guard autoReconnectEnabled, webSocketTask == nil else { return }
        connectionState = .connecting
        onConnectionStateChange?(.connecting)

        let task = session.webSocketTask(with: makeWebSocketRequest())
        webSocketTask = task
        task.resume()

        connectionState = .connected
        onConnectionStateChange?(.connected)

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let typeString = json["type"] as? String
        else { return }

        switch typeString {
        case MessageType.identity.rawValue:
            let name = json["name"] as? String ?? instanceName
            let agent = json["agent"] as? String ?? agentName
            identified = true
            connectionState = .identified(name: name, agent: agent)
            onIdentity?(name, agent)
            onConnectionStateChange?(.identified(name: name, agent: agent))
            readyContinuation?.resume()
            readyContinuation = nil
            previousName = name
            previousAgent = agent

        case MessageType.state.rawValue:
            if let stateValue = json["state"],
               let stateData = try? JSONSerialization.data(withJSONObject: stateValue),
               let decoded = try? JSONDecoder().decode(State.self, from: stateData)
            {
                state = decoded
                onStateUpdate?(decoded, .server)
            }

        case MessageType.stateError.rawValue:
            if let errorMsg = json["error"] as? String {
                onError?(AgentError.rpcFailed(errorMsg))
            }

        case MessageType.mcpServers.rawValue:
            if let servers = json["servers"] as? [[String: Any]] {
                let infos = servers.map { s in
                    McpServerInfo(name: s["name"] as? String ?? "", url: s["url"] as? String)
                }
                onMcpServers?(infos)
            }

        case MessageType.rpc.rawValue:
            handleRPCResponse(json)

        case MessageType.chatMessages.rawValue:
            if let messages = json["messages"] as? [[String: Any]] {
                onChatMessages?(messages)
            }

        case MessageType.chatResponse.rawValue:
            if let responseData = try? JSONSerialization.data(withJSONObject: json),
               let response = try? JSONDecoder().decode(ChatResponse.self, from: responseData) {
                onChatResponse?(response)
            }

        case MessageType.chatClear.rawValue:
            onChatClear?()

        case MessageType.session.rawValue:
            onSession?(json)

        case MessageType.sessionError.rawValue:
            if let errorMsg = json["error"] as? String {
                onSessionError?(errorMsg)
            }

        default:
            onUnhandledMessage?(text)
        }
    }

    private func handleRPCResponse(_ json: [String: Any]) {
        guard let id = json["id"] as? String else { return }

        let success = json["success"] as? Bool ?? false
        let done = json["done"] as? Bool  // nil means non-streaming (resolve immediately)

        // For streaming responses: keep the continuation alive while done == false
        if done == false {
            // Intermediate chunk — deliver to onStreamChunk if registered, keep pending
            if let resultValue = json["result"],
               let handler = pendingStreamChunks[id] {
                let decoded = AnyCodable.fromJSONObject(resultValue)
                handler(decoded)
            }
            return
        }

        // done == true or done == nil (non-streaming): resolve the continuation
        guard let continuation = pendingCalls.removeValue(forKey: id) else { return }
        pendingStreamChunks.removeValue(forKey: id)

        if !success {
            let error = json["error"] as? String ?? "Unknown RPC error"
            continuation.resume(throwing: AgentError.rpcFailed(error))
            return
        }

        if let resultValue = json["result"] {
            let decoded = AnyCodable.fromJSONObject(resultValue)
            continuation.resume(returning: decoded)
        } else {
            continuation.resume(returning: nil)
        }
    }

    private func rejectCall(id: String, error: Error) {
        if let continuation = pendingCalls.removeValue(forKey: id) {
            continuation.resume(throwing: error)
        }
    }

    private static func camelCaseToKebabCase(_ input: String) -> String {
        var result = ""
        for (i, char) in input.enumerated() {
            if char.isUppercase {
                if i > 0 { result += "-" }
                result += char.lowercased()
            } else {
                result += String(char)
            }
        }
        return result
    }

    func makeWebSocketRequest() -> URLRequest {
        var request = URLRequest(url: baseURL)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }
}

// MARK: - Errors

public enum AgentError: LocalizedError, Sendable {
    case connectionClosed
    case encodingFailed
    case rpcFailed(String)
    case timeout(method: String, seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .connectionClosed: return "Connection closed"
        case .encodingFailed: return "Failed to encode message"
        case .rpcFailed(let msg): return "RPC failed: \(msg)"
        case .timeout(let method, let seconds): return "RPC call to \(method) timed out after \(seconds)s"
        }
    }
}
