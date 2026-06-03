import Combine
import Foundation

public struct AgentIdentity: Equatable, Sendable {
    public let name: String
    public let agent: String

    public init(name: String, agent: String) {
        self.name = name
        self.agent = agent
    }
}

/// Main-actor adapter for SwiftUI/Combine-style state binding.
///
/// `AgentClient` owns the Cloudflare Agents wire protocol. This type mirrors
/// connection, identity, state, and error updates into `@Published` properties
/// that can be observed by SwiftUI, Combine, or adapted into TCA effects.
@MainActor
public final class AgentStateStore<State: Codable & Sendable>: ObservableObject {
    public let client: AgentClient<State>

    @Published public private(set) var state: State?
    @Published public private(set) var connectionState: AgentConnectionState = .disconnected
    @Published public private(set) var identity: AgentIdentity?
    @Published public private(set) var identified = false
    @Published public private(set) var lastStateSource: StateSource?
    @Published public private(set) var lastError: Error?
    @Published public private(set) var lastStateError: String?
    @Published public private(set) var mcpServers: [McpServerInfo] = []

    private var callbacksInstalled = false

    public init(client: AgentClient<State>) {
        self.client = client
    }

    public convenience init(options: AgentClient<State>.Options) {
        self.init(client: AgentClient<State>(options: options))
    }

    public func connect() async {
        await installCallbacksIfNeeded()
        await client.connect()
    }

    public func disconnect() async {
        await client.disconnect()
        connectionState = .disconnected
        identified = false
    }

    public func waitForReady() async {
        await client.waitForReady()
    }

    public func setAutoReconnect(_ enabled: Bool, maxDelay: TimeInterval = 30.0) async {
        await client.setAutoReconnect(enabled, maxDelay: maxDelay)
    }

    public func setState(_ newState: State) async throws {
        try await client.setState(newState)
        state = newState
        lastStateSource = .client
    }

    public func call(_ method: String, args: [AnyCodable] = []) async throws -> AnyCodable? {
        try await client.call(method, args: args)
    }

    public func call(_ method: String, args: [AnyCodable] = [], timeout: TimeInterval) async throws -> AnyCodable? {
        try await client.call(method, args: args, timeout: timeout)
    }

    public func clearError() {
        lastError = nil
        lastStateError = nil
    }

    private func installCallbacksIfNeeded() async {
        guard !callbacksInstalled else { return }
        callbacksInstalled = true

        await client.onConnectionStateChange { [weak self] newState in
            Task { @MainActor in
                self?.connectionState = newState
                if case .identified(let name, let agent) = newState {
                    self?.identity = AgentIdentity(name: name, agent: agent)
                    self?.identified = true
                } else if case .disconnected = newState {
                    self?.identified = false
                }
            }
        }

        await client.onIdentity { [weak self] name, agent in
            Task { @MainActor in
                self?.identity = AgentIdentity(name: name, agent: agent)
                self?.identified = true
            }
        }

        await client.onStateUpdate { [weak self] state, source in
            Task { @MainActor in
                self?.state = state
                self?.lastStateSource = source
                if source == .server {
                    self?.lastError = nil
                    self?.lastStateError = nil
                }
            }
        }

        await client.onError { [weak self] error in
            Task { @MainActor in
                self?.lastError = error
                if let agentError = error as? AgentError,
                   case .rpcFailed(let message) = agentError {
                    self?.lastStateError = message
                }
            }
        }

        await client.onMcpServers { [weak self] servers in
            Task { @MainActor in
                self?.mcpServers = servers
            }
        }
    }
}
