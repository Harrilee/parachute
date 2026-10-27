# Native macOS application

Parachute 0.4.0 uses SwiftUI, Apple MapKit and Sparkle 2. This branch contains the native macOS application; Electron source and build tooling are removed. A separate PR and published Electron 0.3.9 release provide the compatibility bridge before 0.4.0 can ship. The release workflow prepares signed artifacts for review; publication remains explicit.

## Build and run

Release builds require macOS 26 with Xcode 26.2 or later for layered icon compilation, plus Go 1.24.4. The application itself runs on macOS 14 or later. Command Line Tools previews use the static icon fallback. The shared `native/release/build-go-ios.sh` helper can fetch the locked dependencies on a fresh machine and reuses a verified local build cache. No Electron checkout or previous `bin/ios` is required.

```sh
bash native/release/build-go-ios.sh "$(uname -m)" "$PWD/native/build/ios-native"
NATIVE_GO_IOS_BINARY="$PWD/native/build/ios-native" bash native/build.sh
open 'native/build/Parachute.app'
```

The output directory can be passed as the first argument. The native build uses a pinned go-ios variant with one acknowledgement log added after the device accepts a location request. Source and dependency versions are not upgraded. See [the patch and reproducible local build](go-ios/README.md). The bundled executable is verified against that build; its provenance is included in `ios-build-info.txt`. The app is ad-hoc signed for local use, not Developer ID signed or notarized.

On this development machine, the macOS 27 beta Command Line Tools SDK lacks the SwiftUI macro plugin. Use the already-installed stable SDK:

```sh
NATIVE_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash native/build.sh
NATIVE_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash native/test.sh
```

The default local preview uses the separate bundle identifier `li.haorui.Parachute.NativePrototype`. It does not replace an installed Electron app, migrate its preferences, or participate in its automatic updates.

## Interface

- Full-window MapKit map with a persistent floating device panel in the lower-left corner, native window buttons and sheets; system light/dark appearance. The panel fits its content and scrolls only when the available height is insufficient. No title toolbar or collapsing sidebar.
- Floating panels use native Liquid Glass on macOS 26 and later, with thin material on earlier systems and an opaque accessible fallback when Reduce Transparency is enabled. Nested opaque form backgrounds have been removed.
- Hovering over the top window-control row reveals a translucent native material strip. Its height follows the actual traffic-light diameter plus twice the gap from the window's top edge (32pt on the development machine). Dragging its center moves the window; native buttons retain their click targets. Below the strip, dragging pans the map.
- Map selection and marker with native drag/double-click navigation. The upper-right button switches between flat standard mapping and realistic satellite imagery while keeping the same overhead camera, without automatically tilting it.
- Native address/place search in the upper-left uses Apple MapKit suggestions and the visible map region. Its native search field retains editing, magnifier and clear controls inside one glass surface, without an inset bezel or focus ring. Select a suggestion or result to update the marker, coordinates and camera. Enter automatically selects a single matching address; multiple matches remain selectable. Search cancels outdated requests and never simulates a device location by itself.
- A successful location-command acknowledgement emits four green rings from that request's coordinate for 2.8 seconds. They use native geographic overlays below annotations, so the red marker and its label stay in front. Later selections cannot move an earlier pulse. Reduce Motion uses a brief stationary ring; animation neither intercepts map gestures nor continues indefinitely.
- Longitude and latitude on one row; pencil opens a native editing sheet. Editing preserves full precision; the sidebar displays five decimal places.
- Finite decimal coordinates including zero and negative values; longitude ±180 and latitude ±90. Empty, malformed and out-of-range inputs are rejected. Decimal commas are rejected to avoid ambiguity.
- Native English, Simplified Chinese and Traditional Chinese resources. macOS system/per-app language preferences select the language on launch. There is no custom language switch or preference store.
- No current-location lookup or permission request. Coordinates come only from map selection or manual entry.

macOS 14 is the deployment target because the application uses modern SwiftUI MapKit APIs. Liquid Glass is available on macOS 26 and later; earlier supported systems use native material. Electron users on macOS 10.15–13 remain on the compatible bridge version. See [the migration design](migration/README.md) for update routing and validation boundaries.

## Device controls and boundaries

The app polls go-ios for devices reported by usbmuxd as `USB` or `Network`, then reads pairing / Developer Mode status. Entries are deduplicated by UDID with USB preferred for the same device. A new selection prefers USB; an existing selection stays on the same reachable UDID across discovery reordering or USB-to-network fallback. The UI reports the discovered transport; go-ios chooses its underlying transport internally by UDID. Device-changing commands run only after a user clicks the relevant control. Calls use `Process` argument arrays, with timeouts, cancellation and cleanup limited to owned subprocesses.

Read-only checks on this development machine verified that its network-only iPhone is discoverable and that device-name and Developer Mode queries succeed. `ready` means the Developer Mode query succeeded; it does not establish that network tunnel setup or location simulation will succeed. The inspected fork source has no USB-only filter in the userspace tunnel path, but end-to-end network location simulation has not been tested.

