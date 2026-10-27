#!/bin/bash
set -euo pipefail
MAKE_DIR="${1:?Usage: finish-bridge.sh staged-out-make artifact-directory}"
OUTPUT_DIR="${2:?Artifact directory is required}"
: "${ASSET_ARCH:?arm64 or x64 is required}"
: "${APPLE_TEAM_ID:?Expected signing team is required}"
: "${KEYCHAIN_PATH:?Dedicated signing keychain is required}"
: "${NOTARY_PROFILE:?Stored notarytool profile is required}"
case "$ASSET_ARCH" in arm64) MACH_ARCH=arm64;; x64) MACH_ARCH=x86_64;; *) exit 1;; esac
mkdir -p "$OUTPUT_DIR"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/parachute-bridge-verify.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
python3 - "$MAKE_DIR" "$OUTPUT_DIR" "$ASSET_ARCH" <<'PY'
import pathlib, shutil, sys
source, output, arch = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
for extension, name in [('zip', f'Parachute-darwin-{arch}-0.3.9.zip'), ('pkg', f'Parachute-0.3.9-{arch}.pkg')]:
    paths = list(source.rglob('*.' + extension))
    if len(paths) != 1:
        raise SystemExit('Expected exactly one bridge .' + extension + ' artifact')
    shutil.copy2(paths[0], output / name)
PY
ZIP="$OUTPUT_DIR/Parachute-darwin-$ASSET_ARCH-0.3.9.zip"
PKG="$OUTPUT_DIR/Parachute-0.3.9-$ASSET_ARCH.pkg"
ditto -x -k "$ZIP" "$STAGING_DIR"
APP_PATH="$STAGING_DIR/Parachute.app"
codesign --verify --deep --strict "$APP_PATH"
codesign --verify --test-requirement "anchor apple generic and certificate leaf[subject.OU] = \"$APPLE_TEAM_ID\" and identifier \"com.electron.parachute\"" "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
/usr/bin/lipo -verify_arch "$MACH_ARCH" "$APP_PATH/Contents/MacOS/Parachute"
/usr/bin/lipo -verify_arch "$MACH_ARCH" "$APP_PATH/Contents/Resources/ios"
python3 - "$APP_PATH/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as file: info = plistlib.load(file)
assert info['CFBundleIdentifier'] == 'com.electron.parachute'
assert info['CFBundleShortVersionString'] == '0.3.9'
assert int(info.get('LSMinimumSystemVersion', '10.15').split('.')[0]) < 14
PY
SUBMIT_EXIT=0
xcrun notarytool submit "$PKG" --keychain "$KEYCHAIN_PATH" --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout 30m --output-format json > "$OUTPUT_DIR/bridge-pkg-notarization.json" || SUBMIT_EXIT=$?
SUBMISSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$OUTPUT_DIR/bridge-pkg-notarization.json")"
STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$OUTPUT_DIR/bridge-pkg-notarization.json")"
xcrun notarytool log "$SUBMISSION" --keychain "$KEYCHAIN_PATH" --keychain-profile "$NOTARY_PROFILE" "$OUTPUT_DIR/bridge-pkg-notarization-log.json"
[ "$SUBMIT_EXIT" = 0 ] && [ "$STATUS" = Accepted ] || { echo "Bridge notarization failed: $STATUS" >&2; exit 1; }
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"
pkgutil --check-signature "$PKG"
spctl --assess --type install --verbose=2 "$PKG"
if [ "${CI_INSTALL_TEST:-0}" = 1 ]; then
    [ "${GITHUB_ACTIONS:-}" = true ] || { echo 'Install test requires GitHub Actions.' >&2; exit 1; }
    sudo installer -pkg "$PKG" -target /
    cmp "$APP_PATH/Contents/Info.plist" /Applications/Parachute.app/Contents/Info.plist
    codesign --verify --deep --strict /Applications/Parachute.app
    spctl --assess --type execute --verbose=2 /Applications/Parachute.app
fi
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "Parachute-darwin-$ASSET_ARCH-0.3.9.zip" "Parachute-0.3.9-$ASSET_ARCH.pkg" > "bridge-$ASSET_ARCH-SHA256SUMS.txt"
)
echo 'Bridge ZIP and notarized PKG validation passed.'
