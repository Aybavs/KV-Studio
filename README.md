# KV Studio

A native macOS client and control plane for [`go-kv-store`](https://github.com/Aybavs/go-kv-store).

KV Studio speaks the server's RESP2 wire protocol directly from Swift, with no Redis client
dependency. It can run and own a local `kv-server`, or connect to one you already have, and it
browses keys and values without ever assuming they are text.

> **Screenshot:** not yet captured. Add `docs/images/browser.png` and link it here before the first
> tagged release — a screenshot that does not match the shipped UI is worse than none.

Requires **macOS 14** or later and **go-kv-store 1.1.0** or later.

## What it does

- **Browser** — infinite scroll over `SCAN`, server-side `MATCH` search, and a value viewer that
  shows Text, formatted JSON, or a hex dump.
- **Console** — send commands directly and read the RESP reply, on its own connection so a long
  browse never blocks a command.
- **Server** — start, stop, and restart the local server; see its PID, endpoint, version,
  persistence mode, append-only file size, and paths. For a server you connected to rather than
  started, Disconnect closes the connection and leaves the process running.
- **Logs** — the managed server's live output, with search, pause, and a clear that empties the view
  and not the file on disk.
- **Settings** — appearance, whether to reopen the last connection, and update checking.

## Local server or an existing one

**Local.** KV Studio runs exactly one `kv-server` for you, on `127.0.0.1:6380` by default, with
`--appendonly` and `--appendfsync everysec`. It owns that process: it records the identity of what
it started, adopts its own server again after a crash, and stops it gracefully when you quit.

It will not take over a port it does not own. If something else is already on the port, KV Studio
says so and offers to connect to it instead — it never signals a process it cannot prove is its own.

**Existing.** Give a host and port and KV Studio probes the server before trusting it, with `PING`,
`DBSIZE`, and `SCAN 0 COUNT 1`. A server that fails the probe is reported, not connected to. Process
controls and log capture are hidden for a server KV Studio does not manage.

## Binary safety

Keys and values are `Data` end to end and are never forced through `String`.

- A value is shown as Text when it is valid UTF-8, as formatted JSON when it is valid JSON, and as a
  hex dump otherwise. You can override the choice.
- Keys can be created in Text or Hex.
- Copying a value copies the text when it is text, and hex when it is not, so no byte is lost to a
  replacement character.
- `NUL`, `CRLF`, and invalid UTF-8 all round-trip unchanged. There are tests that assert exactly
  that against a real server.

## Install

Download the notarized `.dmg` from the releases page and drag KV Studio to Applications.

To build from source you need Xcode 16 or later:

```bash
git clone <this repository>
cd kv-studio
xcodebuild build -project KVStudio.xcodeproj -scheme KVStudio -configuration Debug
```

For a development backend:

```bash
./scripts/build-test-backend.sh    # builds .build/kv-server for the test suites
./scripts/install-dev-backend.sh   # installs one where the app looks for it
```

## Updates

Nothing installs itself. KV Studio checks when you ask it to (and on launch, if you leave that on in
Settings), then shows one card describing what is available.

The app and the backend have independent versions, and a coordinated update handles both in the
order that keeps them compatible: the backend is downloaded and verified first, the app updates and
relaunches, and the new app activates the backend it inherited. Every backend archive is checked
against the release's published SHA-256 before anything is unpacked, and a backend that fails to
start or fails its compatibility probe is rolled back to the previous one automatically.

See [docs/updater.md](docs/updater.md) for the full flow and what happens when a step fails.

## Limitations in v0.1

- macOS only, and one managed local server at a time.
- No custom data directory: managed data lives in `~/Library/Application Support/KV Studio/`.
- No TLS or authentication UI, no cluster UI, no RESP3.
- No Pub/Sub, keyspace notifications, or persistence dashboard.
- Not a general Redis client. Compatibility is decided by capability — `PING`, `DBSIZE`, and
  `SCAN` — so other servers offering those may connect, but nothing else is supported.

## Documentation

- [Architecture](docs/architecture.md)
- [Updater and rollback](docs/updater.md)
- [Privacy and security](docs/security.md)
- [Troubleshooting](docs/troubleshooting.md)
