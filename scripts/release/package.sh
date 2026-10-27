#!/bin/bash
# Build, notarize and verify the Electron transition artifacts in visible phases.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Subshell functions keep temporary directories and cleanup traps independent.
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
    INPUT="${1:?Usage: notarize input-file evidence-prefix}"
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

build_pkg() (
    APP_PATH="${1:?Usage: build_pkg signed-bridge.app output.pkg}"
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
    python3 "$SCRIPT_DIR/process.py" run --timeout 120 --log "$OUTPUT_PKG-component.log" -- \
        bash "$SCRIPT_DIR/package.sh" component "$APP_PATH" "$STAGING_DIR/payload.pkg" com.electron.parachute 0.3.9
    python3 "$SCRIPT_DIR/process.py" run --timeout 600 --log "$OUTPUT_PKG-build.log" -- \
        /usr/bin/productbuild --package "$STAGING_DIR/payload.pkg" \
        --product "$STAGING_DIR/requirements.plist" \
        --identifier com.electron.parachute.installer --version 0.3.9 \
        --sign "$APPLE_INSTALLER_SIGN_ID" --keychain "$KEYCHAIN_PATH" "$OUTPUT_PKG"
    /usr/sbin/pkgutil --check-signature "$OUTPUT_PKG"
    echo "Built bridge installer: $OUTPUT_PKG"
)

prepare_app() {
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
    notarize "$ZIP" "$OUTPUT_DIR/bridge-app-notarization"
    python3 "$SCRIPT_DIR/process.py" staple "$APP_PATH"
    python3 "$SCRIPT_DIR/process.py" validate "$APP_PATH"
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
}

verify_installer() {
    notarize "$PKG" "$OUTPUT_DIR/bridge-pkg-notarization"
    python3 "$SCRIPT_DIR/process.py" staple "$PKG"
    python3 "$SCRIPT_DIR/process.py" validate "$PKG"
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
    python3 - "$OUTPUT_DIR" "$ASSET_ARCH" "$APP_PATH/Contents/Info.plist" <<'PYMANIFEST'
import hashlib, json, os, pathlib, plistlib, subprocess, sys
output, arch = pathlib.Path(sys.argv[1]), sys.argv[2]
with open(sys.argv[3], 'rb') as file: info = plistlib.load(file)
manifest = {
    'sourceCommit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'workflowRun': os.environ.get('GITHUB_RUN_ID'),
    'workflowPath': '.github/workflows/release.yml',
    'version': info['CFBundleShortVersionString'],
    'bundleID': info['CFBundleIdentifier'],
    'minimumMacOS': info['LSMinimumSystemVersion'],
    'architecture': arch,
    'artifacts': {},
}
for name in (f'Parachute-darwin-{arch}-0.3.9.zip', f'Parachute-0.3.9-{arch}.pkg'):
    path = output / name
    manifest['artifacts'][name] = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'bytes': path.stat().st_size}
(output / f'bridge-{arch}-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PYMANIFEST
}

# The unsigned component entry point is also exercised by the package-layout test.
if [ "${1:-}" = component ]; then
    shift
    build_component "$@"
    exit
fi

MAKE_DIR="${1:?Usage: package.sh staged-out-make artifact-directory}"
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
case "$PHASE" in
    all) prepare_app; build_pkg "$APP_PATH" "$PKG"; verify_installer ;;
    prepare) prepare_app ;;
    build-pkg) build_pkg "$APP_PATH" "$PKG" ;;
    notarize-pkg) verify_installer ;;
esac
echo "Bridge packaging phase completed: $PHASE"
