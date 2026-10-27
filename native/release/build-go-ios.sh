#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NATIVE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_URL=https://github.com/Harrilee/go-ios.git
SOURCE_COMMIT=80ed9e1cb2c9dfd8af38efff54e0feaad6fe742b
ORIGINAL_SHA=0d5d80df01f77b9c0532d6e95530ed07f7915159b0d363089038798ce8c80798
ARCH="${1:?Usage: build-go-ios.sh arm64\|x86_64 output-path}"
OUTPUT="${2:?Output path is required}"
case "$ARCH" in arm64) GO_TARGET_ARCH=arm64;; x86_64) GO_TARGET_ARCH=amd64;; *) echo 'Unsupported architecture' >&2; exit 1;; esac
GO_COMPILER="$(go version)"
case "$GO_COMPILER" in 'go version go1.24.4 '*) ;; *) echo 'Go 1.24.4 is required; no automatic toolchain upgrades.' >&2; exit 1;; esac
mkdir -p "$(dirname "$OUTPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"
REPO_DIR="$(cd "$NATIVE_DIR/.." && pwd)"
[ "$OUTPUT" != "$REPO_DIR/bin/ios" ] || { echo 'Refusing to replace the original Electron binary.' >&2; exit 1; }
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/parachute-go-release.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
if [ -n "${GO_IOS_SOURCE_DIR:-}" ]; then
    git clone --quiet --no-checkout --no-hardlinks "$GO_IOS_SOURCE_DIR" "$STAGING_DIR/source"
else
    git init --quiet "$STAGING_DIR/source"
    git -C "$STAGING_DIR/source" remote add origin "$SOURCE_URL"
    git -C "$STAGING_DIR/source" fetch --quiet --depth 1 origin "$SOURCE_COMMIT"
fi
git -C "$STAGING_DIR/source" checkout --quiet --detach "$SOURCE_COMMIT"
[ "$(git -C "$STAGING_DIR/source" rev-parse HEAD)" = "$SOURCE_COMMIT" ]
git -C "$STAGING_DIR/source" apply --check "$NATIVE_DIR/go-ios/location-ack.patch"
git -C "$STAGING_DIR/source" apply "$NATIVE_DIR/go-ios/location-ack.patch"
(
    cd "$STAGING_DIR/source"
    # Fresh CI may download the existing pinned modules. Neither this command nor
    # the acknowledgement patch may upgrade dependencies or change lock files.
    GOTOOLCHAIN=local GOOS=darwin GOARCH="$GO_TARGET_ARCH" CGO_ENABLED=0 \
        go build -mod=readonly -trimpath -ldflags='-s -w' -o "$STAGING_DIR/ios" ./main.go
    git diff --exit-code -- '*.mod' '*.sum' go.work
    [ -z "$(git ls-files --others --exclude-standard -- '*.mod' '*.sum' go.work)" ]
)
go version -m "$STAGING_DIR/ios" | awk '$1 == "dep" { sub(/[[:space:]]+$/, ""); print }' | LC_ALL=C sort > "$STAGING_DIR/dependencies.txt"
diff -u "$SCRIPT_DIR/go-ios-dependencies.txt" "$STAGING_DIR/dependencies.txt"
/usr/bin/lipo "$STAGING_DIR/ios" -verify_arch "$ARCH"
mv "$STAGING_DIR/ios" "$OUTPUT"
chmod +x "$OUTPUT"
cat > "$OUTPUT.build-info.txt" <<INFO
source_url=$SOURCE_URL
source_ref=v1.0.204
source_commit=$SOURCE_COMMIT
patch_sha256=$(shasum -a 256 "$NATIVE_DIR/go-ios/location-ack.patch" | awk '{print $1}')
original_binary_sha256=$ORIGINAL_SHA
patched_binary_sha256=$(shasum -a 256 "$OUTPUT" | awk '{print $1}')
compiler=$GO_COMPILER
goos=darwin
goarch=$GO_TARGET_ARCH
module_files_unchanged=true
dependency_records_unchanged=true
ack_event=location-simulation-started
INFO
echo "Built pinned go-ios acknowledgement variant: $OUTPUT"
