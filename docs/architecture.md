# Architecture

KV Studio is layered so that everything below the UI can be tested without a screen, and most of it
without a server.

```
KVStudio/
├── App/            the shell: routing, sidebar, termination
├── Core/
│   ├── RESP/       the wire format: encoder, incremental decoder, value model
│   ├── Networking/ KVConnection, a serialized actor over NWConnection
│   ├── Client/     KVClient, typed commands over a connection
│   ├── Server/     owning a local kv-server process, and probing any server
│   ├── Storage/    Application Support paths and persisted preferences
│   ├── Connection/ ConnectionCoordinator, what the UI binds to
│   ├── Backend/    release lookup, verified staging, activation and rollback
│   ├── Updates/    Sparkle integration and the coordinated update machine
│   ├── Errors/     the user-facing error taxonomy
│   └── Utilities/  version parsing, value presentation, pasteboard, hex
└── Features/       one folder per screen
```

## The wire

`RESPEncoder` writes commands; `RESPDecoder` reads replies incrementally. The decoder is the part
most worth knowing about:

- It never advances its cursor on an incomplete reply. Every parse helper works on a local cursor
  that is committed only on success, at any nesting depth, so a reply split across ten packets
  parses identically to one that arrives whole.
- Bulk bodies are taken by their declared byte count, with the terminator verified at a computed
  offset rather than searched for, so a value containing `CRLF` cannot corrupt the stream.
- Nothing on the read path becomes a `String`.

## One command at a time, two lanes

`KVConnection` is an actor that keeps at most one command in flight, using an explicit FIFO slot
rather than relying on actor reentrancy — a second send can otherwise interleave at any suspension
point inside the first one's write-then-read.

Because a connection is serialized, the Browser and the Console get **separate** connections. A long
`SCAN` traversal would otherwise sit in front of every console command.

## Owning a process

`ManagedServerController` runs exactly one `kv-server`.

- **Identity, not just a PID.** It records the process's kernel start time alongside its PID, so a
  recycled PID can never be mistaken for its own server — and it never signals a process whose
  identity it cannot confirm.
- **Adoption.** If Studio crashes, the next launch recognises its own orphaned server and takes it
  back rather than spawning a second one onto the same append-only file.
- **An intent record.** The record is written *before* the spawn, so a crash in the gap still leaves
  a route back to whatever started.
- **Bounded probes.** `KVConnection` has no timeout by design, so readiness and compatibility checks
  run under an explicit budget that tears the connection down when it expires.
- **Drained output.** An undrained pipe fills its kernel buffer and blocks the child; both streams
  are drained continuously and appended to the log file.
- **An exit watcher.** The state stops claiming `running` when the child dies on its own.

## Compatibility

There is no `VERSION` command, so compatibility is decided by capability: `PING`, then `DBSIZE`,
then `SCAN 0 COUNT 1`. Failures are classified by the server's documented error *class prefix*, never
by exact wording. A go-kv-store 1.0.x answers `PING` and then rejects `DBSIZE` — that is the exact
signature the 1.1.0 floor is enforced by.

A consequence worth stating: a server that answers all three may connect even if it is not
go-kv-store. That is the compatibility model the product chose, not an oversight.

## What the UI binds to

`ConnectionCoordinator` is `@MainActor` and observable; the I/O stays in the actors that own it. It
publishes two axes — the connection `phase` and the `managedServer` status — and holds the two
`KVClient` lanes. Connecting to an existing server means connect, then probe, then accept: a server
that fails the probe never becomes the active connection.

While connected it pings the Browser lane every five seconds. Commands report a dead peer when they
hit one, but nothing issues a command while the app sits idle, so without the ping a server that had
gone would keep being drawn as connected until the user happened to ask it something. The ping
starts where the connected phase is published and is cancelled with the lanes, so it can never
outlive the connection it describes and turn a deliberate disconnect into a failure.
