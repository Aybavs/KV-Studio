# Troubleshooting

## "Port 6380 is already in use"

Something else holds the port. KV Studio will not take it: it offers to connect to whatever is there
instead. Find the owner with:

```bash
lsof -nP -iTCP:6380 -sTCP:LISTEN
```

Either stop that process yourself, connect to it from the Existing card, or change the port in
Settings.

## "A server KV Studio started earlier is still holding port …"

A previous run left its server behind and KV Studio can no longer prove which process is its own, so
it refuses to guess. Stop it yourself, or connect to it.

## The local server will not start

Check the **Logs** screen first — the server's own output says more than the error does. Common
causes: no backend installed (run `./scripts/install-dev-backend.sh`, or install one from Settings),
or the append-only file's directory is not writable.

## "KV Studio could not use its Application Support folder"

The app opens on an explanation instead of its normal window. Check that
`~/Library/Application Support` exists and is writable. KV Studio deliberately does not fall back to
a temporary directory, because data written there would be silently purgeable.

## Keys disappear while browsing

Expected, and not a bug. `SCAN` snapshots key *names* when the traversal starts; values are not
snapshotted. A key that expires or is deleted mid-traversal can still be listed and will then be
missing when opened. Refresh restarts the traversal.

## Search feels like it restarts

It does. Changing the search pattern cancels the current traversal and starts again from cursor 0,
because the server fixes `MATCH` when the scan session is created.

## Updates

- **Checksum failure** — nothing was installed; the archive did not match its published hash. Try
  again later.
- **"the previous one was restored"** — the new backend did not work and KV Studio rolled back. You
  can keep working.
- **No update button** — no appcast feed is configured in this build, so the updater never starts.

## Running the test suites

```bash
# unit tests
xcodebuild test -project KVStudio.xcodeproj -scheme KVStudio -configuration Debug \
  -only-testing:KVStudioTests

# integration and end-to-end tests need a real server
./scripts/build-test-backend.sh
```

Two traps worth knowing:

- **Do not pass `CODE_SIGNING_ALLOWED=NO` to the UI tests.** It skips the re-sign of the
  `lipo`-rewritten XCTest runner, producing a runner macOS treats as damaged; it is SIGKILLed at
  launch and the damaged bundle then breaks the next link with `Operation not permitted`. Recover by
  deleting `KVStudioUITests-Runner.app` from DerivedData. The flag is correct for build and unit
  tests.
- **UI tests need automation permission for whichever app launches them.** macOS grants automation
  to the *responsible process*, so running `xcodebuild` from a terminal requires that terminal to be
  allowed under Privacy & Security. If the runner starts but sees no windows, that is the cause.

If a run is interrupted, check for leftovers before trusting the next one:

```bash
pgrep -fl kv-server; pgrep -fl kv-fixtures
```
