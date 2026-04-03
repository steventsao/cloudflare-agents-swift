# cloudflare-agents-swift

Swift client for the [Cloudflare Agents SDK](https://github.com/cloudflare/agents).

Mirrors the TypeScript `AgentClient` — connects to a Cloudflare Durable Object agent over WebSocket and handles the full wire protocol: identity handshake, state synchronization, RPC calls (including streaming), and auto-reconnect with exponential backoff.

## Usage

```swift
import CloudflareAgents

let client = AgentClient<MyState>(options: .init(
    agent: "ChatAgent",
    name: "my-room",
    host: "https://my-worker.example.com"
))

await client.onStateUpdate { state, source in
    print("State updated (\(source)): \(state)")
}

await client.connect()
await client.waitForReady()

// RPC
let result = try await client.call("incrementCount", args: [])

// State sync
try await client.setState(MyState(count: 42))

await client.disconnect()
```

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/steventsao/cloudflare-agents-swift.git", branch: "main")
]
```

## Features

- WebSocket connection with `ws://` / `wss://` auto-detection
- Identity handshake (`cf_agent_identity`)
- Bidirectional state sync (`cf_agent_state`) with optimistic local updates
- RPC calls with async/await, streaming (`done: false/true`), and timeouts
- Auto-reconnect with exponential backoff + jitter
- No-protocol mode (`?protocol=false`) and readonly mode (`?readonly=true`)
- Custom headers and query parameters
- `basePath` routing for non-standard agent URLs
- Swift concurrency (`actor`-based, `Sendable`-safe)

## Protocol Compatibility

Wire format matches the [cloudflare/agents](https://github.com/cloudflare/agents) TypeScript SDK:

| Message Type | Direction | Description |
|---|---|---|
| `cf_agent_identity` | server -> client | Agent name + instance on connect |
| `cf_agent_state` | bidirectional | State sync |
| `cf_agent_state_error` | server -> client | Rejected state mutation |
| `cf_agent_mcp_servers` | server -> client | MCP server list |
| `rpc` | bidirectional | Remote procedure calls |

## Tests

62 tests covering connection lifecycle, state round-trips, RPC with mixed types, streaming, reconnection, malformed message resilience, and no-protocol mode.

```sh
swift test
```
