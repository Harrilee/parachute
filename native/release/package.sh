#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="${1:?Usage: package.sh application.app output-directory}"
OUTPUT_DIR="${2:?Output directory is required}"
: "${RELEASE_VERSION:?Release version is required}"
: "${BUILD_NUMBER:?Monotonically increasing build number is required}"
: "${RELEASE_ARCH:?arm64 or x86_64 is required}"
: "${BUNDLE_ID:?Verified existing application identity is required}"
: "${APPLE_INSTALLER_SIGN_ID:?Developer ID Installer identity is required}"
: "${KEYCHAIN_PATH:?Dedicated signing keychain is required}"
: "${NOTARY_PROFILE:?Stored notarytool keychain profile is required}"
case "$RELEASE_ARCH" in arm64) ASSET_ARCH=arm64;; x86_64) ASSET_ARCH=x64;; *) exit 1;; esac
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
[ "$(basename "$APP_PATH")" = Parachute.app ] || { echo 'Bundle must be named Parachute.app.' >&2; exit 1; }
PLIST="$APP_PATH/Contents/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
[ "$(read_plist CFBundleIdentifier)" = "$BUNDLE_ID" ]
[ "$(read_plist CFBundleShortVersionString)" = "$RELEASE_VERSION" ]
[ "$(read_plist CFBundleVersion)" = "$BUILD_NUMBER" ]
[ "$(read_plist LSMinimumSystemVersion)" = 14.0 ]
[ -n "$(read_plist SUPublicEDKey)" ]
[ "$(read_plist SUVerifyUpdateBeforeExtraction)" = true ]
[ "$(read_plist SURequireSignedFeed)" = true ]
case "$(read_plist SUFeedURL)" in https://*) ;; *) echo 'Sparkle feed must use HTTPS.' >&2; exit 1;; esac
/usr/bin/lipo "$APP_PATH/Contents/MacOS/Parachute" -verify_arch "$RELEASE_ARCH"
/usr/bin/lipo "$APP_PATH/Contents/Resources/ios" -verify_arch "$RELEASE_ARCH"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/parachute-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
xattr -cr "$APP_PATH"
bash "$SCRIPT_DIR/sign-app.sh" "$APP_PATH"
notarize() {
    local input="$1" label="$2" result="$OUTPUT_DIR/$2-notarization.json"
    local submission_exit=0
    xcrun notarytool submit "$input" --keychain "$KEYCHAIN_PATH" \
        --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m --output-format json > "$result" || submission_exit=$?
    local submission status
    submission="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$result")"
    status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$result")"
    xcrun notarytool log "$submission" --keychain "$KEYCHAIN_PATH" --keychain-profile "$NOTARY_PROFILE" \
        "$OUTPUT_DIR/$label-notarization-log.json"
    [ "$submission_exit" = 0 ] && [ "$status" = Accepted ] || { echo "Notarization failed: $status" >&2; exit 1; }
}
# Notarize the app payload, staple it, then create the final ZIP. ZIP itself
# cannot hold a stapled ticket. Both Squirrel and Sparkle receive the same app.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$STAGING_DIR/app-for-notary.zip"
notarize "$STAGING_DIR/app-for-notary.zip" app
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
STEM="Parachute-native-$ASSET_ARCH-$RELEASE_VERSION"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_DIR/$STEM.zip"
python3 - "$STAGING_DIR/requirements.plist" "$RELEASE_ARCH" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump({'os': ['14.0'], 'arch': [sys.argv[2]], 'home': False}, file)
PY
productbuild --component "$APP_PATH" /Applications --product "$STAGING_DIR/requirements.plist" \
    --identifier "$BUNDLE_ID.installer" --version "$RELEASE_VERSION" \
    --sign "$APPLE_INSTALLER_SIGN_ID" --keychain "$KEYCHAIN_PATH" "$OUTPUT_DIR/$STEM.pkg"
notarize "$OUTPUT_DIR/$STEM.pkg" pkg
xcrun stapler staple "$OUTPUT_DIR/$STEM.pkg"
xcrun stapler validate "$OUTPUT_DIR/$STEM.pkg"
pkgutil --check-signature "$OUTPUT_DIR/$STEM.pkg"
spctl --assess --type install --verbose=2 "$OUTPUT_DIR/$STEM.pkg"
cp "$APP_PATH/Contents/Resources/ios-build-info.txt" "$OUTPUT_DIR/$STEM-go-ios-build-info.txt"
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$STEM.zip" "$STEM.pkg" > "$STEM-SHA256SUMS.txt"
)
python3 - "$OUTPUT_DIR" "$STEM" "$APP_PATH" <<'PY'
import hashlib, json, os, pathlib, plistlib, subprocess, sys
output, stem, app = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
with (app / 'Contents/Info.plist').open('rb') as file: info = plistlib.load(file)
manifest = {
    'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'workflowRun': os.environ.get('GITHUB_RUN_ID'),
    'bundleIdentifier': info['CFBundleIdentifier'],
    'version': info['CFBundleShortVersionString'],
    'build': info['CFBundleVersion'],
    'minimumMacOS': info['LSMinimumSystemVersion'],
    'architecture': os.environ['RELEASE_ARCH'],
    'applicationSigningIdentity': os.environ['APPLE_SIGN_ID'],
    'installerSigningIdentity': os.environ['APPLE_INSTALLER_SIGN_ID'],
    'artifacts': {},
}
for extension in ('zip', 'pkg'):
    path = output / (stem + '.' + extension)
    with path.open('rb') as file: digest = hashlib.file_digest(file, 'sha256').hexdigest()
    manifest['artifacts'][path.name] = {'sha256': digest, 'bytes': path.stat().st_size}
(output / (stem + '-manifest.json')).write_text(json.dumps(manifest, indent=2) + '\n')
PY
echo "Signed, notarized and stapled artifacts: $OUTPUT_DIR/$STEM.{zip,pkg}"
