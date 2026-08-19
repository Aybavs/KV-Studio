#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# git-common-dir collapses worktree nesting, so the default resolves correctly from any worktree.
MAIN_REPO_ROOT="$(cd "$(git rev-parse --git-common-dir)/.." && pwd)"
DEFAULT_SRC="$MAIN_REPO_ROOT/../go-kv-store"

GO_KV_STORE_SRC="${GO_KV_STORE_SRC:-$DEFAULT_SRC}"
DEST="$REPO_ROOT/.build/kv-server"

if [ ! -d "$GO_KV_STORE_SRC" ]; then
    echo "error: go-kv-store source not found at $GO_KV_STORE_SRC" >&2
    echo "set GO_KV_STORE_SRC to override" >&2
    exit 1
fi

mkdir -p "$REPO_ROOT/.build"
(cd "$GO_KV_STORE_SRC" && go build -o "$DEST" ./cmd/kv-server)

echo "built $DEST"
