#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_SDK_PATH="${NATIVE_SDK_PATH:-$(xcrun --show-sdk-path)}"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
xcrun swiftc -sdk "$NATIVE_SDK_PATH" -swift-version 5 "$ROOT_DIR/Sources/Parachute/Coordinates.swift" "$ROOT_DIR/Tests/ParachuteTests/CoordinatesTests.swift" -o "$TEST_ROOT/coordinates"
"$TEST_ROOT/coordinates"
xcrun swiftc -sdk "$NATIVE_SDK_PATH" -swift-version 5 "$ROOT_DIR/Sources/Parachute/DeviceService.swift" "$ROOT_DIR/Tests/ParachuteTests/DeviceServiceTests.swift" -o "$TEST_ROOT/devices"
"$TEST_ROOT/devices"
xcrun swiftc -sdk "$NATIVE_SDK_PATH" -swift-version 5 "$ROOT_DIR/Sources/Parachute/MapSearchService.swift" "$ROOT_DIR/Tests/ParachuteTests/MapSearchServiceTests.swift" -o "$TEST_ROOT/search"
"$TEST_ROOT/search"
TEST_APP="$TEST_ROOT/LocalizationTests.app"
mkdir -p "$TEST_APP/Contents/MacOS" "$TEST_APP/Contents/Resources"
cp "$ROOT_DIR/Resources/Info.plist" "$TEST_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleExecutable LocalizationTests' "$TEST_APP/Contents/Info.plist"
cp -R "$ROOT_DIR/Resources/". "$TEST_APP/Contents/Resources/"
xcrun swiftc -sdk "$NATIVE_SDK_PATH" -swift-version 5 "$ROOT_DIR/Sources/Parachute/Localization.swift" "$ROOT_DIR/Tests/ParachuteTests/LocalizationTests.swift" -o "$TEST_APP/Contents/MacOS/LocalizationTests"
for LOCALE in en zh-Hans zh-Hant zh-TW fr; do
    EXPECTED=en
    case "$LOCALE" in zh*) EXPECTED=zh;; esac
    "$TEST_APP/Contents/MacOS/LocalizationTests" -AppleLanguages "($LOCALE)" --expect-language "$EXPECTED"
done
UPDATER_ARGS=()
if [ "${NATIVE_TEST_SPARKLE:-0}" = 1 ]; then
    SPARKLE_ROOT="$(bash "$ROOT_DIR/scripts/updates/fetch-sparkle.sh")"
    UPDATER_ARGS=(-F "$SPARKLE_ROOT" -framework Sparkle -Xlinker -rpath -Xlinker "$SPARKLE_ROOT")
fi
xcrun swiftc -sdk "$NATIVE_SDK_PATH" -swift-version 5 ${UPDATER_ARGS[@]+"${UPDATER_ARGS[@]}"} \
    "$ROOT_DIR/Sources/Parachute/UpdaterService.swift" "$ROOT_DIR/Tests/ParachuteTests/UpdaterConfigurationTests.swift" -o "$TEST_ROOT/updater"
"$TEST_ROOT/updater"
xcrun swiftc -sdk "$NATIVE_SDK_PATH" -swift-version 5 -D LOCAL_PREVIEW \
    "$ROOT_DIR/Sources/Parachute/UpdaterService.swift" "$ROOT_DIR/Tests/ParachuteTests/UpdaterConfigurationTests.swift" -o "$TEST_ROOT/updater-preview"
"$TEST_ROOT/updater-preview"
if [ "${NATIVE_TEST_SPARKLE:-0}" = 1 ]; then
    python3 "$ROOT_DIR/Tests/ReleaseTests/AppcastTests.py"
fi
