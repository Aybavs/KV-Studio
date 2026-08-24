#!/usr/bin/env bash
set -euo pipefail

# Xcode signs the UI-test runner from its own template, which sandboxes it with network.client
# only. A runner that cannot bind cannot start the servers five scenarios need, and the servers it
# spawns inherit the refusal and exit. Re-signing it to match the unsandboxed app it drives is the
# only step here that is not a plain xcodebuild invocation; setting CODE_SIGN_ENTITLEMENTS on the
# test target does not reach the generated runner.

cd "$(dirname "$0")/.."

PROJECT=KVStudio.xcodeproj
SCHEME=KVStudio
CONFIGURATION="${CONFIGURATION:-Debug}"
ENTITLEMENTS=Config/KVStudioUITests.entitlements

xcodebuild build-for-testing -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION"

products=$(xcodebuild -showBuildSettings -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" 2>/dev/null |
    awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{ print $2; exit }')
runner="$products/KVStudioUITests-Runner.app"
[ -d "$runner" ] || { echo "error: no runner built at $runner" >&2; exit 1; }

codesign --force --sign - --entitlements "$ENTITLEMENTS" "$runner"
codesign --verify --verbose=1 "$runner"

xcodebuild test-without-building -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" \
    -only-testing:KVStudioUITests "$@"
