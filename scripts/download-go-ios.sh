#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/Harrilee/go-ios.git"
BRANCH="v1.0.204"
BIN_DIR="$(cd "$(dirname "$0")/.." && pwd)/bin"
DEST="$BIN_DIR/ios"

if [ -x "$DEST" ] && [ "${FORCE_REBUILD:-}" != "1" ]; then
  echo "go-ios binary already exists at ${DEST}, skipping build. Set FORCE_REBUILD=1 to rebuild."
  exit 0
fi

if ! command -v go &>/dev/null; then
  echo "Error: Go is required to build go-ios. Install it with: brew install go" >&2
  exit 1
fi

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Building go-ios from ${REPO} @ ${BRANCH}..."
git clone --depth 1 --branch "$BRANCH" "$REPO" "$TMPDIR/go-ios"

cd "$TMPDIR/go-ios"
go work use .
GOOS="${GOOS:-$(go env GOOS)}" GOARCH="${GOARCH:-$(go env GOARCH)}" CGO_ENABLED=0 \
  go build -trimpath -ldflags="-s -w" -o "$TMPDIR/ios" ./main.go

mkdir -p "$BIN_DIR"
mv "$TMPDIR/ios" "$DEST"
chmod +x "$DEST"

echo "Done. Binary at: ${DEST}"
