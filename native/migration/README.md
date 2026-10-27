# Electron to native macOS migration

The first native release is **1.0.0**. An internal **0.3.9 Electron bridge** carries existing users through the old updater without offering a macOS 14-only app to older systems. This directory prepares artifacts; it does not publish releases or modify installed applications.

## Release and feed contract

One GitHub Release, tagged `v1.0.0`, contains:

| Purpose | Assets |
| --- | --- |
| Native installation and Sparkle | `Parachute-native-arm64-1.0.0.zip`, `Parachute-native-x64-1.0.0.zip`, and the corresponding native PKGs |
| Existing Electron updater | `Parachute-darwin-arm64-0.3.9.zip`, `Parachute-darwin-x64-0.3.9.zip` |
| Optional compatibility installers | `Parachute-0.3.9-arm64.pkg`, `Parachute-0.3.9-x64.pkg` |

The public service takes its reported version from the **release tag**, and its download URL from the selected asset. It does not parse an asset's embedded version. Therefore a `v1.0.0` release can deliver the signed `0.3.9` bridge ZIP to an old `0.3.8` application. The bridge recognizes its own bundled version and stops using the public updater, so this version difference does not create an update loop.

Keep native ZIP names free of `-mac`, `-darwin`, and `-osx`. These patterns select assets for the old public updater. A dormant `0.3.8` installation must always receive the bridge first, even years after release. Preserve the bridge ZIPs in subsequent releases, or maintain equivalent routing that has been independently tested. Merely releasing a bridge before a conventionally named native ZIP does not protect clients that skip releases.

Generate two permanent first-native-update manifests:

```sh
python3 native/migration/generate-feeds.py PATH_TO_REVIEW_ARTIFACTS
```

After the signed native ZIPs have been verified and published, these files belong at:

- `https://raw.githubusercontent.com/Harrilee/parachute/main/updates/electron-migration-arm64.json`
- `https://raw.githubusercontent.com/Harrilee/parachute/main/updates/electron-migration-x64.json`

Both manifests stay pinned to **1.0.0**, including its original download URLs. Future native updates use Sparkle. Do not advance the bridge manifests to later native builds that may drop the migration helper, raise the minimum OS, or change architecture support.

The old service has no OS-version filter. The bridge checks the actual macOS version before consulting its native feed:

- macOS 14 or later, arm64/x64: download the native app with Electron's `serverType: 'json'` updater, then install and relaunch.
- Earlier macOS: open the existing Electron interface and do not offer the native package.
- Missing feed, network failure, or a 90-second timeout: open the existing interface. A late download does not trigger an immediate `quitAndInstall` after this fallback. Squirrel can still finish staging a download and apply it on a later normal quit; its macOS API has no cancellation method.

Device-client construction, administrator prompts, and tunnel startup are postponed until the legacy fallback is needed. The bridge's fallback removes the location lookup control, strips the location entitlement/usage strings, and denies browser permission requests. Native language selection follows macOS preferred/per-app languages. The earlier custom language choice remains in the untouched Electron profile; this migration does not parse Chromium LevelDB or rewrite Apple language preferences.

## Inspected published application

