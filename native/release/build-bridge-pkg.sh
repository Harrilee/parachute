#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="${1:?Usage: build-bridge-pkg.sh signed-bridge.app output.pkg}"
OUTPUT_PKG="${2:?Output package is required}"
: "${ASSET_ARCH:?arm64 or x64 is required}"
: "${APPLE_INSTALLER_SIGN_ID:?Developer ID Installer identity is required}"
: "${KEYCHAIN_PATH:?Dedicated signing keychain is required}"
case "$ASSET_ARCH" in
    arm64) MACH_ARCH=arm64 ;;
    x64) MACH_ARCH=x86_64 ;;
    *) echo 'Unsupported bridge architecture' >&2; exit 1 ;;
esac
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
PLIST="$APP_PATH/Contents/Info.plist"
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST"; }
[ "$(read_plist CFBundleIdentifier)" = com.electron.parachute ]
[ "$(read_plist CFBundleShortVersionString)" = 0.3.9 ]
[ "$(read_plist CFBundleVersion)" = 0.3.9 ]
MINIMUM_OS="$(read_plist LSMinimumSystemVersion)"
EXECUTABLE="$(read_plist CFBundleExecutable)"
/usr/bin/lipo "$APP_PATH/Contents/MacOS/$EXECUTABLE" -verify_arch "$MACH_ARCH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
mkdir -p "$(dirname "$OUTPUT_PKG")"
OUTPUT_PKG="$(cd "$(dirname "$OUTPUT_PKG")" && pwd)/$(basename "$OUTPUT_PKG")"
[ ! -e "$OUTPUT_PKG" ] || { echo 'Refusing to overwrite an existing package' >&2; exit 1; }
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/parachute-bridge-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
python3 - "$STAGING_DIR/requirements.plist" "$MINIMUM_OS" "$MACH_ARCH" <<'PY'
import plistlib, re, sys
if not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', sys.argv[2]):
    raise SystemExit('Bridge has an invalid minimum macOS version')
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({'os': [sys.argv[2]], 'arch': [sys.argv[3]], 'home': False}, output)
PY
echo "Building signed bridge installer ($ASSET_ARCH, macOS $MINIMUM_OS+)"
python3 "$SCRIPT_DIR/run-bounded.py" --timeout 120 --log "$OUTPUT_PKG-component.log" -- \
    bash "$SCRIPT_DIR/build-component.sh" "$APP_PATH" "$STAGING_DIR/payload.pkg" com.electron.parachute 0.3.9
python3 "$SCRIPT_DIR/run-bounded.py" --timeout 600 --log "$OUTPUT_PKG-build.log" -- \
    /usr/bin/productbuild --package "$STAGING_DIR/payload.pkg" \
    --product "$STAGING_DIR/requirements.plist" \
    --identifier com.electron.parachute.installer --version 0.3.9 \
    --sign "$APPLE_INSTALLER_SIGN_ID" --keychain "$KEYCHAIN_PATH" "$OUTPUT_PKG"
/usr/sbin/pkgutil --check-signature "$OUTPUT_PKG"
echo "Built bridge installer: $OUTPUT_PKG"
