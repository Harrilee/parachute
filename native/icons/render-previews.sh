#!/bin/bash
set -euo pipefail
ICON_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$ICON_DIR/../build/icon-previews}"
ICON_TOOL="${ICTOOL:-}"
if [ -z "$ICON_TOOL" ]; then
    DEVELOPER_PATH="$(xcode-select -p)"
    for CANDIDATE in \
        "$DEVELOPER_PATH/../Applications/Icon Composer.app/Contents/Executables/ictool" \
        '/Applications/Icon Composer.app/Contents/Executables/ictool'; do
        if [ -x "$CANDIDATE" ]; then ICON_TOOL="$CANDIDATE"; break; fi
    done
fi
if [ -z "$ICON_TOOL" ] || [ ! -x "$ICON_TOOL" ]; then
    echo 'Set ICTOOL to the ictool executable inside Apple Icon Composer.app.' >&2
    exit 1
fi
codesign --verify --strict -R='anchor apple' "$ICON_TOOL"
mkdir -p "$OUTPUT_DIR"
for RENDITION in Default Dark ClearLight ClearDark TintedLight TintedDark; do
    "$ICON_TOOL" "$ICON_DIR/AppIcon.icon" --export-image \
        --output-file "$OUTPUT_DIR/$RENDITION.png" --platform macOS \
        --rendition "$RENDITION" --width 512 --height 512 --scale 1 \
        --tint-color 0.58 --tint-strength 0.6
done
echo "Rendered six native appearances in $OUTPUT_DIR"
