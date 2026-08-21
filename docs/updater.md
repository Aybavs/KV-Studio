# Updater and rollback

Nothing installs itself. Every update is something you asked for.

## The order, and why it is that order

When both the app and the backend have updates, the backend is staged **first**:

1. Look up the latest `go-kv-store` release and pick the archive for this machine's architecture.
2. Download the archive and the release's `SHA256SUMS`.
3. Compute SHA-256 and compare. **A mismatch stops here and installs nothing.**
4. Inspect the archive's entries and extract only the expected `kv-server`.
5. Stage it under `backend/staging/` with its version and hash.
6. Let Sparkle stage the new app, then relaunch.
7. The **new** app activates the staged backend and probes it.

The backend goes first because after the relaunch it is the new app that must be able to run it. A
staged backend simply waits on disk across the restart.

## Verification comes before extraction

The archive is never handed to `tar` until its checksum matches. Layout is then validated before a
single member is extracted, and the following are refused outright:

- any absolute path,
- any path containing a `..` component,
- anything that is not a regular file or a directory (links, devices),
- more than one top-level directory,
- an archive whose `kv-server` is not a regular file.

Only `<release-directory>/kv-server` is extracted. Nothing downloaded is executed before it has been
verified.

## Activation is a rename, so it can be undone

Activation stops the server first, then:

```
backend/previous   <- backend/current     (rename)
backend/current    <- backend/staging     (rename)
backend/staging    <- recreated empty
```

Each step is a rename within Application Support, so each is atomic on its volume and each can be
undone by renaming back. The server is then started and probed.

## When it goes wrong

| What happens | What KV Studio does |
|---|---|
| Checksum does not match | Installs nothing; `backend/staging` is left empty |
| Archive layout is unexpected | Installs nothing, naming the entry it refused |
| New backend will not start | Restores `previous`, restarts it, reports why |
| New backend fails its compatibility probe | Same: restores, restarts, reports the outcome |
| Previous cannot be restored | Reported distinctly — this is the one case needing your attention |

A rollback is reported as a rollback, not as a generic failure, so the message can say your previous
backend is back rather than implying data loss.

## Signing

The app update feed is a Sparkle appcast verified by EdDSA signature, and the DMG is signed and
notarized. Automatic checking and automatic download are both disabled explicitly, and without a
configured feed no updater is created at all.
