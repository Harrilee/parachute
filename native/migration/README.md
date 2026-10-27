# Electron to native macOS migration

Migration uses **two separate PRs and releases**: first publish the **0.3.9 Electron bridge**, then the **0.4.0 native app** (build **400000**). The bridge prevents the old updater from offering a macOS 14-only app to older systems. This native branch removes Electron source and build tooling. It consumes the bridge's reviewed artifacts and contains a small new native relaunch helper, migration tests and feed generation. Preparing those artifacts does not publish a release or change an installed application.

## Release and feed contract

| Release | Purpose | Assets |
| --- | --- | --- |
| `v0.3.9` | Existing Electron updater and legacy compatibility | `Parachute-darwin-arm64-0.3.9.zip`, `Parachute-darwin-x64-0.3.9.zip`; installers belong to that release's workflow |
| `v0.4.0` | Native installation and Sparkle | `Parachute-native-arm64-0.4.0.zip`, `Parachute-native-x64-0.4.0.zip`, and corresponding native PKGs |

The inspected public service scans the **first 100 GitHub releases**, skips drafts, prereleases and invalid semantic versions, and searches for matching platform/architecture assets. It can continue to older releases when a newer release has no matching asset. Its reported version comes from the selected release tag. Keep native ZIP names free of the service's `mac`, `darwin` and `osx` patterns: `Parachute-native-...` ZIPs are skipped, allowing an old 0.3.8 client to find the prior stable 0.3.9 bridge release. **Do not copy bridge ZIPs into 0.4.0 or every later native release.** The bridge stops using the public updater and consults its pinned native migration feed instead.

This routing has a finite history limit, not an indefinite compatibility guarantee. Keep the signed 0.3.9 release/assets available, monitor the public feed for both architectures and the release's position within the service's first 100 results. Before 0.3.9 falls outside that window, establish and test a stable legacy routing endpoint or equivalent compatibility routing that existing clients can actually reach. A new endpoint alone cannot redirect an untouched 0.3.8 app's hardcoded URL. Recheck the upstream selection rules before relying on future release behavior.

Generate two permanent first-native-update manifests:

```sh
python3 native/migration/generate-feeds.py PATH_TO_REVIEW_ARTIFACTS
```

The checked-in `updates/electron-migration-*.json` files remain no-update placeholders (`{"currentRelease":"0.3.9","releases":[]}`) through the native PR merge. Generating candidate manifests writes review artifacts; it does not activate migration. Only after the signed 0.4.0 native ZIPs have been verified and published should the placeholders be replaced through a reviewed feed update at:

- `https://raw.githubusercontent.com/Harrilee/parachute/main/updates/electron-migration-arm64.json`
- `https://raw.githubusercontent.com/Harrilee/parachute/main/updates/electron-migration-x64.json`

Both manifests stay pinned to **0.4.0** and its original `v0.4.0/Parachute-native-{arch}-0.4.0.zip` URLs. Future native updates use Sparkle. Do not advance the bridge manifests to later native builds that may drop the migration helper, raise the minimum OS, or change architecture support.

The old service has no OS-version filter. The 0.3.9 bridge registers its device IPC handlers, opens its existing interface, and starts background migration checks independently of the legacy administrator-access check. Cancelling that authorization leaves the bridge window and updater available. Device and tunnel operations retain their existing authorization requirements.

- macOS 14 or later, arm64/x64: make an abortable manifest preflight with a 10-second deadline. Only a manifest naming native 0.4.0 and its exact architecture-specific GitHub asset URL starts Electron's `serverType: 'json'` updater. The deadline covers the manifest preflight, not the native ZIP download.
- Earlier macOS or an unsupported architecture: keep the legacy interface and do not request a native migration feed or ZIP.
- HTTP 404/204, an empty body, or the 0.3.9 no-update placeholder: leave the working interface unchanged without a migration dialog. Network, malformed-feed and other HTTP failures are logged without blocking the interface.
- Retry eligible checks every 10 minutes. Do not overlap a pending preflight or updater check/download. Stop checking once a download is ready or the application quits.
- When the native download is ready, ask the user to **Restart and update** or **Later**, with **Later** selected by default. Only explicit restart approval calls `quitAndInstall`; restarting ends the current location simulation session. Choosing Later keeps the interface running, but Squirrel installs the staged update on the next normal quit. Its macOS API cannot cancel an update already in progress.

This keeps 0.3.9 usable before the separate native release is available. The bridge's existing interface removes the location lookup control, strips location entitlement/usage strings, and denies browser permission requests. Native language selection follows macOS preferred/per-app languages; the bridge restart prompt uses the system language. The earlier custom language choice remains in the untouched Electron profile. Migration does not parse Chromium LevelDB or rewrite Apple language preferences. The separate 0.3.9 PR/release and Git history retain the old implementation for compatibility and rollback review; this native branch has no Electron build entry point.

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

