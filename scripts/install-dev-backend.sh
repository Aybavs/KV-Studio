#!/usr/bin/env bash
set -euo pipefail

# git-common-dir collapses worktree nesting, so the default resolves correctly from any worktree.
MAIN_REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
DEFAULT_SRC="$MAIN_REPO_ROOT/../go-kv-store"

GO_KV_STORE_SRC="${GO_KV_STORE_SRC:-$DEFAULT_SRC}"
SUPPORT_DIR="${KV_STUDIO_SUPPORT_DIR:-$HOME/Library/Application Support/KV Studio}"
DEST_DIR="$SUPPORT_DIR/backend/current"
STAGING_DIR="$SUPPORT_DIR/backend/staging"

if [ ! -d "$GO_KV_STORE_SRC" ]; then
    echo "error: go-kv-store source not found at $GO_KV_STORE_SRC" >&2
    echo "set GO_KV_STORE_SRC to override" >&2
    exit 1
fi

mkdir -p "$DEST_DIR" "$STAGING_DIR"
# Building straight over the destination would fail with ETXTBSY while a managed server runs it.
VERSION="$(cd "$GO_KV_STORE_SRC" && git describe --tags --always --dirty 2>/dev/null || echo unknown)"
VERSION="${VERSION#v}"
(cd "$GO_KV_STORE_SRC" && go build -ldflags "-X main.version=$VERSION" -o "$STAGING_DIR/kv-server" ./cmd/kv-server)
mv -f "$STAGING_DIR/kv-server" "$DEST_DIR/kv-server"

# The app reads the installed version from here, the same file the real installer writes. Without
# it a working backend is reported as not installed at all.
SHA="$(shasum -a 256 "$DEST_DIR/kv-server" | cut -d' ' -f1)"
printf '{"version":"%s","sha256":"%s"}\n' "$VERSION" "$SHA" > "$DEST_DIR/metadata.json"

echo "installed $DEST_DIR/kv-server ($VERSION)"
