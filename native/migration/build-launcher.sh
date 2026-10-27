#!/bin/bash
set -euo pipefail
MIGRATION_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="${1:?Usage: build-launcher.sh app-path arm64-or-x64}"
ASSET_ARCH="${2:?Missing architecture}"
case "$ASSET_ARCH" in
    arm64) CLANG_ARCH=arm64 ;;
    x64|x86_64) CLANG_ARCH=x86_64 ;;
    *) echo 'Unsupported architecture' >&2; exit 1 ;;
esac
test -f "$APP_PATH/Contents/Info.plist"
FRAMEWORK="$APP_PATH/Contents/Frameworks/Squirrel.framework"
if [ -e "$FRAMEWORK" ]; then
    echo 'Refusing to overwrite an existing Squirrel framework' >&2
    exit 1
fi
mkdir -p "$FRAMEWORK/Versions/A/Resources"
NATIVE_SDK_PATH="${NATIVE_SDK_PATH:-$(xcrun --show-sdk-path)}"
xcrun clang -isysroot "$NATIVE_SDK_PATH" -arch "$CLANG_ARCH" -mmacosx-version-min=10.15 \
    -fobjc-arc -O2 -framework AppKit -framework Foundation \
    "$MIGRATION_DIR/ShipItLauncher.m" -o "$FRAMEWORK/Versions/A/Squirrel"
cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.electron.parachute.migration-launcher</string>
<key>CFBundleName</key><string>Parachute Migration Launcher</string>
<key>CFBundleExecutable</key><string>Squirrel</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
</dict></plist>
PLIST
ln -s A "$FRAMEWORK/Versions/Current"
ln -s Versions/Current/Squirrel "$FRAMEWORK/Squirrel"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"
ln -s ../Squirrel "$FRAMEWORK/Versions/A/Resources/ShipIt"
echo "Built migration launcher: $FRAMEWORK/Versions/A/Resources/ShipIt"