The old designated requirement requires the identifier above, Apple's Developer ID certificate classes, and leaf certificate team `YCP6FXQDL5`. It does not pin a certificate serial number. The native app must satisfy that old requirement, not merely carry any valid signature. The component harness pins the published archive hashes. The separate Electron 0.3.9 PR provisions the exact published go-ios executable without rebuilding or upgrading it; that provisioning and the Electron build pipeline are not retained in this native branch.

## Why the native app includes a compatibility launcher

Electron 32.1.2 pins Squirrel.Mac at [`0e5d146ba13101a1302d59ea6e6e0b3cace4ae38`](https://github.com/electron/electron/blob/v32.1.2/DEPS), then applies [Electron-specific patches](https://github.com/electron/electron/tree/v32.1.2/patches/squirrel.mac). Its updater finds an application with the same bundle identifier, verifies the old designated requirement with strict nested-code and all-architecture validation, and replaces the bundle. Its patched macOS 11+ relaunch path uses `posix_spawn` to execute **the new file at its own former ShipIt path**. A plain native ZIP can therefore replace the app but fail to reopen it.

`build-launcher.sh` supplies that exact path:

```text
Parachute.app/Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt
```

This is a symlink to a small standalone AppKit executable in a correctly structured versioned framework. It accepts only `___launch___ <its-own-enclosing-app>`, verifies that app's bundle identifier, and asks Launch Services to open that exact application as a new instance. It implements no installation, shell execution, arbitrary-app launching, or device operations. This is new native compatibility code, not retained Electron source. It does not depend on Electron, Mantle, ReactiveObjC, or the old Squirrel code.

Build it before release signing:

```sh
bash native/migration/build-launcher.sh PATH_TO_APP arm64
# Use x64 for the Intel package.
```

Sign the complete `Squirrel.framework` with the same Developer ID identity before signing the outer app. Its `Resources/ShipIt` path resolves to the framework executable; signing only the outer app is insufficient. The framework layout, strict nested ad-hoc signing, rejection of an unrelated target, and actual creation of a second instance while the first is running have been checked with a harmless local fixture. Developer ID validation and actual Squirrel replacement/relaunch require the signed artifact tests below.

## Obtain the separate 0.3.9 bridge

The Electron 0.3.9 bridge is implemented, built and reviewed in the first PR. This native-only branch consumes its signed artifacts; it does not stage an Electron checkout or run npm/Forge. It retains the new AppKit relaunch helper because the old updater requires its path after replacing the app.

For prepublication PR validation, dispatch the native workflow with both `bridge_run_id` and `bridge_commit`. The latter is the approved exact 40-character commit. The resolver accepts a successful completed manual `.github/workflows/release.yml` run in `Harrilee/parachute`, from `feat/harrli/electron-transition-0.3.9` or `main`, with that exact source commit. It downloads `electron-bridge-macos-{arm64,x64}-0.3.9` and verifies the archive hashes and identity/version/run/commit in each `bridge-{arch}-manifest.json`. Evidence marks this source `releaseEligible=false`: a passing component test with CI bridge artifacts does not satisfy the published-0.3.9 prerequisite.

For release validation, omit both CI-source inputs. The resolver then requires a stable published `v0.3.9` and a reviewed `native/release/bridge-release-pins.json`, containing version, exact source commit, and both architecture archive hashes. That file is deliberately absent until the 0.3.9 release can be inspected and pinned. `releaseEligible=true` establishes the bridge's published source; complete migration and native release gates still apply.

## Isolated component tests

Run real signed-bundle replacement without launching any application main:

```sh
python3 native/migration/test-shipit.py \
  --legacy PATH_TO_PUBLISHED_0.3.8_ZIP \
  --report-directory NEW_REPORT_DIRECTORY \
  PATH_TO_SIGNED_0.3.9_BRIDGE_ZIP PATH_TO_SIGNED_0.4.0_NATIVE_ZIP
```

The script pins the initial archive's SHA-256, creates fresh copies under `/private/tmp`, and uses each currently installed Electron version's genuine ShipIt executable for the next replacement. Every request sets `launchAfterInstallation` to `false`. It verifies strict signatures, the previous app's designated requirement, a changed target inode, and the complete installed bundle's file/symlink hash. It preserves JSON evidence and ShipIt logs, then removes its temporary application copies and uniquely named test preference domains. It accepts no installed-app destination and never invokes the Electron or native application main.

The fixture itself passed locally against the published arm64 app (0.3.8 → 0.3.8). That baseline validates the harness protocol; the 0.3.9 → 0.4.0 chain must use the exact new signed artifacts. Earlier signed CI/component evidence for a prepared 1.0.0 candidate is superseded preparation evidence, not a published release or proof that the current 0.4.0 chain passed. This component test bypasses HTTP routing, updater download/extraction, user approval, and automatic relaunch, and does not validate minimum-OS behavior.

Separately, in a macOS GUI session:

```sh
python3 native/migration/test-launcher.py
```

This compiles a harmless short-lived AppKit fixture, includes the production launcher, signs it ad hoc, and verifies strict nested signatures, unrelated-target rejection, and launching a new instance while one is already running. The fixture performs no network, location, or device operations. It is a launcher protocol test, not a claim that the shipping native app has relaunched successfully through Squirrel.

## Required isolated migration test

The untouched published Electron app’s complete download/approval/replacement/relaunch chain remains unverified. These checks are release gates, not claims of completed end-to-end testing:

1. Use disposable macOS VMs/accounts with no device/USB passthrough, no production app installation, and no production updater traffic. Test Apple Silicon and Intel; include macOS 14 and a supported pre-14 OS for the compatibility path.
2. Install an untouched signed published v0.3.8 app inside the disposable environment. Preserve its archive hash, designated requirement, architecture, installed path, and initial profile. Test normal and user-renamed bundle paths, writable user Applications and a normal `/Applications` install.
3. Redirect `update.electronjs.org` **inside that disposable environment only** to a controlled HTTPS test server, using a test CA trusted only there. Return the same response shape as the public service, pointing to the signed bridge artifact. Do not patch `app.asar`, re-sign the old app, edit host DNS/trust, or change the production release/feed. The old app hardcodes its feed and has ASAR integrity fuses, so a patched copy would not constitute this test.
4. Intercept the bridge's exact `raw.githubusercontent.com/.../updates/electron-migration-{arch}.json` request within that environment and serve the generated static manifest with isolated artifact URLs. Native ZIPs must have their production identity, signature, helper layout and minimum OS. Keep production endpoints blocked so a test cannot accidentally download a real release.
5. Exercise the old update approval/quit flow, then verify signed v0.3.8 → signed bridge → signed native replacement and relaunch. Record network requests and ShipIt logs, final on-disk hash/version, same installation path, helper exit status, and successful native launch. The original app and the 0.3.9 bridge may request legacy device authorization; contain those calls wholly inside the disposable environment, with no phone or access to host services. Verify that cancelling authorization in the bridge does not prevent its window or update checks, download completion offers Restart/Later, and only explicit approval causes immediate restart.
6. On pre-14 macOS, verify the bridge opens the compatible legacy app and never requests a native ZIP. Test the checked-in no-update placeholder, missing feed, offline/error and preflight-timeout paths without delaying the bridge interface. Verify retry/non-overlap and choosing Later, including the documented installation on a later normal quit. On supported macOS, verify corrupted ZIPs, wrong bundle IDs and wrong publisher signatures are rejected while the installed old app remains usable.
7. Separately test native 0.4.0 (build 400000) → a signed higher-build native fixture through an isolated Sparkle appcast. This does not substitute for the original Electron migration test.

Changing a disposable copy of the updater's feed or linking the old Squirrel framework into a test harness is useful additional component testing, but does not prove that an untouched published v0.3.8 app can complete this chain. Keep that distinction in CI/PR validation notes.

## Primary implementation evidence

- [Public service asset classifier](https://github.com/electron/update.electronjs.org/blob/9652cd82a680d695de6658524873b57843b631f7/src/asset-platform.ts): mac/darwin/osx ZIP names and architecture selection.
- [Public service release selection](https://github.com/electron/update.electronjs.org/blob/9652cd82a680d695de6658524873b57843b631f7/src/updates.ts): release-tag version, first matching asset, draft/prerelease exclusion, up to 100 releases, and no OS filter.
- [Old Squirrel bundle lookup/verification](https://github.com/Squirrel/Squirrel.Mac/blob/0e5d146ba13101a1302d59ea6e6e0b3cace4ae38/Squirrel/SQRLUpdater.m#L551-L592), [designated-requirement validation](https://github.com/Squirrel/Squirrel.Mac/blob/0e5d146ba13101a1302d59ea6e6e0b3cace4ae38/Squirrel/SQRLCodeSignature.m#L78-L127).
- [Old ShipIt replacement](https://github.com/Squirrel/Squirrel.Mac/blob/0e5d146ba13101a1302d59ea6e6e0b3cace4ae38/Squirrel/SQRLInstaller.m#L217-L313) and [same-path relaunch requirement](https://github.com/Squirrel/Squirrel.Mac/blob/0e5d146ba13101a1302d59ea6e6e0b3cace4ae38/Squirrel/ShipIt-main.m#L113-L154).
- Electron's applied patches for [strict nested signature validation](https://github.com/electron/electron/blob/v32.1.2/patches/squirrel.mac/fix_use_kseccschecknestedcode_kseccsstrictvalidate_in_the_sec.patch), [`posix_spawn` relaunch](https://github.com/electron/electron/blob/v32.1.2/patches/squirrel.mac/refactor_use_posix_spawn_instead_of_nstask_so_we_can_disclaim_the.patch), and [the final running-app guard](https://github.com/electron/electron/blob/v32.1.2/patches/squirrel.mac/fix_abort_installation_attempt_at_the_final_mile_if_the_app_is.patch). The guard matches both bundle identifier and exact target path, so a live app at a different path is not the test's replacement target.
