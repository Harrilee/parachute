#!/bin/bash
# CI-only: import existing Apple credentials into an ephemeral keychain.
set -euo pipefail
set +x
: "${RUNNER_TEMP:?Run this helper on a disposable CI runner}"
: "${GITHUB_ENV:?GitHub Actions environment file is required}"
: "${APPLE_CERTIFICATE:?Missing application certificate}"
: "${APPLE_CERTIFICATE_PASSWORD:?Missing application certificate password}"
: "${APPLE_INSTALLER_CERTIFICATE:?Missing installer certificate}"
: "${APPLE_INSTALLER_CERTIFICATE_PASSWORD:?Missing installer certificate password}"
: "${APPLE_ID:?Missing notarization Apple ID}"
: "${APPLE_PASSWORD:?Missing notarization password}"
: "${APPLE_TEAM_ID:?Missing Apple team ID}"
KEYCHAIN_PATH="$RUNNER_TEMP/parachute-native-signing.keychain-db"
NOTARY_PROFILE=parachute-native-notary
CERT_DIR="$(mktemp -d "$RUNNER_TEMP/parachute-certs.XXXXXX")"
trap 'rm -rf "$CERT_DIR"' EXIT
umask 077
printf '%s' "$APPLE_CERTIFICATE" | base64 --decode > "$CERT_DIR/application.p12"
printf '%s' "$APPLE_INSTALLER_CERTIFICATE" | base64 --decode > "$CERT_DIR/installer.p12"
SIGNING_KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"
printf '::add-mask::%s\n' "$SIGNING_KEYCHAIN_PASSWORD"
security create-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$SIGNING_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERT_DIR/application.p12" -P "$APPLE_CERTIFICATE_PASSWORD" -t cert -f pkcs12 -k "$KEYCHAIN_PATH" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security import "$CERT_DIR/installer.p12" -P "$APPLE_INSTALLER_CERTIFICATE_PASSWORD" -t cert -f pkcs12 -k "$KEYCHAIN_PATH" -T /usr/bin/productbuild -T /usr/bin/productsign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$SIGNING_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH" login.keychain-db
# The identity names are public certificate metadata. Require one identity of
# each class for the expected team; never guess from a source-code constant.
python3 - "$KEYCHAIN_PATH" "$APPLE_TEAM_ID" "$GITHUB_ENV" <<'PY'
import re, subprocess, sys
output = subprocess.check_output(['security', 'find-identity', '-v', sys.argv[1]], text=True)
identities = re.findall(r'\b[0-9A-Fa-f]{40}\s+"([^"]+)"', output)
with open(sys.argv[3], 'a') as file:
    for variable, prefix in [('APPLE_SIGN_ID', 'Developer ID Application:'), ('APPLE_INSTALLER_SIGN_ID', 'Developer ID Installer:')]:
        matches = [name for name in identities if name.startswith(prefix) and name.endswith('(' + sys.argv[2] + ')')]
        if len(matches) != 1:
            raise SystemExit('Expected one valid ' + prefix + ' identity for the configured team')
        file.write(variable + '=' + matches[0] + '\n')
PY
xcrun notarytool store-credentials "$NOTARY_PROFILE" --keychain "$KEYCHAIN_PATH" \
    --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" >/dev/null
printf 'KEYCHAIN_PATH=%s\nNOTARY_PROFILE=%s\n' "$KEYCHAIN_PATH" "$NOTARY_PROFILE" >> "$GITHUB_ENV"
