# cloudflare-agents-swift

Swift client for the [Cloudflare Agents SDK](https://github.com/cloudflare/agents).

Mirrors the TypeScript `AgentClient` — connects to a Cloudflare Durable Object agent over WebSocket and handles the full wire protocol: identity handshake, state synchronization, RPC calls (including streaming), and auto-reconnect with exponential backoff.

**Compatibility:** tracks [`cloudflare/agents`](https://github.com/cloudflare/agents) **v0.8.5**. The package version mirrors the upstream `agents` release it targets, so pin the client to the same version as the agent running on your Worker.

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

Create one store per agent instance, matching the TypeScript `useAgent` pattern
where each hook instance owns its own socket, identity, state, and errors:

```swift
struct DashboardView: View {
    @StateObject private var left = AgentStateStore<PanelState>(options: .init(
        agent: "PanelAgent",
        name: "left-room",
        host: "https://my-worker.example.com"
    ))
    @StateObject private var right = AgentStateStore<PanelState>(options: .init(
        agent: "PanelAgent",
        name: "right-room",
        host: "https://my-worker.example.com"
    ))

    var body: some View {
        HStack {
            Text(left.state?.title ?? "Left")
            Text(right.state?.title ?? "Right")
        }
        .task {
            await left.connect()
            await right.connect()
        }
    }
}
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
- Multiple `AgentStateStore` instances in one view/model, each with independent socket, identity, state, and errors

## Scope

This package is a Swift port of Cloudflare's TypeScript Agents client, not a
BYOT app SDK. Additions should map to one of:

- A Cloudflare Agents wire-protocol message.
- A TypeScript `AgentClient` or `useAgent` behavior.
- A compatibility test against the Cloudflare Agents server contract.

Keep app workflows, model routing, UI state, and product-specific naming in the
app layer. Use BYOT requirements only as concrete compatibility cases that
exercise the generic client.

## State rejection reconciliation

The upstream TypeScript client treats `setState()` as an optimistic local update
and reports `cf_agent_state_error` through `onStateUpdateError`; that protocol
message currently carries only an error string, not a mutation id or replacement
state. This Swift client keeps the same wire format and optimistic callback
behavior, then reconciles rejected optimistic state by restoring the latest
server-delivered `cf_agent_state` when one is available.

Assumptions behind that behavior:

- The server is authoritative for durable agent state.
- `cf_agent_state_error` rejects at least one pending optimistic client state.
- Because errors are not correlated to a specific `setState`, rollback is
  conservative: any rejection restores the latest server snapshot. Apps that
  need stronger ordering should wait for a server broadcast before sending
  dependent state mutations.

## Protocol Compatibility

Wire format matches the [cloudflare/agents](https://github.com/cloudflare/agents) TypeScript SDK:

| Message Type | Direction | Description |
|---|---|---|
| `cf_agent_identity` | server -> client | Agent name + instance on connect |
| `cf_agent_state` | bidirectional | State sync |
| `cf_agent_state_error` | server -> client | Rejected state mutation |
| `cf_agent_mcp_servers` | server -> client | MCP server list |
| `rpc` | bidirectional | Remote procedure calls (incl. streaming chunks) |
| `cf_agent_use_chat_request` | client -> server | Chat turn, body wrapped in `init` (see below) |
| `cf_agent_use_chat_response` | server -> client | Streaming chat response chunk |
| `cf_agent_chat_messages` | server -> client | Full chat message list broadcast |
| `cf_agent_chat_clear` | bidirectional | Clear chat history |

## Interop note: your `State` must emit explicit `null`

The JS Agent strict-compares state fields server-side (e.g. `state.winner !== expected.winner`).
Swift's default `JSONEncoder` **omits `nil` optionals** rather than encoding them as `null`
([SR-9232](https://github.com/apple/swift-corelibs-foundation/issues/3594)), so a `nil` field
arrives as `undefined`, fails the `!== null` check, and the agent replies `cf_agent_state_error`
("State update rejected").

This is a Swift↔JS Codable property, not something the client can fix generically — Foundation
has no global "encode nulls" flag. Emit explicit nulls at the model layer:

- **One/few optionals:** custom `encode(to:)` using `encodeNil(forKey:)`.
- **Many optionals:** a property wrapper such as [`@NullCodable`](https://github.com/g-mark/NullCodable).

```swift
// nil winner must serialize as `"winner": null`, not be dropped
public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if let winner { try c.encode(winner, forKey: .winner) } else { try c.encodeNil(forKey: .winner) }
    // ...other fields...
}
```

(Raw WS libraries like Starscream don't help — they only move bytes. Even `supabase-swift`
centralizes encoder *config* in a shared factory but still expresses null-emission per model.)

## Interop note: chat requests are wrapped in `init`

The `cf_agent_use_chat_request` frame carries the encoded request payload under an
`init` key shaped like a `RequestInit`, **not** at the top level. The server reads
`data.init.method === "POST"` and then `const { body } = data.init` (see the
cloudflare/agents `ws-chat-transport.ts` and `AIChatAgent` message handler), so the
wire frame must be:

```json
{ "type": "cf_agent_use_chat_request", "id": "…", "init": { "method": "POST", "body": "<json>" } }
```

`sendChatRequest(body:)` produces exactly this frame. A top-level `body` would be
ignored by an upstream `AIChatAgent`. The chat *response* (`cf_agent_use_chat_response`)
keeps `body` at the top level — that asymmetry matches the upstream protocol.

## Client callbacks mirrored from the TypeScript client

- `onStateUpdate(state, source)` — server broadcasts and optimistic client `setState`.
- `onStateError(message)` — rejected state mutation (JS `onStateUpdateError`); the last
  server snapshot is also re-broadcast so observers can reconcile.
- `onIdentity(name, agent)` — identity handshake on every (re)connect.
- `onIdentityChange(oldName, newName, oldAgent, newAgent)` — fires when the server reports
  a *different* instance/agent on reconnect (e.g. `basePath` + `getAgentByName` routing).
- Streaming RPC: `call(method, args:, timeout:, onChunk:)` delivers intermediate
  `done: false` chunks to `onChunk` and resolves with the terminal result (JS `stream.onChunk` + `onDone`).

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
