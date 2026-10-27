# Native release preparation

Native 1.0.0 (build 1000000) requires the **Electron 0.3.9 transition release to be published first**. Its [merged implementation](https://github.com/Harrilee/parachute/tree/b8d4ddf66153c6508bb0ba85b7ff5548ed4ebf05) remains available for historical reference; this tree neither builds nor publishes Electron.

The manually dispatched `.github/workflows/release.yml` builds native Apple Silicon and Intel artifacts and runs migration component tests. It does not publish them. The separate [native-only publisher](../../.github/workflows/publish.yml) validates a successful run, creates a GitHub Release draft or publishes an existing draft. Neither workflow changes public update feeds. Native jobs use macOS 26/Xcode 26.2 for layered icons; migration jobs use macOS 15. The application requires macOS 14 and retains bundle identity `com.electron.parachute` and Developer ID team `YCP6FXQDL5`.

## Artifacts and routing

Each architecture produces `Parachute-native-{arm64,x64}-1.0.0.zip` and `.pkg`, signed appcast XML, checksums, helper provenance, icon-validation evidence and notarization logs. The ZIP contains a root `Parachute.app`; the Installer-signed PKG installs into `/Applications`.

Keep native names free of the old updater's `mac`, `darwin` and `osx` patterns. The separate 0.3.9 release supplies the bridge ZIPs; they are not copied into each native release. The public service's first-100-release limit requires monitoring and future routing maintenance, as described in [migration routing](../migration/README.md#release-and-feed-contract).

The two `updates/electron-migration-*.json` files remain no-update placeholders until the first native assets are published, then stay pinned to 1.0.0. Only `updates/appcast-*.xml` advances for subsequent native releases. Generated feeds are review artifacts until explicitly published.

## Bridge source for CI

Every native build requires stable published `v0.3.9` and the reviewed `native/release/bridge-release-pins.json`, containing `version`, `sourceCommit`, and `archives.{arm64,x64}.sha256`. The resolver verifies the tag commit, archive hashes, bundle identifier and version. It records the published source in `bridge-source.json` with `source=published-release` and `releaseEligible=true`. There is no CI-artifact override for the bridge.

The workflow downloads these signed bridge ZIPs without an Electron checkout, npm or Forge. Its two native package jobs and two migration jobs retain evidence independently. Missing publication or pins fails the build; it does not select an unreviewed substitute.

## Build contract

`build-go-ios.sh <arm64|x86_64> <output>` builds the pinned source, compiler and dependency manifest with the single acknowledgement patch. The application builder calls it directly when no helper is supplied. See [go-ios provenance and caching](../go-ios/README.md).

`native/build.sh` accepts `NATIVE_RELEASE=1`, `NATIVE_ARCH`, `NATIVE_GO_IOS_BINARY`, `NATIVE_GO_IOS_BUILD_INFO`, `SPARKLE_FRAMEWORK_PATH`, `RELEASE_VERSION`, `BUILD_NUMBER`, `BUNDLE_ID`, `SPARKLE_PUBLIC_KEY`, `SPARKLE_FEED_URL`, `RELEASE_TEAM_ID` and optional `NATIVE_ICON_REPORT`. CI retains icon evidence from the actual application build. Add the [native migration launcher](../migration/README.md#why-the-native-app-includes-a-compatibility-launcher) before release signing.

`package.sh <app> <output> [phase]` signs, notarizes and packages that complete app. Phases are `sign`, `notarize-app`, `build-pkg`, and `notarize-pkg`; omitting the phase runs all. `package.sh component <app> <output.pkg> <bundle-id> <version>` exposes the unsigned component builder for tests. Package metadata disables relocation so Installer cannot select a matching app in Downloads or a build directory.

`process.py` provides `run`, `staple` and `validate`. Signing and `productbuild` have a 10-minute deadline; timeout cleanup targets only the owned process group. Notarization waits at most 30 minutes, recording the submission ID before waiting and retaining result/log JSON. Stapling and ticket validation retry at most three times only for exit 68 with a transient `NSURLErrorDomain` network error, with 120-second attempts and 5/15-second backoffs. Invalid signatures, tickets and trust errors fail immediately; exhausted retries fail the job.

`sign-app.sh` signs Sparkle's nested code in its documented order, preserving Downloader XPC entitlements, then signs the helper, migration launcher and app. It does not use Electron JIT entitlements or `codesign --deep` for signing. `verify-artifacts.sh` checks the final ZIP's identity, version, architecture, publisher, ticket and Gatekeeper acceptance. `CI_INSTALL_TEST=1` also installs the PKG on the disposable runner and verifies `/Applications/Parachute.app` without launching it or touching devices.

`python3 native/Tests/ReleaseToolsTests.py` covers process cleanup, retry policy, fixed-destination package metadata and bridge provenance. Local fixtures neither install a package nor contact Apple notarization.

## Credentials

The workflow imports `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_INSTALLER_CERTIFICATE` and `APPLE_INSTALLER_CERTIFICATE_PASSWORD` into an ephemeral keychain. It resolves the two signing identities for `APPLE_TEAM_ID`, stores notarytool credentials from `APPLE_ID` / `APPLE_PASSWORD`, and removes the keychain in an always-run cleanup step. Noninteractive access is limited to that disposable keychain, including certificates sharing a private key. Actual signing and notarization must succeed; Secret names alone do not establish validity.

Sparkle reads `SPARKLE_PRIVATE_KEY` through standard input and checks against `native/updater/public-key.txt`. Never put the private key in repository files, artifact directories, command arguments or logs. See [Sparkle key management](../updater/README.md#signing-keys).

## Validation boundaries

Associate all results with the exact source commit and artifact hashes. Native package checks do not establish an Electron or Sparkle upgrade. The migration matrix uses genuine Squirrel replacement on temporary copies (`0.3.8` → `0.3.9` → `1.0.0`) with `launchAfterInstallation=false`; it bypasses HTTP, approval and automatic relaunch. The separate launcher and Sparkle fixtures verify their protocols with harmless test apps.

The untouched published Electron application's complete migration, older-macOS execution, production-signed native Sparkle upgrades and physical-device operation remain unverified publication gates. Follow the [isolated migration procedure](../migration/README.md#required-isolated-migration-test) and [Sparkle test boundaries](../updater/README.md#verification-boundaries). Successful fixtures do not substitute for those tests. The publisher validates CI evidence and provenance; it does not perform these remaining manual checks.

## Explicit publication procedure

1. Confirm stable `v0.3.9` is published and its tag commit/archive hashes match `bridge-release-pins.json`. Keep the migration feeds at their no-update values until native 1.0.0 assets are ready.
2. Build the reviewed native revision and require all four jobs to succeed:

   ```sh
   gh workflow run release.yml --ref <release-ref> -f version=1.0.0 -f build_number=1000000
   ```

3. Dispatch the native publisher against the successful native run and its exact 40-character source commit:

   ```sh
   gh workflow run publish.yml --ref main -f action=draft \
     -f source_run_id=<successful-native-run-id> \
     -f source_commit=<40-character-commit> -f version=1.0.0
   ```

   `action=validate` performs the same artifact checks without changing a tag or Release. `action=draft` creates the `v1.0.0` Release draft targeting that source commit and uploads existing signed ZIPs/PKGs, checksums/manifests and unchanged feed artifacts. It does not rebuild, re-sign or regenerate feeds. GitHub manages when the associated tag is created; an existing tag must resolve to the supplied commit.
4. Review the draft, asset hashes and release notes, including the macOS 14 minimum and 0.3.9 compatibility path. Complete the remaining isolated migration, unsupported-OS, signed native update and physical-device checks using those exact artifacts. Do not use production update feeds or user installations for upgrade testing. Draft creation does not establish that these manual checks passed. Repeat the command with `action=publish` and identical source/version inputs to promote the reviewed draft. The source commit must be on `main`, and both migration reports must identify the published bridge with `releaseEligible=true`. An existing draft must match the same provenance; existing assets are verified rather than overwritten, and already-published releases are not rewritten.
5. Verify all public asset URLs. Then copy the unchanged migration JSON and signed appcast XML from the reviewed release artifacts into `updates/` on `main` in a reviewed commit. The publisher only attaches these feeds to the Release; it does not activate them. Never edit signed XML. Until this commit, the bridge retains its existing interface.
6. Verify the public legacy feed selects 0.3.9 for both architectures, and verify all four native feed URLs/downloads. Preserve the original bridge and 1.0.0 native assets and monitor the public service's first-100-release window.

Run `publish.yml` from a revision containing the reviewed native publisher; `--ref main` assumes that workflow has merged. `source_run_id` refers to the native build workflow, not the publisher run or the old Electron build. `source_commit` must match the successful build exactly. The publisher is for native assets only.

Future native releases increase both version and numeric build, update Sparkle feeds and preserve compatible older feed items when raising requirements. Migration JSON stays pinned to 1.0.0. Before publication, rollback means discarding artifacts. After publication, withdrawing an appcast item stops new offers but cannot downgrade installed higher builds. Keep signed legacy packages for explicit reinstall; never rewrite release tags or signed artifacts in place.