On Simulate, the app reuses a ready external tunnel or starts its own `go-ios tunnel start --userspace` process on a private loopback port and waits for the selected device. Startup is bounded; failure is reported with retained diagnostics. It stops only owned processes, including on disconnect and exit, and never prompts for administrator access, installs helpers, writes sudoers or pauses `remoted`. The current binary's userspace mode requires iOS later than 17.4; older iOS 17 devices need an existing compatible tunnel, while pre-iOS 17 uses the legacy USB service. A live location command is explicitly distinguished from verification of the phone's reported location.

The unchanged local binary was tested starting an isolated userspace tunnel and returning a ready device tunnel; it was stopped afterward. This live check did not run `setlocation` or change the phone's location.

The existing connection and Developer Mode guide images are preserved byte-for-byte in `native/Resources/Help/` and bundled as native resources. Connection instructions are hidden when a trusted device is connected.

Failed action details are retained in `last-action-failure.log`; the rolling `diagnostic.log` is capped at 256 KiB. Both live in the application runtime directory. The UI exposes failure details and a Finder shortcut. Logs redact device identifiers and coordinate values. Prior builds deleted temporary command output, so earlier failed simulations may not be recoverable.

Production runtime files live in `~/Library/Application Support/Parachute/go-ios-runtime`; local previews use the separate `ParachuteNativePrototype/go-ios-runtime` directory. No pairing identity is copied from Electron. Device commands still require a usable pairing/trust relationship; verify this with a physical device before production use.

Historical helper inspection and retained native source baseline:

- The previous Electron build configuration referenced `Harrilee/go-ios` ref `v1.0.204`; the native builder pins the inspected commit from that ref.
- The inspected original local executable identified itself as `local-build`; its exact source commit was not embedded. Do not claim commit provenance from the ref alone.
- SHA-256: `0d5d80df01f77b9c0532d6e95530ed07f7915159b0d363089038798ce8c80798` (arm64).
- The original binary is a historical comparison baseline, not a build input retained on this branch. Its embedded dependency records are checked in as `native/release/go-ios-dependencies.txt`. The native app bundles a separately built acknowledgement variant from the pinned source, without upgrading dependencies. The Electron 0.3.9 PR retains its own published-binary provisioning. See `go-ios/README.md` for the provenance distinction.

## Verification

`native/test.sh` runs coordinate edge cases, fake-executable device service/tunnel/acknowledgement checks, MapKit search cancellation and stale-result tests, and native language/resource selection in a temporary bundle. Language tests also verify the bundle declares no location permission keys. It does not send device-changing commands or modify system language preferences.

Live Apple MapKit queries verified both an `Apple Park` completion and a single result for `1 Apple Park Way, Cupertino, CA`. Successful-command acknowledgement handling is tested with fake executables; the instrumented binary has not been used to set a real phone's location during automated validation.

Search keeps IME marked text inside the native editor until candidate confirmation. Unrelated SwiftUI refreshes cannot overwrite a composition, and confirming a candidate does not also submit a search. Old results and deferred focus changes are rejected while a new composition is in progress.

`NATIVE_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk bash native/test-input.sh` runs the opt-in input regression checks in a temporary GUI window. They exercise the actual AppKit field editor, marked ranges and queued keyboard events with fake search responses; they neither change the system input source nor contact devices or Apple search servers. Candidate confirmation is simulated, not an automated test of the operating system's candidate chooser.

The optional `NATIVE_QA=1` build includes internal view snapshot helpers:

```sh
NATIVE_QA=1 bash native/build.sh
'native/build/Parachute.app/Contents/MacOS/Parachute' \
  --preview --selected --snapshot /tmp/native-en.png -AppleLanguages '(en)'
```

An isolated map-only harness measured the previous `.onTapGesture` delay at approximately 502 ms after mouse-up. A simultaneous zero-distance drag completion, filtered to reject actual drags, removes the double-click arbitration wait (approximately 0.4–1.6 ms to the selection callback in the harness). Drag and double-click zoom were checked separately. These timings are callback latency, not a guarantee of tile-rendering time.

`--preview` suppresses device polling. QA snapshots can add `--small` or `--edit`. Normal builds exclude screenshot helpers and fixture UI state.

## Deferred

- Compatibility / migration of older privileged tunnel setups.
- True on-device location simulation and disconnect/reconnect validation, including network-only tunnel setup and simulation.
- See [release validation](release/README.md), [migration validation](migration/README.md), and [Sparkle validation](updater/README.md) for the exact signing, install and update checks and their remaining limits.

Local preview builds never initialize Sparkle. Production builds retain `com.electron.parachute`, use architecture-specific HTTPS feeds and signed updates, and include a small new AppKit relaunch helper required by the old updater. That helper has no Electron dependency. The initial native version is 0.4.0 with build number 400000. Historical 1.0.0 candidate results describe superseded preparation work, not a published release or verification of the current 0.4.0 artifacts. Do not route production users to 0.4.0 until published 0.3.9 and the explicit migration/release checks are in place.
