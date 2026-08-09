# KV Studio

A native macOS client and control plane for [`go-kv-store`](https://github.com/Aybavs/go-kv-store).

KV Studio talks to the server over its RESP2 wire protocol directly from Swift,
without a Redis client dependency. It manages one local `kv-server` instance,
connects to existing servers, and browses binary-safe keys and values.

Requires macOS 14 or later and `go-kv-store` 1.1.0 or later.
