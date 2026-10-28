# Native macOS application

Parachute 1.0.1 uses SwiftUI, Apple MapKit and Sparkle 2, with macOS 14 as its deployment target. This source tree contains the native application and its tooling. The published Electron 0.3.9 and native 1.0.0 releases remain the first-upgrade path; see the [release procedure](release.md).

## Build and run

Release builds require macOS 26 with Xcode 26.2 or later for layered icon compilation, plus Go 1.24.4. The application itself runs on macOS 14 or later. Local builds with only Command Line Tools use the static icon fallback.

```sh
bash scripts/release/build-go-ios.sh "$(uname -m)" "$PWD/build/ios-native"
NATIVE_GO_IOS_BINARY="$PWD/build/ios-native" bash scripts/build.sh
open build/Parachute.app
```

`scripts/build.sh` accepts an output `.app` path as its first argument. Without `NATIVE_GO_IOS_BINARY`, it invokes the same pinned helper builder and cache directly. The helper adds an acknowledgement after the device accepts a location request and enforces explicit transport selection; the upstream revision and dependencies remain pinned. Its provenance is bundled in `ios-build-info.txt`; see [the build contract](go-ios.md).

Local builds are ad-hoc signed and use the separate identifier `li.haorui.Parachute.NativePrototype`, with Sparkle disabled. They do not replace the installed production application or migrate its preferences. Launch with `--preview` to suppress device polling as well:

```sh
build/Parachute.app/Contents/MacOS/Parachute --preview
```

## Interface

- Full-window MapKit map, a floating device panel and native editing sheets. Panels use Liquid Glass on macOS 26, native material on earlier systems, and an opaque fallback with Reduce Transparency. The device panel scrolls when needed; the window-control strip supports dragging.
- Standard and satellite maps preserve the overhead camera. Address search uses native MapKit suggestions and the visible map region. Selection updates the marker, coordinates and camera without simulating a device location. Search cancels stale requests and preserves native IME composition and candidate confirmation.
- Longitude and latitude share one row; the pencil opens an editor preserving full precision. Finite decimal values, zero and negatives are accepted within longitude ±180 and latitude ±90. Empty, malformed and out-of-range values, including ambiguous decimal commas, are rejected.
- A successful command acknowledgement emits four finite green rings at that request's coordinate, behind the marker. Reduce Motion uses a brief stationary ring. An acknowledgement does not independently verify the phone's reported location.
- Native English, Simplified Chinese and Traditional Chinese resources follow macOS system/per-app language and appearance settings. There is no custom language preference store or current-location permission request.

## Device controls and boundaries

The app discovers devices reported by usbmuxd as USB or Network and prefers USB for a device reachable through both. The selected transport is enforced by the helper, including tunnel lookup. Connected status does not claim that a location tunnel or simulation has succeeded. A transport change stops the old owned session; users explicitly retry rather than silently continuing over a different connection. Wireless remains available on a best-effort basis, with USB guidance if discovery, trust, tunnel setup or simulation fails. Device-changing actions require a user click and use `Process` argument arrays with bounded execution and cleanup of owned subprocesses.

Simulation reuses a compatible external tunnel with matching transport metadata or starts an owned userspace tunnel on a private loopback port. It never installs privileged helpers, prompts for administrator access, changes sudoers or pauses `remoted`. The pinned helper's userspace mode requires iOS later than 17.4; older iOS 17 devices need an existing compatible tunnel created with a helper that reports its transport, while pre-iOS 17 uses the legacy USB service. Owned processes stop on disconnect and exit.

Connection and Developer Mode guide images are preserved in `Resources/Help/`. Failure details are retained in `last-action-failure.log`; `diagnostic.log` is limited to 256 KiB. Logs redact device identifiers and coordinates. Production runtime files live in `~/Library/Application Support/Parachute/go-ios-runtime`; previews use `ParachuteNativePrototype/go-ios-runtime`. Pairing identities are not copied from Electron.

## Verification

`bash scripts/test.sh` covers coordinate boundaries, fake-device discovery/tunnel/acknowledgement behavior, search cancellation, native language selection and updater configuration. `NATIVE_TEST_SPARKLE=1` also runs signed appcast fixtures. These tests do not change device locations or system language preferences.

`bash scripts/test-input.sh` exercises the actual AppKit field editor and marked text in a temporary window using fake search responses. It simulates candidate confirmation without changing the system input source; it does not automate the operating system's candidate chooser.

`python3 Tests/ReleaseTests/ReleaseToolsTests.py` covers process cleanup, ticket retries, package metadata and bridge provenance using local fixtures. See [release validation](release.md), [migration validation](migration.md), and [Sparkle validation](updates.md) for signing, installation and upgrade checks. Record validation against the exact source commit and artifact hashes.

## Deferred

- True on-device location simulation and disconnect/reconnect validation, including network-only operation and compatibility with older privileged tunnels.
- The untouched published Electron application's complete download/approval/replacement/relaunch flow, older-macOS execution and production-signed native Sparkle upgrades.

These remain publication gates. Native 1.0.1 uses build number 1000001 and retains `com.electron.parachute`, the publisher identity and a small native relaunch compatibility helper. Preparing local or CI artifacts does not publish a release or activate its feeds.
