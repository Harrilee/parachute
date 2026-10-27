#!/bin/bash
set -euo pipefail
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
NATIVE_DIR="$(cd "$PATCH_DIR/.." && pwd)"
REPO_DIR="$(cd "$NATIVE_DIR/.." && pwd)"
SOURCE_URL="https://github.com/Harrilee/go-ios.git"
SOURCE_COMMIT="80ed9e1cb2c9dfd8af38efff54e0feaad6fe742b"
OUTPUT="$NATIVE_DIR/build/ios-with-ack"
mkdir -p "$NATIVE_DIR/build"
ORIGINAL_SHA="$(shasum -a 256 "$REPO_DIR/bin/ios" | cut -d ' ' -f 1)"
GO_COMPILER="$(go version)"
case "$GO_COMPILER" in
    'go version go1.24.4 '*) ;;
    *) echo "This pinned prototype build requires the tested Go 1.24.4 compiler; found: $GO_COMPILER" >&2; exit 1;;
esac
ARCH="$(uname -m)"
case "$ARCH" in arm64) GO_TARGET_ARCH=arm64;; x86_64) GO_TARGET_ARCH=amd64;; *) echo "Unsupported macOS architecture: $ARCH" >&2; exit 1;; esac
PATCH_SHA="$(shasum -a 256 "$PATCH_DIR/location-ack.patch" | cut -d ' ' -f 1)"
INFO_FILE="$OUTPUT.build-info.txt"
# Treat metadata as data only: never source or evaluate it as shell code.
metadata_value() {
    /usr/bin/awk -v wanted="$1" 'index($0, wanted "=") == 1 { print substr($0, length(wanted) + 2); exit }' "$INFO_FILE"
}
if [ -x "$OUTPUT" ] && [ -f "$INFO_FILE" ] &&
    [ "$(metadata_value source_commit)" = "$SOURCE_COMMIT" ] &&
    [ "$(metadata_value patch_sha256)" = "$PATCH_SHA" ] &&
    [ "$(metadata_value compiler)" = "$GO_COMPILER" ] &&
    [ "$(metadata_value original_binary_sha256)" = "$ORIGINAL_SHA" ] &&
    [ "$(metadata_value goos)" = darwin ] &&
    [ "$(metadata_value goarch)" = "$GO_TARGET_ARCH" ] &&
    [ "$(metadata_value module_files_unchanged)" = true ] &&
    [ "$(metadata_value dependency_records_unchanged)" = true ] &&
    [ "$(metadata_value ack_event)" = location-simulation-started ] &&
    [ "$(metadata_value patched_binary_sha256)" = "$(shasum -a 256 "$OUTPUT" | cut -d ' ' -f 1)" ]; then
    echo "Using verified cached acknowledgement variant: $OUTPUT"
    exit 0
fi
STAGING_DIR="$(mktemp -d "$NATIVE_DIR/build/go-ios-ack.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
if [ -n "${GO_IOS_SOURCE_DIR:-}" ]; then
    # Optional local source cache. Build in a fresh clone; never patch the caller's checkout.
    git clone --quiet --no-checkout --no-hardlinks "$GO_IOS_SOURCE_DIR" "$STAGING_DIR/source"
else
    git init --quiet "$STAGING_DIR/source"
    git -C "$STAGING_DIR/source" remote add origin "$SOURCE_URL"
    git -C "$STAGING_DIR/source" fetch --quiet --depth 1 origin "$SOURCE_COMMIT"
fi
git -C "$STAGING_DIR/source" checkout --quiet --detach "$SOURCE_COMMIT"
[ "$(git -C "$STAGING_DIR/source" rev-parse HEAD)" = "$SOURCE_COMMIT" ]
git -C "$STAGING_DIR/source" apply --check "$PATCH_DIR/location-ack.patch"
git -C "$STAGING_DIR/source" apply "$PATCH_DIR/location-ack.patch"
(
    cd "$STAGING_DIR/source"
    # Use the checked-in workspace/module versions. Never resolve newer dependencies.
    # Offline mode keeps this local prototype build from fetching replacement dependency data.
    GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off GOOS=darwin GOARCH="$GO_TARGET_ARCH" CGO_ENABLED=0 \
        go build -mod=readonly -trimpath -ldflags='-s -w' -o "$STAGING_DIR/ios-with-ack" ./main.go
    git diff --exit-code -- go.mod go.sum go.work go.work.sum ncm/go.mod ncm/go.sum restapi/go.mod restapi/go.sum
)
[ "$(shasum -a 256 "$REPO_DIR/bin/ios" | cut -d ' ' -f 1)" = "$ORIGINAL_SHA" ]
go version -m "$REPO_DIR/bin/ios" | awk '$1 == "dep" { print }' | LC_ALL=C sort > "$STAGING_DIR/original-dependencies.txt"
go version -m "$STAGING_DIR/ios-with-ack" | awk '$1 == "dep" { print }' | LC_ALL=C sort > "$STAGING_DIR/patched-dependencies.txt"
diff -u "$STAGING_DIR/original-dependencies.txt" "$STAGING_DIR/patched-dependencies.txt"
mv "$STAGING_DIR/ios-with-ack" "$OUTPUT"
chmod +x "$OUTPUT"
PATCHED_SHA="$(shasum -a 256 "$OUTPUT" | cut -d ' ' -f 1)"
cat > "$OUTPUT.build-info.txt" <<INFO
source_url=$SOURCE_URL
source_ref=v1.0.204
source_commit=$SOURCE_COMMIT
patch_sha256=$PATCH_SHA
original_binary_sha256=$ORIGINAL_SHA
patched_binary_sha256=$PATCHED_SHA
compiler=$GO_COMPILER
goos=darwin
goarch=$GO_TARGET_ARCH
module_files_unchanged=true
dependency_records_unchanged=true
ack_event=location-simulation-started
INFO
echo "Built local acknowledgement variant: $OUTPUT"
echo "Original bin/ios preserved: $ORIGINAL_SHA"
echo "Patched SHA-256: $PATCHED_SHA"
