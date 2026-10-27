# Native release preparation

Native 1.0.0 (build 1000000) requires the **Electron 0.3.9 transition release to be published first**. Its [merged implementation](https://github.com/Harrilee/parachute/tree/b8d4ddf66153c6508bb0ba85b7ff5548ed4ebf05) and [transition release procedure](https://github.com/Harrilee/parachute/blob/b8d4ddf66153c6508bb0ba85b7ff5548ed4ebf05/docs/electron-transition.md) remain available at that source revision; this tree no longer builds Electron.

The manually dispatched `.github/workflows/release.yml` builds native Apple Silicon and Intel artifacts and runs migration component tests. It does not create tags, publish releases or change public feeds. Native jobs use macOS 26/Xcode 26.2 for layered icons; migration jobs use macOS 15. The application requires macOS 14 and retains bundle identity `com.electron.parachute` and Developer ID team `YCP6FXQDL5`.

## Artifacts and routing

Each architecture produces `Parachute-native-{arm64,x64}-1.0.0.zip` and `.pkg`, signed appcast XML, checksums, helper provenance, icon-validation evidence and notarization logs. The ZIP contains a root `Parachute.app`; the Installer-signed PKG installs into `/Applications`.

Keep native names free of the old updater's `mac`, `darwin` and `osx` patterns. The separate 0.3.9 release supplies the bridge ZIPs; they are not copied into each native release. The public service's first-100-release limit requires monitoring and future routing maintenance, as described in [migration routing](../migration/README.md#release-and-feed-contract).

The two `updates/electron-migration-*.json` files remain no-update placeholders until the first native assets are published, then stay pinned to 1.0.0. Only `updates/appcast-*.xml` advances for subsequent native releases. Generated feeds are review artifacts until explicitly published.

## Bridge source for CI

Dispatch with `version=1.0.0` and `build_number=1000000`. Bridge sources have two modes:

- **Before bridge publication:** provide both `bridge_run_id` and `bridge_commit`, the approved exact 40-character commit. The resolver requires a successful completed manual `.github/workflows/release.yml` run in `Harrilee/parachute`, from `feat/harrli/electron-transition-0.3.9` or `main`, with that commit and the same head repository. It downloads `electron-bridge-macos-{arm64,x64}-0.3.9` and verifies each `bridge-{arch}-manifest.json` for hashes, identity/version, commit and run. Evidence is marked `releaseEligible=false`; passing tests cannot replace the published-0.3.9 prerequisite.
- **For release preparation:** omit both inputs. The resolver requires stable published `v0.3.9` and reviewed `native/release/bridge-release-pins.json`, with `version`, `sourceCommit`, and `archives.{arm64,x64}.sha256`. It verifies the tag commit and archive hashes, then records `releaseEligible=true`. The pins file stays absent until the published release is inspected. All native publication gates still apply.

The workflow consumes these signed artifacts without an Electron checkout, npm or Forge. Its two native package jobs and two migration jobs retain their evidence independently.

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

The untouched published Electron application's complete migration, older-macOS execution, production-signed native Sparkle upgrades and physical-device operation remain unverified publication gates. Follow the [isolated migration procedure](../migration/README.md#required-isolated-migration-test) and [Sparkle test boundaries](../updater/README.md#verification-boundaries). Successful fixtures do not substitute for those tests, and a CI bridge source remains ineligible for release.

## Explicit publication procedure

1. Validate and publish signed `v0.3.9` using the [merged transition source and procedure](https://github.com/Harrilee/parachute/blob/b8d4ddf66153c6508bb0ba85b7ff5548ed4ebf05/docs/electron-transition.md). Its no-update feed keeps the interface usable before native 1.0.0 is available.
2. Inspect that release and add its reviewed archive hashes/tag commit to `bridge-release-pins.json`. Select the reviewed native release commit and dispatch `release.yml` with version `1.0.0`, build `1000000`, and no CI bridge-source overrides. Require both package and both migration jobs to pass with `releaseEligible=true`.
3. Complete the remaining isolated migration, unsupported-OS, signed native update and physical-device checks. Use the exact intended artifacts; retain hashes and evidence. Do not use production update feeds or user installations for upgrade testing.
4. Review both native artifact bundles: checksums, source commit, architecture, minimum OS, signature, notarization and installation evidence. Preserve appcasts byte-for-byte. Explicitly create tag `v1.0.0` at the tested commit and a draft release containing native ZIPs, PKGs and checksums, with notes explaining macOS 14 and the 0.3.9 compatibility path.
5. Publish the reviewed release and verify final asset URLs. Then copy generated migration JSON and signed appcast XML into `updates/` on `main` through a reviewed commit. Do not edit signed XML. Until the feeds are live, the bridge retains its existing interface.
6. Verify the public legacy feed selects 0.3.9 for both architectures, and verify all four native feed URLs/downloads. Preserve the original bridge and 1.0.0 native assets and monitor the public service's first-100-release window.

Future native releases increase both version and numeric build, update Sparkle feeds and preserve compatible older feed items when raising requirements. Migration JSON stays pinned to 1.0.0. Before publication, rollback means discarding artifacts. After publication, withdrawing an appcast item stops new offers but cannot downgrade installed higher builds. Keep signed legacy packages for explicit reinstall; never rewrite release tags or signed artifacts in place.
