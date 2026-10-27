#!/bin/bash
# A tiny, never-installed fixture isolates package creation from key access.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PHASE="${1:?Usage: probe-installer.sh create-or-sign}"
: "${RUNNER_TEMP:?Disposable CI runner required}"
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'Signing probe is CI-only.' >&2; exit 1; }
PROBE_DIR="$RUNNER_TEMP/installer-preflight"
mkdir -p "$PROBE_DIR"
case "$PHASE" in
    create)
        mkdir -p "$PROBE_DIR/payload"
        printf 'Temporary installer signing fixture; never installed.\n' > "$PROBE_DIR/payload/probe.txt"
        python3 "$SCRIPT_DIR/run-bounded.py" --timeout 60 --log "$PROBE_DIR/create.log" -- \
            /usr/bin/pkgbuild --root "$PROBE_DIR/payload" \
            --identifier com.electron.parachute.signing-probe --version 1 \
            --install-location /private/tmp/parachute-signing-probe "$PROBE_DIR/unsigned.pkg"
        ;;
    sign)
        : "${APPLE_INSTALLER_SIGN_ID:?}" "${KEYCHAIN_PATH:?}"
        python3 "$SCRIPT_DIR/run-bounded.py" --timeout 60 --log "$PROBE_DIR/sign.log" -- \
            /usr/bin/productsign --sign "$APPLE_INSTALLER_SIGN_ID" --keychain "$KEYCHAIN_PATH" \
            "$PROBE_DIR/unsigned.pkg" "$PROBE_DIR/signed.pkg"
        /usr/sbin/pkgutil --check-signature "$PROBE_DIR/signed.pkg"
        ;;
    *) echo 'Unknown signing probe phase.' >&2; exit 1;;
esac
