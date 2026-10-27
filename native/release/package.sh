#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Subshell functions isolate temporary paths and cleanup traps from other phases.
build_component() (
APP_PATH="${1:?Usage: package.sh component application.app output.pkg bundle-id version}"
OUTPUT="${2:?Output component package is required}"
BUNDLE_ID="${3:?Bundle identifier is required}"
VERSION="${4:?Version is required}"
[ "$(basename "$APP_PATH")" = Parachute.app ] || { echo 'Expected Parachute.app' >&2; exit 1; }
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
[ ! -e "$OUTPUT" ] || { echo 'Refusing to overwrite component package' >&2; exit 1; }
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/parachute-component.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir "$STAGING_DIR/root"
ditto "$APP_PATH" "$STAGING_DIR/root/Parachute.app"
pkgbuild --analyze --root "$STAGING_DIR/root" "$STAGING_DIR/components.plist"
python3 - "$STAGING_DIR/components.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as file: components = plistlib.load(file)
if not any(item.get('RootRelativeBundlePath') == 'Parachute.app' for item in components):
    raise SystemExit('Analyzed package is missing the root application')
def prevent_relocation(items):
    for item in items:
        # Never redirect installation to a matching app in Downloads, a build
        # folder, or the extracted ZIP used by CI's installation check.
        item['BundleIsRelocatable'] = False
        prevent_relocation(item.get('ChildBundles', []))
prevent_relocation(components)
with open(path, 'wb') as file: plistlib.dump(components, file)
PY
pkgbuild --root "$STAGING_DIR/root" --component-plist "$STAGING_DIR/components.plist" \
    --identifier "$BUNDLE_ID" --version "$VERSION" --install-location /Applications "$OUTPUT"
)

notarize() (
INPUT="${1:?Notarization input is required}"
PREFIX="${2:?Evidence prefix is required}"
: "${KEYCHAIN_PATH:?}" "${NOTARY_PROFILE:?}"
mkdir -p "$(dirname "$PREFIX")"
echo "Submitting $(basename "$INPUT") to Apple notarization"
# Save the submission ID before waiting, including when a later wait is cancelled.
xcrun notarytool submit "$INPUT" --keychain "$KEYCHAIN_PATH" --keychain-profile "$NOTARY_PROFILE" \
    --output-format json > "$PREFIX-submission.json"
SUBMISSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$PREFIX-submission.json")"
echo "Waiting for notarization submission $SUBMISSION"
WAIT_EXIT=0
xcrun notarytool wait "$SUBMISSION" --keychain "$KEYCHAIN_PATH" --keychain-profile "$NOTARY_PROFILE" \
    --timeout 30m --output-format json > "$PREFIX.json" || WAIT_EXIT=$?
xcrun notarytool log "$SUBMISSION" --keychain "$KEYCHAIN_PATH" --keychain-profile "$NOTARY_PROFILE" \
    "$PREFIX-log.json" || true
STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status", "Unknown"))' "$PREFIX.json")"
[ "$WAIT_EXIT" = 0 ] && [ "$STATUS" = Accepted ] || { echo "Notarization failed or timed out: $STATUS" >&2; exit 1; }
echo "Apple accepted notarization submission $SUBMISSION"
)

# The unsigned component entry point supports focused packaging tests.
if [ "${1:-}" = component ]; then
    shift
    build_component "$@"
    exit 0
fi

APP_PATH="${1:?Usage: package.sh application.app output-directory}"
OUTPUT_DIR="${2:?Output directory is required}"
PHASE="${3:-all}"
case "$PHASE" in all|sign|notarize-app|build-pkg|notarize-pkg) ;; *) echo 'Unknown packaging phase' >&2; exit 1;; esac
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
STEM="Parachute-native-$ASSET_ARCH-$RELEASE_VERSION"
echo "Native packaging phase: $PHASE"
if [ "$PHASE" = all ] || [ "$PHASE" = sign ]; then
    xattr -cr "$APP_PATH"
    python3 "$SCRIPT_DIR/process.py" run --timeout 600 --log "$OUTPUT_DIR/app-signing.log" -- bash "$SCRIPT_DIR/sign-app.sh" "$APP_PATH"
fi
if [ "$PHASE" = all ] || [ "$PHASE" = notarize-app ]; then
# Notarize the app payload, staple it, then create the final ZIP. ZIP itself
# cannot hold a stapled ticket. Both Squirrel and Sparkle receive the same app.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$STAGING_DIR/app-for-notary.zip"
notarize "$STAGING_DIR/app-for-notary.zip" "$OUTPUT_DIR/app-notarization"
python3 "$SCRIPT_DIR/process.py" staple "$APP_PATH"
python3 "$SCRIPT_DIR/process.py" validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$OUTPUT_DIR/$STEM.zip"
fi
if [ "$PHASE" = all ] || [ "$PHASE" = build-pkg ]; then
python3 - "$STAGING_DIR/requirements.plist" "$RELEASE_ARCH" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump({'os': ['14.0'], 'arch': [sys.argv[2]], 'home': False}, file)
PY
python3 "$SCRIPT_DIR/process.py" run --timeout 120 --log "$OUTPUT_DIR/pkg-component.log" -- \
    bash "$SCRIPT_DIR/package.sh" component "$APP_PATH" "$STAGING_DIR/payload.pkg" "$BUNDLE_ID" "$RELEASE_VERSION"
python3 "$SCRIPT_DIR/process.py" run --timeout 600 --log "$OUTPUT_DIR/pkg-build.log" -- \
    productbuild --package "$STAGING_DIR/payload.pkg" --product "$STAGING_DIR/requirements.plist" \
    --identifier "$BUNDLE_ID.installer" --version "$RELEASE_VERSION" \
    --sign "$APPLE_INSTALLER_SIGN_ID" --keychain "$KEYCHAIN_PATH" "$OUTPUT_DIR/$STEM.pkg"
fi
if [ "$PHASE" = all ] || [ "$PHASE" = notarize-pkg ]; then
notarize "$OUTPUT_DIR/$STEM.pkg" "$OUTPUT_DIR/pkg-notarization"
python3 "$SCRIPT_DIR/process.py" staple "$OUTPUT_DIR/$STEM.pkg"
python3 "$SCRIPT_DIR/process.py" validate "$OUTPUT_DIR/$STEM.pkg"
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
fi
echo "Native packaging phase completed: $PHASE"
