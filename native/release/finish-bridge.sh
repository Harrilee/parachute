#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAKE_DIR="${1:?Usage: finish-bridge.sh staged-out-make artifact-directory}"
OUTPUT_DIR="${2:?Artifact directory is required}"
PHASE="${3:-all}"
case "$PHASE" in all|prepare|build-pkg|notarize-pkg) ;; *) echo 'Unknown bridge packaging phase' >&2; exit 1;; esac
: "${ASSET_ARCH:?arm64 or x64 is required}"
: "${APPLE_TEAM_ID:?Expected signing team is required}"
: "${KEYCHAIN_PATH:?Dedicated signing keychain is required}"
: "${NOTARY_PROFILE:?Stored notarytool profile is required}"
case "$ASSET_ARCH" in arm64) MACH_ARCH=arm64;; x64) MACH_ARCH=x86_64;; *) exit 1;; esac
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP_PATH="$OUTPUT_DIR/.bridge-payload/Parachute.app"
ZIP="$OUTPUT_DIR/Parachute-darwin-$ASSET_ARCH-0.3.9.zip"
PKG="$OUTPUT_DIR/Parachute-0.3.9-$ASSET_ARCH.pkg"
echo "Bridge packaging phase: $PHASE"
if [ "$PHASE" = all ] || [ "$PHASE" = prepare ]; then
python3 - "$MAKE_DIR" "$OUTPUT_DIR" "$ASSET_ARCH" <<'PY'
import pathlib, shutil, sys
source, output, arch = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
for extension, name in [('zip', f'Parachute-darwin-{arch}-0.3.9.zip')]:
    paths = list(source.rglob('*.' + extension))
    if len(paths) != 1:
        raise SystemExit('Expected exactly one bridge .' + extension + ' artifact')
    shutil.copy2(paths[0], output / name)
PY
mkdir -p "$OUTPUT_DIR/.bridge-payload"
ditto -x -k "$ZIP" "$OUTPUT_DIR/.bridge-payload"
codesign --verify --deep --strict "$APP_PATH"
codesign --verify --test-requirement "=anchor apple generic and certificate leaf[subject.OU] = \"$APPLE_TEAM_ID\" and identifier \"com.electron.parachute\"" "$APP_PATH"
bash "$SCRIPT_DIR/notarize.sh" "$ZIP" "$OUTPUT_DIR/bridge-app-notarization"
python3 "$SCRIPT_DIR/stapler-retry.py" staple "$APP_PATH"
python3 "$SCRIPT_DIR/stapler-retry.py" validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
# Forge signs the staged app; shared release tooling handles notarization and
# bounded ticket-server retries. Rebuild the ZIP only after its app is stapled.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_DIR/.bridge-stapled.zip"
mv "$OUTPUT_DIR/.bridge-stapled.zip" "$ZIP"
/usr/bin/lipo "$APP_PATH/Contents/MacOS/Parachute" -verify_arch "$MACH_ARCH"
/usr/bin/lipo "$APP_PATH/Contents/Resources/ios" -verify_arch "$MACH_ARCH"
python3 - "$APP_PATH/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as file: info = plistlib.load(file)
assert info['CFBundleIdentifier'] == 'com.electron.parachute'
assert info['CFBundleShortVersionString'] == '0.3.9'
assert int(info.get('LSMinimumSystemVersion', '10.15').split('.')[0]) < 14
assert not any(key.startswith('NSLocation') for key in info), 'Bridge must not request current location'
PY
fi
if [ "$PHASE" = all ] || [ "$PHASE" = build-pkg ]; then
    bash "$SCRIPT_DIR/build-bridge-pkg.sh" "$APP_PATH" "$PKG"
fi
if [ "$PHASE" = all ] || [ "$PHASE" = notarize-pkg ]; then
bash "$SCRIPT_DIR/notarize.sh" "$PKG" "$OUTPUT_DIR/bridge-pkg-notarization"
python3 "$SCRIPT_DIR/stapler-retry.py" staple "$PKG"
python3 "$SCRIPT_DIR/stapler-retry.py" validate "$PKG"
pkgutil --check-signature "$PKG"
spctl --assess --type install --verbose=2 "$PKG"
if [ "${CI_INSTALL_TEST:-0}" = 1 ]; then
    [ "${GITHUB_ACTIONS:-}" = true ] || { echo 'Install test requires GitHub Actions.' >&2; exit 1; }
    sudo installer -verboseR -pkg "$PKG" -target / | tee "$OUTPUT_DIR/bridge-pkg-install.log"
    cmp "$APP_PATH/Contents/Info.plist" /Applications/Parachute.app/Contents/Info.plist
    codesign --verify --deep --strict /Applications/Parachute.app
    spctl --assess --type execute --verbose=2 /Applications/Parachute.app
fi
(
    cd "$OUTPUT_DIR"
    shasum -a 256 "Parachute-darwin-$ASSET_ARCH-0.3.9.zip" "Parachute-0.3.9-$ASSET_ARCH.pkg" > "bridge-$ASSET_ARCH-SHA256SUMS.txt"
)
fi
echo "Bridge packaging phase completed: $PHASE"