The actual [v0.3.8 ZIPs](https://github.com/Harrilee/parachute/releases/tag/v0.3.8), for both architectures, were downloaded and inspected rather than inferred from project defaults:

| Field | Observed value |
| --- | --- |
| ZIP root and executable | `Parachute.app`, `Contents/MacOS/Parachute` |
| Bundle identifier | `com.electron.parachute` |
| Name / display name | `Parachute` |
| Both bundle version fields | `0.3.8` |
| `LSMinimumSystemVersion` | `10.15` (the arm64 executable's Mach-O minimum is 11.0) |
| Architectures | Separate arm64 and x86_64 apps and go-ios executables |
| Publisher | `Developer ID Application: Haorui Li (YCP6FXQDL5)` |
| Notarization | Stapled ticket present |
| Electron framework | `32.1.2` |
| Bundled updater module | `update-electron-app` 3.3.0 |

The old designated requirement requires the identifier above, Apple's Developer ID certificate classes, and leaf certificate team `YCP6FXQDL5`. It does not pin a certificate serial number. The native app must satisfy that old requirement, not merely carry any valid signature. The archive and go-ios hashes are pinned in `provision-legacy-ios.sh`; the bridge uses the exact published go-ios executable without rebuilding or upgrading it.

## Why the native app includes a compatibility launcher

Electron 32.1.2 pins Squirrel.Mac at [`0e5d146ba13101a1302d59ea6e6e0b3cace4ae38`](https://github.com/electron/electron/blob/v32.1.2/DEPS), then applies [Electron-specific patches](https://github.com/electron/electron/tree/v32.1.2/patches/squirrel.mac). Its updater finds an application with the same bundle identifier, verifies the old designated requirement with strict nested-code and all-architecture validation, and replaces the bundle. Its patched macOS 11+ relaunch path uses `posix_spawn` to execute **the new file at its own former ShipIt path**. A plain native ZIP can therefore replace the app but fail to reopen it.

`build-launcher.sh` supplies that exact path:

```text
Parachute.app/Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt
```

This is a symlink to a small standalone AppKit executable in a correctly structured versioned framework. It accepts only `___launch___ <its-own-enclosing-app>`, verifies that app's bundle identifier, and asks Launch Services to open that exact application as a new instance. It implements no installation, shell execution, arbitrary-app launching, or device operations. It does not depend on Electron, Mantle, ReactiveObjC, or the old Squirrel code.

Build it before release signing:

```sh
bash native/migration/build-launcher.sh PATH_TO_APP arm64
# Use x64 for the Intel package.
```

Sign the complete `Squirrel.framework` with the same Developer ID identity before signing the outer app. Its `Resources/ShipIt` path resolves to the framework executable; signing only the outer app is insufficient. The framework layout, strict nested ad-hoc signing, rejection of an unrelated target, and actual creation of a second instance while the first is running have been checked with a harmless local fixture. Developer ID validation and actual Squirrel replacement/relaunch require the signed artifact tests below.

## Building the bridge

```sh
bash native/migration/stage-bridge.sh NEW_STAGING_DIRECTORY
bash native/migration/provision-legacy-ios.sh NEW_STAGING_DIRECTORY arm64
cd NEW_STAGING_DIRECTORY
npm ci
npm run make -- --arch=arm64 --targets=@electron-forge/maker-zip
```

Staging changes only the generated copy to version 0.3.9 and uses the committed bridge dependency lock. `npm ci` still runs Electron's required installation hook; the provisioned go-ios binary makes the project's postinstall skip rebuilding it. Set `LEGACY_APP_ARCHIVE` to a cached v0.3.8 ZIP to avoid downloading it again; both its archive hash and extracted binary hash are checked.

The shared CI signing setup supplies `APPLE_SIGN_ID`, `APPLE_INSTALLER_SIGN_ID`, `KEYCHAIN_PATH`, and the existing Apple notarization credentials. Forge signs/notarizes the app and makes the ZIP. `native/release/build-bridge-pkg.sh` builds its installer directly with a bounded `productbuild` invocation, preserving the bridge's minimum OS and architecture. The PKG requires a separate notarization submission and staple, as in the existing Electron release process. Collect the ZIP and PKG as review artifacts, never publish them from the build step.

Run the isolated bridge policy/event tests with:

```sh
node --test native/migration/bridge.test.cjs
```

## Isolated component tests

Run real signed-bundle replacement without launching any application main:

```sh
python3 native/migration/test-shipit.py \
  --legacy PATH_TO_PUBLISHED_0.3.8_ZIP \
  --report-directory NEW_REPORT_DIRECTORY \
  PATH_TO_SIGNED_0.3.9_BRIDGE_ZIP PATH_TO_SIGNED_1.0.0_NATIVE_ZIP
```

The script pins the initial archive's SHA-256, creates fresh copies under `/private/tmp`, and uses each currently installed Electron version's genuine ShipIt executable for the next replacement. Every request sets `launchAfterInstallation` to `false`. It verifies strict signatures, the previous app's designated requirement, a changed target inode, and the complete installed bundle's file/symlink hash. It preserves JSON evidence and ShipIt logs, then removes its temporary application copies and uniquely named test preference domains. It accepts no installed-app destination and never invokes the Electron or native application main.

The fixture itself passed locally against the published arm64 app (0.3.8 → 0.3.8). That baseline validates the harness protocol; the bridge/native chain must use the actual signed CI ZIPs. This component test bypasses HTTP routing, updater download/extraction, user approval, and automatic relaunch, and does not validate minimum-OS behavior.

Separately, in a macOS GUI session:

```sh
python3 native/migration/test-launcher.py
```

This compiles a harmless short-lived AppKit fixture, includes the production launcher, signs it ad hoc, and verifies strict nested signatures, unrelated-target rejection, and launching a new instance while one is already running. The fixture performs no network, location, or device operations. It is a launcher protocol test, not a claim that the shipping native app has relaunched successfully through Squirrel.

## Required isolated migration test

These checks are release gates, not claims of completed end-to-end testing:

1. Use disposable macOS VMs/accounts with no device/USB passthrough, no production app installation, and no production updater traffic. Test Apple Silicon and Intel; include macOS 14 and a supported pre-14 OS for the compatibility path.
2. Install an untouched signed published v0.3.8 app inside the disposable environment. Preserve its archive hash, designated requirement, architecture, installed path, and initial profile. Test normal and user-renamed bundle paths, writable user Applications and a normal `/Applications` install.
3. Redirect `update.electronjs.org` **inside that disposable environment only** to a controlled HTTPS test server, using a test CA trusted only there. Return the same response shape as the public service, pointing to the signed bridge artifact. Do not patch `app.asar`, re-sign the old app, edit host DNS/trust, or change the production release/feed. The old app hardcodes its feed and has ASAR integrity fuses, so a patched copy would not constitute this test.
4. Intercept the bridge's exact `raw.githubusercontent.com/.../updates/electron-migration-{arch}.json` request within that environment and serve the generated static manifest with isolated artifact URLs. Native ZIPs must have their production identity, signature, helper layout and minimum OS. Keep production endpoints blocked so a test cannot accidentally download a real release.
5. Exercise the old update approval/quit flow, then verify signed v0.3.8 → signed bridge → signed native replacement and relaunch. Record network requests and ShipIt logs, final on-disk hash/version, same installation path, helper exit status, and successful native launch. The old application may attempt its legacy administrator/tunnel startup; contain it wholly inside the disposable environment, with no phone or access to host services. The bridge's eligible path must make no such calls.
6. On pre-14 macOS, verify the bridge opens the compatible legacy app and never requests a native ZIP. Test offline/error/timeout paths. On supported macOS, verify corrupted ZIPs, wrong bundle IDs and wrong publisher signatures are rejected while the installed old app remains usable.
7. Separately test native 1.0.0 → a signed higher-build native fixture through an isolated Sparkle appcast. This does not substitute for the original Electron migration test.

Changing a disposable copy of the updater's feed or linking the old Squirrel framework into a test harness is useful additional component testing, but does not prove that an untouched published v0.3.8 app can complete this chain. Keep that distinction in CI/PR validation notes.

## Primary implementation evidence

- [Public service asset classifier](https://github.com/electron/update.electronjs.org/blob/9652cd82a680d695de6658524873b57843b631f7/src/asset-platform.ts): mac/darwin/osx ZIP names and architecture selection.
- [Public service release selection](https://github.com/electron/update.electronjs.org/blob/9652cd82a680d695de6658524873b57843b631f7/src/updates.ts): release-tag version, first matching asset, draft/prerelease exclusion, up to 100 releases, and no OS filter.
- [Old Squirrel bundle lookup/verification](https://github.com/Squirrel/Squirrel.Mac/blob/0e5d146ba13101a1302d59ea6e6e0b3cace4ae38/Squirrel/SQRLUpdater.m#L551-L592), [designated-requirement validation](https://github.com/Squirrel/Squirrel.Mac/blob/0e5d146ba13101a1302d59ea6e6e0b3cace4ae38/Squirrel/SQRLCodeSignature.m#L78-L127).
- [Old ShipIt replacement](https://github.com/Squirrel/Squirrel.Mac/blob/0e5d146ba13101a1302d59ea6e6e0b3cace4ae38/Squirrel/SQRLInstaller.m#L217-L313) and [same-path relaunch requirement](https://github.com/Squirrel/Squirrel.Mac/blob/0e5d146ba13101a1302d59ea6e6e0b3cace4ae38/Squirrel/ShipIt-main.m#L113-L154).
- Electron's applied patches for [strict nested signature validation](https://github.com/electron/electron/blob/v32.1.2/patches/squirrel.mac/fix_use_kseccschecknestedcode_kseccsstrictvalidate_in_the_sec.patch), [`posix_spawn` relaunch](https://github.com/electron/electron/blob/v32.1.2/patches/squirrel.mac/refactor_use_posix_spawn_instead_of_nstask_so_we_can_disclaim_the.patch), and [the final running-app guard](https://github.com/electron/electron/blob/v32.1.2/patches/squirrel.mac/fix_abort_installation_attempt_at_the_final_mile_if_the_app_is.patch). The guard matches both bundle identifier and exact target path, so a live app at a different path is not the test's replacement target.
