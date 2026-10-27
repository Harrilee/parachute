#!/bin/bash
set -euo pipefail
APP_PATH="${1:?Usage: sign-app.sh application.app}"
: "${APPLE_SIGN_ID:?Developer ID Application signing identity is required}"
: "${KEYCHAIN_PATH:?Dedicated signing keychain is required}"
FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"
VERSION_DIR="$FRAMEWORK/Versions/B"
[ -d "$VERSION_DIR" ] || { echo 'Sparkle framework is missing.' >&2; exit 1; }
sign_code() {
    codesign --force --sign "$APPLE_SIGN_ID" --keychain "$KEYCHAIN_PATH" \
        --options runtime --timestamp "$@"
}
# Sparkle's documented manual signing order. Do not use --deep for signing.
# Downloader's distribution-provided entitlements, when present, must survive.
sign_code "$VERSION_DIR/XPCServices/Installer.xpc"
sign_code --preserve-metadata=entitlements "$VERSION_DIR/XPCServices/Downloader.xpc"
sign_code "$VERSION_DIR/Autoupdate"
sign_code "$VERSION_DIR/Updater.app"
sign_code "$FRAMEWORK"
sign_code "$APP_PATH/Contents/Resources/ios"
SHIPIT="$APP_PATH/Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt"
[ -x "$SHIPIT" ] || { echo 'Electron migration relaunch helper is missing.' >&2; exit 1; }
sign_code "$SHIPIT"
sign_code "$APP_PATH/Contents/Frameworks/Squirrel.framework"
# Swift and go-ios do not require Electron's JIT/library-validation exceptions.
sign_code "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
