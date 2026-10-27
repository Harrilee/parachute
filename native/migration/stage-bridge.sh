#!/bin/bash
set -euo pipefail
MIGRATION_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$MIGRATION_DIR/../.." && pwd)"
STAGE="${1:?Usage: stage-bridge.sh new-staging-directory}"
if [ -e "$STAGE" ]; then
    echo 'Bridge staging directory must not already exist' >&2
    exit 1
fi
mkdir -p "$STAGE"
cp "$REPO_DIR/package.json" "$REPO_DIR/forge.config.js" "$REPO_DIR/icon.icns" "$STAGE/"
cp "$MIGRATION_DIR/bridge-package-lock.json" "$STAGE/package-lock.json"
cp "$REPO_DIR"/webpack*.js "$REPO_DIR"/entitlements*.plist "$STAGE/"
cp -R "$REPO_DIR/src" "$REPO_DIR/scripts" "$STAGE/"
# Staged builds retain the working tree and root package version unchanged.
python3 - "$STAGE" <<'PY'
import json, pathlib, plistlib, sys
stage = pathlib.Path(sys.argv[1])
path = stage / 'package.json'
package = json.loads(path.read_text())
package['version'] = '0.3.9'
package['description'] = 'Parachute compatibility update for the native macOS migration'
# The generated stage has no .git directory and does not need development hooks.
package['scripts'].pop('prepare', None)
path.write_text(json.dumps(package, indent=2) + '\n')
lock_path = stage / 'package-lock.json'
lock = json.loads(lock_path.read_text())
lock['version'] = lock['packages']['']['version'] = '0.3.9'
lock_path.write_text(json.dumps(lock, indent=2) + '\n')
# Location lookup is absent even in the bridge's legacy fallback interface.
renderer = stage / 'src/App.jsx'
text = renderer.read_text()
needle = '<LocateButton map={map} />'
if text.count(needle) != 1:
    raise SystemExit('Expected exactly one legacy location control')
renderer.write_text(text.replace(needle, ''))
entitlements = stage / 'entitlements.plist'
values = plistlib.loads(entitlements.read_bytes())
values.pop('com.apple.security.personal-information.location', None)
entitlements.write_bytes(plistlib.dumps(values))
PY
cat >> "$STAGE/forge.config.js" <<'JS'

// CI uses the identities already validated by the shared signing setup.
module.exports.packagerConfig.osxSign.identity = process.env.APPLE_SIGN_ID
module.exports.packagerConfig.osxSign.keychain = process.env.KEYCHAIN_PATH
// finish-bridge.sh notarizes, retries stapling, and recreates the final ZIP.
// Forge's internal stapler has no retry for transient CloudKit failures.
delete module.exports.packagerConfig.osxNotarize
delete module.exports.packagerConfig.extendInfo.NSLocationWhenInUseUsageDescription
delete module.exports.packagerConfig.extendInfo.NSLocationUsageDescription
const installer = module.exports.makers.find(maker => maker.name === '@electron-forge/maker-pkg')
installer.config.identity = process.env.APPLE_INSTALLER_SIGN_ID
JS
echo "Staged Electron bridge 0.3.9: $STAGE"
