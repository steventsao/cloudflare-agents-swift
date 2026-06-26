import Foundation

/// Connection state
public enum AgentConnectionState: Equatable, Sendable {
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

public enum StateSource: Equatable, Sendable {
    case server
    case client
}

public struct AgentConnectionCloseEvent: Equatable, Sendable {
    public let code: Int
    public let reason: String
    public let wasClean: Bool

    public init(code: Int, reason: String = "", wasClean: Bool = false) {
        self.code = code
        self.reason = reason
        self.wasClean = wasClean
    }
}

public struct AgentConnectionError: LocalizedError, Equatable, Sendable {
    public let name = "AgentConnectionError"
    public let code: Int
    public let reason: String
    public let wasClean: Bool

    public init(code: Int, reason: String = "", wasClean: Bool = false) {
        self.code = code
        self.reason = reason
        self.wasClean = wasClean
    }

    public var errorDescription: String? {
        let detail = reason.isEmpty ? "WebSocket closed with code \(code)" : reason
        return "Agent connection closed: \(detail)"
    }
}

public func isTerminalCloseCode(_ code: Int) -> Bool {
    code == 1008 || (4000...4999).contains(code)
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
    public private(set) var connectionError: AgentConnectionError?

    // Upstream TS only reports cf_agent_state_error. Keep the latest server
    // snapshot so Swift observers can recover from rejected optimistic state.
    private var lastServerState: State?
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession
    private var pendingCalls: [String: CheckedContinuation<AnyCodable?, Error>] = [:]
    private var pendingStreamChunks: [String: (AnyCodable?) -> Void] = [:]
    private var pendingTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var onStateUpdate: (@Sendable (State, StateSource) -> Void)?
    private var onStateError: (@Sendable (String) -> Void)?
    private var onIdentity: (@Sendable (String, String) -> Void)?
    private var onIdentityChange: (@Sendable (String, String, String, String) -> Void)?
    private var onUnhandledMessage: (@Sendable (String) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?
    private var onConnectionStateChange: (@Sendable (AgentConnectionState) -> Void)?
    private var onMcpServers: (@Sendable ([McpServerInfo]) -> Void)?
    private var onChatMessages: (@Sendable ([[String: Any]]) -> Void)?
    private var onChatResponse: (@Sendable (ChatResponse) -> Void)?
    private var onChatClear: (@Sendable () -> Void)?
    private var onSession: (@Sendable ([String: Any]) -> Void)?
    private var onSessionError: (@Sendable (String) -> Void)?
    private var onConnectionError: (@Sendable (AgentConnectionError) -> Void)?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatInterval: TimeInterval = 12
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var previousName: String?
    private var previousAgent: String?
    private let defaultCallTimeout: TimeInterval
    private let shouldReconnectOnClose: (@Sendable (AgentConnectionCloseEvent) -> Bool)?

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
        public let defaultCallTimeout: TimeInterval
        public let shouldReconnectOnClose: (@Sendable (AgentConnectionCloseEvent) -> Bool)?

        public init(
            agent: String,
            name: String = "default",
            host: String,
            basePath: String? = nil,
            path: String? = nil,
            query: [String: String]? = nil,
            headers: [String: String]? = nil,
            defaultCallTimeout: TimeInterval = 30.0,
            shouldReconnectOnClose: (@Sendable (AgentConnectionCloseEvent) -> Bool)? = nil
        ) {
            self.agent = agent
            self.name = name
            self.host = host
            self.basePath = basePath
            self.path = path
            self.query = query
            self.headers = headers
            self.defaultCallTimeout = defaultCallTimeout
            self.shouldReconnectOnClose = shouldReconnectOnClose
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
        self.defaultCallTimeout = options.defaultCallTimeout
        self.shouldReconnectOnClose = options.shouldReconnectOnClose
    }

    deinit {
        // Release the URLSession (and its delegate queue/threads) once the client
        // is gone. URLSession retains itself until invalidated, so without this a
        // long-lived process that creates many short-lived clients — or a test
        // suite spinning up one client per case — leaks sessions and their threads.
        session.invalidateAndCancel()
    }

    // MARK: - Lifecycle

    public func connect() {
        guard webSocketTask == nil else { return }
        openConnection()
    }

    /// Re-verify the connection after the app returns to foreground. iOS sleep/wake
    /// leaves a half-open socket that `receive()` won't necessarily error on, so the
    /// client can keep "looking" connected while sends silently fail and moves derived
    /// from stale state get rejected. Pings the socket and force-reconnects (→ fresh
    /// `cf_agent_state` resync) if it's dead; reconnects outright if already closed.
    public func resume() {
        guard let ws = webSocketTask else {
            forceReconnect()
            return
        }
        ws.sendPing { [weak self] error in
            if error != nil { Task { await self?.forceReconnect() } }
        }
    }

    private func openConnection() {
        connectionError = nil
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
        startHeartbeat()
    }

    /// Tear down the current socket and immediately open a fresh one (no backoff).
    private func forceReconnect() {
        heartbeatTask?.cancel(); heartbeatTask = nil
        receiveTask?.cancel(); receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        identified = false
        reconnectAttempt = 0
        openConnection()
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let interval = heartbeatInterval
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.pingOnce()
            }
        }
    }

