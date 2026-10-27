#!/bin/bash
# Download only the pinned, checksum-verified official Sparkle distribution.
# stdout is the distribution root; diagnostics go to stderr.
set -euo pipefail
UPDATER_DIR="$(cd "$(dirname "$0")" && pwd)"
NATIVE_DIR="$(cd "$UPDATER_DIR/.." && pwd)"
SPARKLE_VERSION="2.10.1"
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
CACHE_DIR="$NATIVE_DIR/build/cache"
ARCHIVE="$CACHE_DIR/Sparkle-$SPARKLE_VERSION.tar.xz"
DESTINATION="$CACHE_DIR/sparkle-$SPARKLE_VERSION"
mkdir -p "$CACHE_DIR"
STAGING="$(mktemp -d "$CACHE_DIR/sparkle-fetch.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

if [ ! -f "$ARCHIVE" ]; then
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --silent --show-error \
        "$SPARKLE_URL" -o "$STAGING/download.tar.xz"
    ACTUAL="$(shasum -a 256 "$STAGING/download.tar.xz" | cut -d ' ' -f 1)"
    [ "$ACTUAL" = "$SPARKLE_SHA256" ] || { echo 'Sparkle archive checksum mismatch.' >&2; exit 1; }
    mv "$STAGING/download.tar.xz" "$ARCHIVE"
fi
ACTUAL="$(shasum -a 256 "$ARCHIVE" | cut -d ' ' -f 1)"
[ "$ACTUAL" = "$SPARKLE_SHA256" ] || { echo 'Cached Sparkle archive checksum mismatch.' >&2; exit 1; }

if [ ! -f "$DESTINATION/.archive-sha256" ]; then
    mkdir "$STAGING/distribution"
    tar -xf "$ARCHIVE" -C "$STAGING/distribution"
    printf '%s\n' "$SPARKLE_SHA256" > "$STAGING/distribution/.archive-sha256"
    if [ ! -e "$DESTINATION" ]; then
        mv "$STAGING/distribution" "$DESTINATION"
    fi
fi
[ "$(cat "$DESTINATION/.archive-sha256")" = "$SPARKLE_SHA256" ] || {
    echo 'Sparkle distribution cache does not match the pinned archive.' >&2; exit 1;
}
/usr/bin/lipo -verify_arch arm64 "$DESTINATION/Sparkle.framework/Sparkle"
/usr/bin/lipo -verify_arch x86_64 "$DESTINATION/Sparkle.framework/Sparkle"
codesign --verify --deep --strict "$DESTINATION/Sparkle.framework"
[ -x "$DESTINATION/bin/sign_update" ] && [ -x "$DESTINATION/bin/generate_appcast" ] && [ -x "$DESTINATION/bin/generate_keys" ]
printf '%s\n' "$DESTINATION"
