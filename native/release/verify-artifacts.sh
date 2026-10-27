#!/bin/bash
set -euo pipefail
OUTPUT_DIR="${1:?Usage: verify-artifacts.sh artifact-directory}"
: "${RELEASE_ARCH:?Architecture is required}"
: "${RELEASE_VERSION:?Version is required}"
: "${BUILD_NUMBER:?Build number is required}"
: "${BUNDLE_ID:?Verified bundle ID is required}"
: "${APPLE_TEAM_ID:?Expected signing team is required}"
case "$RELEASE_ARCH" in arm64) ASSET_ARCH=arm64;; x86_64) ASSET_ARCH=x64;; *) exit 1;; esac
STEM="Parachute-native-$ASSET_ARCH-$RELEASE_VERSION"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/parachute-verify.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto -x -k "$OUTPUT_DIR/$STEM.zip" "$STAGING_DIR"
APP_PATH="$STAGING_DIR/Parachute.app"
codesign --verify --deep --strict "$APP_PATH"
codesign --verify --test-requirement "=anchor apple generic and certificate leaf[subject.OU] = \"$APPLE_TEAM_ID\" and identifier \"$BUNDLE_ID\"" "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
python3 - "$APP_PATH/Contents/Info.plist" "$BUNDLE_ID" "$RELEASE_VERSION" "$BUILD_NUMBER" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as file: info = plistlib.load(file)
assert [info[key] for key in ['CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion']] == sys.argv[2:]
assert info['LSMinimumSystemVersion'] == '14.0'
assert not any(key.startswith('NSLocation') for key in info), 'Current-location permission must not be requested'
PY
/usr/bin/lipo "$APP_PATH/Contents/MacOS/Parachute" -verify_arch "$RELEASE_ARCH"
/usr/bin/lipo "$APP_PATH/Contents/Resources/ios" -verify_arch "$RELEASE_ARCH"
pkgutil --check-signature "$OUTPUT_DIR/$STEM.pkg"
xcrun stapler validate "$OUTPUT_DIR/$STEM.pkg"
# Actual installer execution is limited to GitHub's disposable macOS runners.
# Do not launch the app here: installation/signing checks require no device.
if [ "${CI_INSTALL_TEST:-0}" = 1 ]; then
    [ "${GITHUB_ACTIONS:-}" = true ] || { echo 'Install test requires GitHub Actions.' >&2; exit 1; }
    sudo installer -pkg "$OUTPUT_DIR/$STEM.pkg" -target /
    cmp "$APP_PATH/Contents/Info.plist" /Applications/Parachute.app/Contents/Info.plist
    codesign --verify --deep --strict /Applications/Parachute.app
    spctl --assess --type execute --verbose=2 /Applications/Parachute.app
fi
echo 'ZIP contents and PKG validation passed.'
