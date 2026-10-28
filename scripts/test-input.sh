#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_SDK_PATH="${NATIVE_SDK_PATH:-$(xcrun --show-sdk-path)}"
mkdir -p "$ROOT_DIR/build"
TEST_ROOT="$(mktemp -d "$ROOT_DIR/build/input-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
echo 'Running isolated native input tests (requires a macOS GUI session).'
xcrun swiftc -sdk "$NATIVE_SDK_PATH" -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    "$ROOT_DIR/Sources/Parachute/Localization.swift" \
    "$ROOT_DIR/Sources/Parachute/MapSearchService.swift" \
    "$ROOT_DIR/Sources/Parachute/MapSearchView.swift" \
    "$ROOT_DIR/Sources/Parachute/GlassPanel.swift" \
    "$ROOT_DIR/Tests/ParachuteTests/MapSearchInputTests.swift" -o "$TEST_ROOT/search-input-tests"
"$TEST_ROOT/search-input-tests"
