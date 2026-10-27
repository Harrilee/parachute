#!/bin/bash
set -euo pipefail
NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
NATIVE_SDK_PATH="${NATIVE_SDK_PATH:-$(xcrun --show-sdk-path)}"
mkdir -p "$NATIVE_DIR/build"
TEST_ROOT="$(mktemp -d "$NATIVE_DIR/build/input-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT
echo 'Running isolated native input tests (requires a macOS GUI session).'
xcrun swiftc -sdk "$NATIVE_SDK_PATH" -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    "$NATIVE_DIR/Parachute/Localization.swift" \
    "$NATIVE_DIR/Parachute/MapSearchService.swift" \
    "$NATIVE_DIR/Parachute/MapSearchView.swift" \
    "$NATIVE_DIR/Parachute/GlassPanel.swift" \
    "$NATIVE_DIR/Tests/MapSearchInputTests.swift" -o "$TEST_ROOT/search-input-tests"
"$TEST_ROOT/search-input-tests"
