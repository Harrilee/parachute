#!/bin/bash
set -euo pipefail
STAGE="${1:?Usage: provision-legacy-ios.sh bridge-stage arm64-or-x64}"
ARCH="${2:?Missing architecture}"
case "$ARCH" in
    arm64)
        ARCHIVE_SHA=e9912087e25a2a8b3d23f0f5abc3df055fd744d20d8ef990809279bff6aa629e
        BINARY_SHA=2aa5dadbb0865d61836a5ae41251cd6b4cd6fe131ce5ce132d7d099a6aadd934 ;;
    x64)
        ARCHIVE_SHA=3c64a40f42c66c678ddfcc6bdb881380ca6971b23740fe7817d475f0b2d9dc6a
        BINARY_SHA=74645b4df0d1ffc97fad0b4d6ddffe1eb8c92c095237c5d7c4fcd3a3ee1bb32a ;;
    *) echo 'Unsupported architecture' >&2; exit 1 ;;
esac
test -f "$STAGE/package.json"
DOWNLOAD_DIR="$(mktemp -d)"
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT
ARCHIVE="${LEGACY_APP_ARCHIVE:-$DOWNLOAD_DIR/legacy.zip}"
if [ -z "${LEGACY_APP_ARCHIVE:-}" ]; then
    curl --fail --location --retry 3 \
        "https://github.com/Harrilee/parachute/releases/download/v0.3.8/Parachute-darwin-$ARCH-0.3.8.zip" \
        -o "$ARCHIVE"
fi
printf '%s  %s\n' "$ARCHIVE_SHA" "$ARCHIVE" | shasum -a 256 --check
mkdir -p "$STAGE/bin"
unzip -p "$ARCHIVE" 'Parachute.app/Contents/Resources/ios' > "$STAGE/bin/ios"
printf '%s  %s\n' "$BINARY_SHA" "$STAGE/bin/ios" | shasum -a 256 --check
chmod +x "$STAGE/bin/ios"
echo "Prepared unchanged go-ios from the published 0.3.8 $ARCH application"
