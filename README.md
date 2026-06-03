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

For SwiftUI or Combine-style binding, use `AgentStateStore` as a main-actor adapter around the protocol client:

```swift
@MainActor
let store = AgentStateStore<MyState>(options: .init(
    agent: "ChatAgent",
    name: "my-room",
    host: "https://my-worker.example.com"
))

await store.connect()
try await store.setState(MyState(count: 42))
let result = try await store.call("incrementCount", args: [])
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
- Main-actor `AgentStateStore` adapter with `@Published` state, identity, connection, and error properties

## Protocol Compatibility

Wire format matches the [cloudflare/agents](https://github.com/cloudflare/agents) TypeScript SDK:

| Message Type | Direction | Description |
|---|---|---|
| `cf_agent_identity` | server -> client | Agent name + instance on connect |
| `cf_agent_state` | bidirectional | State sync |
| `cf_agent_state_error` | server -> client | Rejected state mutation |
| `cf_agent_mcp_servers` | server -> client | MCP server list |
| `rpc` | bidirectional | Remote procedure calls |

## Application Integration TODO

Keep this package generic. For app-level realtime workflow UI, add integration in the app layer:

- Treat HTTP workflow status as the durable source of truth.
- Use WebSocket subscription only while the app is active for realtime progress.
- Rehydrate from the HTTP status snapshot on connect and reconnect.
- Scope socket access with an app-issued workflow capability, signed token, or unguessable workflow/session identifier before exposing private workflow state. A full user login is not required, but the socket should not rely on guessable room names alone.

## Tests

Tests cover connection lifecycle, state round-trips, RPC with mixed types, streaming, reconnection, malformed message resilience, and no-protocol mode.

```sh
swift test
```

To run compatibility checks against the upstream `cloudflare/agents` Worker test harness:

```sh
./scripts/test-upstream-compat.mjs
```

By default the script expects an upstream `cloudflare/agents` checkout next to this repo at `../agents`. Override with `CF_AGENTS_REPO=/path/to/agents` if needed.
