# Privacy and security

## What leaves your machine

Two things, both only when you ask for them:

- **Backend release metadata** — a request to `api.github.com` for the latest `go-kv-store` release,
  and then the archive and `SHA256SUMS` from `github.com`.
- **The app update feed** — a request to the appcast URL configured in the app bundle.

That is all. KV Studio has no analytics, no telemetry, and no crash reporting. Your keys, values,
commands, and server addresses are never transmitted anywhere.

Automatic update checking can be turned off in Settings. With it off, KV Studio makes no network
request you did not initiate.

## What is stored, and where

Everything lives under `~/Library/Application Support/KV Studio/`:

```
backend/{current,previous,staging}/   the managed kv-server and its metadata
data/appendonly.aof                   the managed server's data
logs/kv-server.log                    the managed server's output
state/preferences.json                appearance, reopen, update checking
state/connections.json                the last connection target
state/managed-server.json             which process KV Studio started
```

There is no custom data directory in v0.1, and no credentials are stored: v0.1 has no
authentication. Nothing is written to the keychain.

## Trusting a downloaded backend

- The archive's SHA-256 is checked against the release's published `SHA256SUMS` **before** the
  archive is opened, and nothing is executed before it is verified.
- Only the one expected `kv-server` member is extracted. Path traversal, absolute paths, links, and
  unexpected archive layouts are refused rather than sanitised.
- A backend that starts but fails its compatibility probe is rolled back.

## Trusting a downloaded app

Updates come through Sparkle with an EdDSA-signed appcast, over HTTPS only — a feed URL that is not
`https` is ignored. The DMG is signed with a Developer ID and notarized. Automatic checking and
automatic download are both off; installation always requires you to choose it.

## Processes KV Studio runs

It runs one `kv-server`, from `KV_SERVER_BINARY` if set, otherwise `backend/current/kv-server`,
otherwise a binary inside the app bundle.

It will not signal a process it cannot prove it started. Ownership is a PID **plus** that process's
kernel start time, so a recycled PID cannot be mistaken for KV Studio's own server. If something
else holds the port, KV Studio reports it and offers to connect — it never kills it.

## Local connections

Connections are plain TCP to the host and port you give, with no TLS in v0.1. The managed server
binds `127.0.0.1` by default and is not reachable from the network. Point KV Studio at a remote
server only over a network you trust, or through a tunnel you control.
