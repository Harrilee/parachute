#!/bin/bash
set -euo pipefail
NATIVE_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_APP="${1:-$NATIVE_DIR/build/Parachute.app}"
case "$OUTPUT_APP" in *.app) ;; *) echo 'Output must be an .app bundle.' >&2; exit 1 ;; esac
mkdir -p "$NATIVE_DIR/build"
STAGING_DIR="$(mktemp -d "$NATIVE_DIR/build/staging.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_PATH="$STAGING_DIR/Parachute.app"
ARCH="${NATIVE_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo 'Unsupported architecture.' >&2; exit 1 ;; esac
if [ -n "${NATIVE_GO_IOS_BINARY:-}" ]; then
    BINARY="$NATIVE_GO_IOS_BINARY"
else
    # Same pinned source/dependencies with one device acknowledgement log.
    BINARY="$NATIVE_DIR/build/ios-with-ack"
    bash "$NATIVE_DIR/release/build-go-ios.sh" "$ARCH" "$BINARY"
fi
BUILD_INFO="${NATIVE_GO_IOS_BUILD_INFO:-$BINARY.build-info.txt}"
/usr/bin/lipo "$BINARY" -verify_arch "$ARCH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
NATIVE_SDK_PATH="${NATIVE_SDK_PATH:-$(xcrun --show-sdk-path)}"
SWIFT_ARGS=()
if [ "${NATIVE_RELEASE:-0}" = "1" ]; then
    : "${RELEASE_VERSION:?}" "${BUILD_NUMBER:?}" "${BUNDLE_ID:?}" "${RELEASE_TEAM_ID:?}"
    : "${SPARKLE_PUBLIC_KEY:?}" "${SPARKLE_FEED_URL:?}"
    if [ -z "${SPARKLE_FRAMEWORK_PATH:-}" ]; then
        SPARKLE_FRAMEWORK_PATH="$(bash "$NATIVE_DIR/updater/fetch-sparkle.sh")/Sparkle.framework"
    fi
    /usr/bin/lipo "$SPARKLE_FRAMEWORK_PATH/Sparkle" -verify_arch "$ARCH"
    SWIFT_ARGS+=(-F "$(dirname "$SPARKLE_FRAMEWORK_PATH")" -framework Sparkle
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
    mkdir -p "$APP_PATH/Contents/Frameworks"
    ditto "$SPARKLE_FRAMEWORK_PATH" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
    cp "$(dirname "$SPARKLE_FRAMEWORK_PATH")/LICENSE" "$APP_PATH/Contents/Resources/Sparkle-LICENSE.txt"
else
    SWIFT_ARGS+=(-D LOCAL_PREVIEW)
fi
xcrun swiftc "${SWIFT_ARGS[@]}" -sdk "$NATIVE_SDK_PATH" -swift-version 5 -O -target "$ARCH-apple-macos14.0" \
    "$NATIVE_DIR"/Parachute/*.swift -o "$APP_PATH/Contents/MacOS/Parachute"
cp "$NATIVE_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
python3 - "$APP_PATH/Contents/Info.plist" <<'PY'
import base64, os, plistlib, re, sys
from urllib.parse import urlparse
path = sys.argv[1]
with open(path, 'rb') as f:
    info = plistlib.load(f)
if os.environ.get('NATIVE_RELEASE') == '1':
    version, build = os.environ['RELEASE_VERSION'], os.environ['BUILD_NUMBER']
    assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version)
    assert re.fullmatch(r'[1-9][0-9]*', build)
    assert os.environ['BUNDLE_ID'] == 'com.electron.parachute'
    assert os.environ['RELEASE_TEAM_ID'] == 'YCP6FXQDL5', 'Published app signing team must be retained'
    key = os.environ['SPARKLE_PUBLIC_KEY']
    assert len(base64.b64decode(key, validate=True)) == 32
    feed = os.environ['SPARKLE_FEED_URL']
    url = urlparse(feed)
    assert url.scheme == 'https' and url.hostname and not url.username and not url.password
    info.update(CFBundleIdentifier=os.environ['BUNDLE_ID'], CFBundleShortVersionString=version,
                CFBundleVersion=build, ParachuteUpdatesEnabled=True, SUFeedURL=feed,
                SUPublicEDKey=key, SUEnableAutomaticChecks=True,
                SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True)
else:
    info['ParachuteUpdatesEnabled'] = False
with open(path, 'wb') as f:
    plistlib.dump(info, f)
PY
cp -R "$NATIVE_DIR/Resources/". "$APP_PATH/Contents/Resources/"
ICON_ARGS=()
if [ -n "${NATIVE_ICON_REPORT:-}" ]; then ICON_ARGS+=(--report "$NATIVE_ICON_REPORT"); fi
python3 "$NATIVE_DIR/icons/compile-icon.py" "$APP_PATH" "${ICON_ARGS[@]}"
cp "$BINARY" "$APP_PATH/Contents/Resources/ios"
cp "$BUILD_INFO" "$APP_PATH/Contents/Resources/ios-build-info.txt"
chmod +x "$APP_PATH/Contents/Resources/ios"
xattr -cr "$APP_PATH"
if [ "${NATIVE_RELEASE:-0}" != "1" ]; then
    codesign --force --sign - "$APP_PATH/Contents/Resources/ios"
    codesign --force --sign - "$APP_PATH"
    codesign --verify --deep --strict "$APP_PATH"
fi
cmp "$BINARY" "$APP_PATH/Contents/Resources/ios" || {
    # Ad-hoc signing may add a signature to a cross-compiled helper; payloads stay identical.
    [ "${NATIVE_RELEASE:-0}" != "1" ] || exit 1
}
if [ -e "$OUTPUT_APP" ]; then
    EXPECTED_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$OUTPUT_APP/Contents/Info.plist")"
    [ "$EXISTING_ID" = "$EXPECTED_ID" ] || { echo 'Refusing to overwrite a different application.' >&2; exit 1; }
fi
mkdir -p "$OUTPUT_APP"
/usr/bin/rsync -a --delete "$APP_PATH/" "$OUTPUT_APP/"
if [ "${NATIVE_RELEASE:-0}" != "1" ]; then codesign --verify --deep --strict "$OUTPUT_APP"; fi
echo "Built: $OUTPUT_APP"
