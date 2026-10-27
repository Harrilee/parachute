#!/bin/bash
set -euo pipefail
NATIVE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${NATIVE_ARCH:-$(uname -m)}"
# Preview and release use the same pinned source, compiler, module manifest and
# acknowledgement patch. No previous Electron checkout or binary is required.
bash "$NATIVE_DIR/release/build-go-ios.sh" "$ARCH" "$NATIVE_DIR/build/ios-with-ack"
