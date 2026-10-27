#!/bin/bash
set -euo pipefail
APP_PATH="${1:?Usage: build-component.sh application.app output.pkg bundle-id version}"
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
