#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
  echo "Apple Command Line Tools are required. Run: xcode-select --install" >&2
  exit 1
fi

DEVELOPER_PATH="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
TEST_FLAGS=(--disable-xctest)
if [[ "$DEVELOPER_PATH" == */CommandLineTools ]]; then
  FRAMEWORK_PATH="$DEVELOPER_PATH/Library/Developer/Frameworks"
  PLUGIN_PATH="$DEVELOPER_PATH/usr/lib/swift/host/plugins/testing"
  if [[ ! -d "$FRAMEWORK_PATH/Testing.framework" || ! -d "$PLUGIN_PATH" ]]; then
    echo "Swift Testing requires recent Apple Command Line Tools or Xcode with Swift 6 or newer." >&2
    exit 1
  fi
  # CLT does not ship XCTest. The native build system also avoids
  # incremental TestingMacros discovery failures in the swiftbuild backend.
  TEST_FLAGS+=(
    --build-system native
    -Xswiftc -F -Xswiftc "$FRAMEWORK_PATH"
    -Xswiftc -plugin-path -Xswiftc "$PLUGIN_PATH"
    -Xlinker -rpath -Xlinker "$FRAMEWORK_PATH"
  )
fi

exec /usr/bin/xcrun swift test "${TEST_FLAGS[@]}" "$@"
