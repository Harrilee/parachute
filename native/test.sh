#!/bin/bash
set -euo pipefail
NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
NATIVE_SDK_PATH="${NATIVE_SDK_PATH:-$(xcrun --show-sdk-path)}"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
xcrun swiftc -sdk "$NATIVE_SDK_PATH" -swift-version 5 "$NATIVE_DIR/Parachute/Coordinates.swift" "$NATIVE_DIR/Tests/CoordinatesTests.swift" -o "$TEST_ROOT/coordinates"
"$TEST_ROOT/coordinates"
xcrun swiftc -sdk "$NATIVE_SDK_PATH" -swift-version 5 "$NATIVE_DIR/Parachute/DeviceService.swift" "$NATIVE_DIR/Tests/DeviceServiceTests.swift" -o "$TEST_ROOT/devices"
"$TEST_ROOT/devices"
xcrun swiftc -sdk "$NATIVE_SDK_PATH" -swift-version 5 "$NATIVE_DIR/Parachute/MapSearchService.swift" "$NATIVE_DIR/Tests/MapSearchServiceTests.swift" -o "$TEST_ROOT/search"
"$TEST_ROOT/search"
TEST_APP="$TEST_ROOT/LocalizationTests.app"
mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources"
cp "$NATIVE_DIR/Info.plist" "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleExecutable LocalizationTests' "$TEST_APP/Contents/Info.plist"
cp -R "$NATIVE_DIR/Resources/". "$TEST_APP/Contents/Resources/"
xcrun swiftc -sdk "$NATIVE_SDK_PATH" -swift-version 5 "$NATIVE_DIR/Parachute/Localization.swift" "$NATIVE_DIR/Tests/LocalizationTests.swift" -o "$TEST_APP/Contents/MacOS/LocalizationTests"
for LOCALE in en zh-Hans zh-Hant zh-TW fr; do
    EXPECTED=en
    case "$LOCALE" in zh*) EXPECTED=zh;; esac
    "$TEST_APP/Contents/MacOS/LocalizationTests" -AppleLanguages "($LOCALE)" --expect-language "$EXPECTED"
done
UPDATER_ARGS=()
if [ "${NATIVE_TEST_SPARKLE:-0}" = 1 ]; then
    SPARKLE_ROOT="$(bash "$NATIVE_DIR/updater/fetch-sparkle.sh")"
    UPDATER_ARGS=(-F "$SPARKLE_ROOT" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE_ROOT")
fi
xcrun swiftc -sdk "$NATIVE_SDK_PATH" -swift-version 5 "${UPDATER_ARGS[@]}" \
    "$NATIVE_DIR/Parachute/UpdaterService.swift" "$NATIVE_DIR/Tests/UpdaterConfigurationTests.swift" -o "$TEST_ROOT/updater"
"$TEST_ROOT/updater"
xcrun swiftc -sdk "$NATIVE_SDK_PATH" -swift-version 5 -D LOCAL_PREVIEW \
    "$NATIVE_DIR/Parachute/UpdaterService.swift" "$NATIVE_DIR/Tests/UpdaterConfigurationTests.swift" -o "$TEST_ROOT/updater-preview"
"$TEST_ROOT/updater-preview"
if [ "${NATIVE_TEST_SPARKLE:-0}" = 1 ]; then
    python3 "$NATIVE_DIR/Tests/AppcastTests.py"
fi
