#!/bin/bash
# Compile only the icon, without an app build, device access, or signing keys.
set -euo pipefail
ICON_DIR="$(cd "$(dirname "$0")" && pwd)"
EVIDENCE_DIR="${1:?Usage: test-compile.sh evidence-directory}"
mkdir -p "$EVIDENCE_DIR"
EVIDENCE_DIR="$(cd "$EVIDENCE_DIR" && pwd)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/parachute-icon-probe.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Parachute.app"
mkdir -p "$APP/Contents/Resources"
cp "$ICON_DIR/../Info.plist" "$APP/Contents/Info.plist"
python3 "$ICON_DIR/compile-icon.py" "$APP" --required --report "$EVIDENCE_DIR/icon-validation.json"
cp "$APP/Contents/Info.plist" "$EVIDENCE_DIR/icon-info.plist"
cp "$APP/Contents/Resources/Assets.car" "$EVIDENCE_DIR/Assets.car"
cp "$APP/Contents/Resources/"*.icns "$EVIDENCE_DIR/"