    private func pingOnce() {
        guard let ws = webSocketTask else { return }
        ws.sendPing { [weak self] error in
            if let error { Task { await self?.handleSocketFailure(error) } }
        }
    }

    /// A dead socket surfaced via a failed ping or send. Tear down and reconnect.
    private func handleSocketFailure(_ error: Error) {
        guard webSocketTask != nil else { return }
        heartbeatTask?.cancel(); heartbeatTask = nil
        receiveTask?.cancel(); receiveTask = nil
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil
        identified = false
        connectionState = .disconnected
        onConnectionStateChange?(.disconnected)
        onError?(error)
        if autoReconnectEnabled { scheduleReconnect() }
    }

    public func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        pendingTimeoutTasks.values.forEach { $0.cancel() }
        pendingTimeoutTasks.removeAll()
        heartbeatTask?.cancel()
        heartbeatTask = nil
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
        guard let ws = webSocketTask else { throw AgentError.connectionClosed }
        let message = StateMessage(type: .state, state: newState)
        let data = try JSONEncoder().encode(message)
        guard let json = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(json)) { [weak self] error in
            if let error { Task { await self?.handleSocketFailure(error) } }
        }
        self.state = newState
        onStateUpdate?(newState, .client)
    }

    // MARK: - RPC

    /// Call a method on the server agent
    public func call(_ method: String, args: [AnyCodable] = []) async throws -> AnyCodable? {
        guard webSocketTask != nil else { throw AgentError.connectionClosed }
        let request = RPCRequest(method: method, args: args)
        let data = try JSONEncoder().encode(request)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AgentError.encodingFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingCalls[request.id] = continuation

            let timeout = defaultCallTimeout
            if timeout > 0 {
                let timeoutTask = Task { [weak self] in
                    let nanoseconds = UInt64(timeout * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled else { return }
                    await self?.timeoutCall(id: request.id, method: method, seconds: timeout)
                }
                pendingTimeoutTasks[request.id] = timeoutTask
            }

            webSocketTask?.send(.string(json)) { [weak self] error in
                if let error {
                    Task { await self?.rejectCall(id: request.id, error: error) }
                }
            }
        }
    }

    /// Convenience: call with timeout
    public func call(_ method: String, args: [AnyCodable] = [], timeout: TimeInterval) async throws -> AnyCodable? {
        guard webSocketTask != nil else { throw AgentError.connectionClosed }
        let request = RPCRequest(method: method, args: args)
        let data = try JSONEncoder().encode(request)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AgentError.encodingFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingCalls[request.id] = continuation

            if timeout > 0 {
                let timeoutTask = Task { [weak self] in
                    let nanoseconds = UInt64(timeout * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled else { return }
                    await self?.timeoutCall(id: request.id, method: method, seconds: timeout)
                }
                pendingTimeoutTasks[request.id] = timeoutTask
            }

            webSocketTask?.send(.string(json)) { [weak self] error in
                if let error {
                    Task { await self?.rejectCall(id: request.id, error: error) }
                }
            }
        }
    }

    /// Call a *streaming* method on the server agent.
    ///
    /// Mirrors the JS client's `call(method, args, { stream: { onChunk, onDone, onError } })`:
    /// every intermediate RPC response (`done: false`) is delivered to `onChunk`,
    /// the final response (`done: true`, or a non-streaming response with no
    /// `done` field) resolves this call with its result (the JS `onDone`), and a
    /// failure throws (the JS `onError`). An optional `timeout` rejects the call
    /// if no terminal response arrives in time.
    public func call(
        _ method: String,
        args: [AnyCodable] = [],
        timeout: TimeInterval? = nil,
        onChunk: @escaping @Sendable (AnyCodable?) -> Void
    ) async throws -> AnyCodable? {
        guard webSocketTask != nil else { throw AgentError.connectionClosed }
        let request = RPCRequest(method: method, args: args)
        let data = try JSONEncoder().encode(request)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AgentError.encodingFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingCalls[request.id] = continuation
            pendingStreamChunks[request.id] = onChunk

            if let timeout, timeout > 0 {
                let timeoutTask = Task { [weak self] in
                    let nanoseconds = UInt64(timeout * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled else { return }
                    await self?.timeoutCall(id: request.id, method: method, seconds: timeout)
                }
                pendingTimeoutTasks[request.id] = timeoutTask
            }

            webSocketTask?.send(.string(json)) { [weak self] error in
                if let error {
                    Task { await self?.rejectCall(id: request.id, error: error) }
                }
            }
        }
    }

    // MARK: - Callbacks

    public func onStateUpdate(_ handler: @escaping @Sendable (State, StateSource) -> Void) {
        self.onStateUpdate = handler
    }

    public func onIdentity(_ handler: @escaping @Sendable (String, String) -> Void) {
        self.onIdentity = handler
    }

    /// Called when the server reports a *different* identity on reconnect — the
    /// instance name and/or the agent class changed. Mirrors the JS client's
    /// `onIdentityChange(oldName, newName, oldAgent, newAgent)`. This happens
    /// with server-side routing (e.g. `basePath` + `getAgentByName`) where the
    /// instance is resolved from auth/session rather than the client-supplied name.
    public func onIdentityChange(_ handler: @escaping @Sendable (String, String, String, String) -> Void) {
        self.onIdentityChange = handler
    }

    /// Called when a state update is rejected by the server (e.g. the connection
    /// is readonly). Mirrors the JS client's `onStateUpdateError`. The latest
    /// server snapshot is also re-broadcast via `onStateUpdate(_, .server)` so
    /// observers can reconcile rejected optimistic state.
    public func onStateError(_ handler: @escaping @Sendable (String) -> Void) {
        self.onStateError = handler
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

    public func onConnectionError(_ handler: @escaping @Sendable (AgentConnectionError) -> Void) {
        self.onConnectionError = handler
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
                if !Task.isCancelled {
                    handleSocketClose(error, task: ws)
                }
                break
            }
        }
    }

    private func handleSocketClose(_ error: Error, task: URLSessionWebSocketTask) {
        let closeEvent = Self.closeEvent(from: task)
        let terminalClose = closeEvent.map { isTerminalCloseCode($0.code) } ?? false
        let shouldReconnect = closeEvent.map { shouldReconnectOnClose?($0) ?? true } ?? true
        let terminalError = closeEvent.map {
            AgentConnectionError(code: $0.code, reason: $0.reason, wasClean: $0.wasClean)
        }

        heartbeatTask?.cancel()
        heartbeatTask = nil
        webSocketTask = nil
        receiveTask = nil
        identified = false
        connectionState = .disconnected
        onConnectionStateChange?(.disconnected)

        pendingTimeoutTasks.values.forEach { $0.cancel() }
        pendingTimeoutTasks.removeAll()
        pendingStreamChunks.removeAll()
        for (_, continuation) in pendingCalls {
            continuation.resume(throwing: terminalError ?? AgentError.connectionClosed)
        }
        pendingCalls.removeAll()

        if terminalClose, let terminalError {
            connectionError = terminalError
            onConnectionError?(terminalError)
            onError?(terminalError)
            return
        }

        onError?(error)
        if autoReconnectEnabled && shouldReconnect {
            scheduleReconnect()
        }
    }

    private static func closeEvent(from task: URLSessionWebSocketTask) -> AgentConnectionCloseEvent? {
        let code = Int(task.closeCode.rawValue)
        guard code > 0 else { return nil }
        let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return AgentConnectionCloseEvent(
            code: code,
            reason: reason,
            wasClean: task.closeCode == .normalClosure
        )
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
        openConnection()
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

            // Detect identity change on reconnect (mirrors JS AgentClient): if we
            // already had an identity and the server now reports a different
            // instance/agent, notify before adopting the new (authoritative) values.
            if let oldName = previousName, let oldAgent = previousAgent,
               oldName != name || oldAgent != agent {
                onIdentityChange?(oldName, name, oldAgent, agent)
            }

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
                lastServerState = decoded
                onStateUpdate?(decoded, .server)
            }

        case MessageType.stateError.rawValue:
            if let errorMsg = json["error"] as? String {
                if let lastServerState {
                    state = lastServerState
                    onStateUpdate?(lastServerState, .server)
                }
                onStateError?(errorMsg)
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
        pendingTimeoutTasks.removeValue(forKey: id)?.cancel()
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
            pendingTimeoutTasks.removeValue(forKey: id)?.cancel()
            pendingStreamChunks.removeValue(forKey: id)
            continuation.resume(throwing: error)
        }
    }

    private func timeoutCall(id: String, method: String, seconds: TimeInterval) {
        guard let continuation = pendingCalls.removeValue(forKey: id) else { return }
        pendingTimeoutTasks.removeValue(forKey: id)?.cancel()
        pendingStreamChunks.removeValue(forKey: id)
        continuation.resume(throwing: AgentError.timeout(method: method, seconds: seconds))
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
