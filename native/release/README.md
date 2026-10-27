# Native release preparation

The release plan uses two separate PRs and releases: **Electron 0.3.9 first, native 1.0.0 second**. This branch contains only the native macOS application and its tooling. It does not stage, build or package Electron; the 0.3.9 PR owns the bridge and legacy release path.

The `Native macOS release artifacts` workflow is manually dispatched or called by the native `release.yml` wrapper. It builds Apple Silicon and Intel applications and runs migration component jobs using independently obtained bridge artifacts. All outputs remain Actions artifacts. It does **not** create a release, push a tag, or change a public update feed.

The initial native version is `1.0.0`, with build number `1000000`. Both architectures retain the published Electron identity `com.electron.parachute`, use the existing Developer ID team, and require macOS 14.0 or newer. Build numbers must increase for each published Sparkle update. Native jobs use macOS 26 and Xcode 26.2 for the layered icon compiler and availability-guarded glass UI; the application deployment target remains macOS 14. Migration component jobs use disposable macOS 15 runners.

## Artifacts and routing

Each native architecture produces:

- `Parachute-native-{arm64,x64}-1.0.0.zip`: a root `Parachute.app`, with signed nested code and main bundle and a stapled notarization ticket.
- `Parachute-native-{arm64,x64}-1.0.0.pkg`: a Developer ID Installer-signed, notarized package installing to `/Applications`, with macOS and architecture requirements.
- An architecture-specific signed Sparkle appcast, checksums, go-ios provenance, and Apple notarization result/log JSON.

The separate stable `v0.3.9` release supplies `Parachute-darwin-{arm64,x64}-0.3.9.zip`. Do not copy these ZIPs into `v1.0.0` or every subsequent native release. Native asset names deliberately omit `darwin`, `mac`, and `osx`, so the inspected public Electron updater skips them and can find the prior 0.3.9 bridge. That service scans at most the first 100 releases. Monitor the old feed and 0.3.9's position, and establish tested durable legacy routing before it falls outside that window. Keeping an old release available alone does not guarantee indefinite discovery. See [migration routing](../migration/README.md).

The app embeds `https://raw.githubusercontent.com/Harrilee/parachute/main/updates/appcast-{arm64,x64}.xml`. Generated feeds reference the planned `v1.0.0` native assets; generation does not publish a release or make its URLs live. The two Electron migration JSON feeds stay pinned to the original native 1.0.0 ZIPs, while Sparkle feeds advance for later native builds. Publish reviewed assets before their production feeds.

## Bridge source for CI

Two modes allow the native PR to be validated before the prerequisite release exists, while keeping that distinct from release readiness:

- **PR preparation:** provide both `bridge_run_id` and `bridge_commit` (the approved exact 40-character source commit). The resolver requires a successful completed `workflow_dispatch` run of `.github/workflows/release.yml` in `Harrilee/parachute`, from `feat/harrli/electron-transition-0.3.9` or `main`, with the supplied commit and the same head repository. It downloads `electron-bridge-macos-{arm64,x64}-0.3.9` and checks each `bridge-{arch}-manifest.json` for hashes, bundle identity/version, source commit and run. Source evidence has `releaseEligible=false`; successful tests do not authorize native publication.
- **Release preparation:** omit both inputs. The resolver requires stable published `v0.3.9` plus the reviewed `native/release/bridge-release-pins.json`, with `version`, `sourceCommit`, and `archives.{arm64,x64}.sha256`. It checks the release's exact tag commit and archive hashes. This file is intentionally absent until the published 0.3.9 release has been reviewed. Source evidence then has `releaseEligible=true`; the complete migration and current native verification gates remain required.

The native workflow generates its own pinned migration feeds. It never uses downloaded artifacts as instructions or needs an Electron source checkout, npm, or Forge. Its two native package jobs and two migration component jobs are separate from the first PR's Electron builds.

## Build contract

`build-go-ios.sh <arm64|x86_64> <output>` builds the existing pinned fork commit
`80ed9e1cb2c9dfd8af38efff54e0feaad6fe742b` (`v1.0.204`) with Go 1.24.4 and the
single success-acknowledgement patch. Fresh CI may download locked dependencies;
`-mod=readonly`, unchanged module/workspace-file checks, and an exact comparison
with `go-ios-dependencies.txt` reject dependency drift. This manifest contains the
26 embedded module records from the historically inspected local Electron `bin/ios` (SHA-256
`0d5d80df01f77b9c0532d6e95530ed07f7915159b0d363089038798ce8c80798`).
That binary is a comparison baseline, not a required input retained on this branch.
The preview wrapper uses the same builder and verified cache. The original binary
does not identify its source commit; the pinned ref came from the prior build
configuration, not independently recovered binary provenance.

`native/build.sh` accepts `NATIVE_RELEASE=1`, `NATIVE_ARCH`,
`NATIVE_GO_IOS_BINARY`, `NATIVE_GO_IOS_BUILD_INFO`, `SPARKLE_FRAMEWORK_PATH`,
`RELEASE_VERSION`, `BUILD_NUMBER`, `BUNDLE_ID`, `SPARKLE_PUBLIC_KEY`,
`SPARKLE_FEED_URL`, and `RELEASE_TEAM_ID`. The migration launcher is staged next.
`package.sh <app> <output>` then signs, notarizes and packages that complete app.
Its optional third argument selects `sign`, `notarize-app`, `build-pkg`, or
`notarize-pkg`; omitting it runs all phases. CI uses separate steps so API-visible
job status distinguishes signing, Apple notarization, and installer construction.
The native installer explicitly disables bundle relocation in its component metadata
and installs into `/Applications`. This prevents Installer from selecting a
matching app in Downloads or a temporary build directory. An unsigned fixture
test inspects the generated package metadata and payload without installing it.
Component construction and notarization are named functions in `package.sh`;
`package.sh component <app> <output.pkg> <bundle-id> <version>` exposes the unsigned
component builder for that test. `process.py` provides the `run`, `staple`, and
`validate` subcommands used by packaging and verification.

`python3 native/Tests/ReleaseToolsTests.py` runs the 16 release-tool checks in one
suite: process cleanup, network retry behavior, fixed-destination package metadata,
and bridge artifact provenance. The real signed package installation in CI checks
installer-key access; no separate signing-probe package is created.

Signing and `productbuild` run under a 10-minute process timeout. A timeout logs
only the owned process group's names/state (not arguments or environment), then
terminates only that group. The helper's tests cover success output, nonzero
exits, child cleanup and preservation of an unrelated process. Apple notarization
has a separate 30-minute wait limit. Submission IDs are written before waiting,
and result/log JSON plus packaging logs are uploaded even after a job failure.
Ticket stapling and validation retry up to three times only when `stapler`
returns 68 with an explicit transient `NSURLErrorDomain` network error. Each
attempt has a 120-second deadline, with 5- and 15-second backoffs. Invalid
signatures, invalid tickets and certificate-trust errors fail immediately;
exhausted network retries still fail the job. The retry tests never contact Apple.

`sign-app.sh` signs Sparkle inside out in the framework's documented order,
retains any Downloader XPC entitlements, and signs the go-ios executable,
migration launcher, and main app. It does not copy Electron JIT entitlements or
use `codesign --deep` for signing. Deep verification is appropriate afterward.

`verify-artifacts.sh` extracts the final ZIP, checks its bundle identity, version,
architecture, signing team, notarization ticket and Gatekeeper acceptance. With
`CI_INSTALL_TEST=1` it also installs the PKG on the disposable GitHub runner and
checks `/Applications/Parachute.app`. It does not launch the app or alter a phone.

## Credentials

The workflow imports the existing `APPLE_CERTIFICATE`,
`APPLE_CERTIFICATE_PASSWORD`, `APPLE_INSTALLER_CERTIFICATE`, and
`APPLE_INSTALLER_CERTIFICATE_PASSWORD` into an ephemeral keychain. It resolves
the two signing identities for `APPLE_TEAM_ID`, stores notarytool credentials
from `APPLE_ID` / `APPLE_PASSWORD`, and deletes the keychain in an always-run
cleanup step. Successful signing and notarization are required; the existence of
a Secret is not treated as validation of its contents.
Both imported keys retain the access policy used by the previous successful CI
workflow so Apple's packaging helpers can sign without an interactive keychain
prompt, including when the two certificates share a private key. This policy
applies only inside the disposable signing keychain.

Sparkle reads `SPARKLE_PRIVATE_KEY` through standard input. Its public counterpart
is checked in at `native/updater/public-key.txt`. Private key material must never
be written into the repository, artifact directory, command-line arguments, or
logs.

## Validation boundaries

Earlier prepared candidates passed native signing, notarization, stapling, Gatekeeper and installer checks for both architectures. Those were preparation artifacts, not published releases. They do not establish that the current consolidated 1.0.0 commit, packages, bridge source or migration chain have passed. Record fresh results and artifact hashes for the reviewed 1.0.0 run.

Local checks can compile both pinned go-ios architectures and inspect module locks without touching a device. Certificate validity, Apple notarization and PKG installation require the exact signed CI artifacts to pass. A passing package job does not demonstrate old Electron download/approval/relaunch or a later signed native Sparkle upgrade.

The migration matrix obtains the separately built bridge and checksum-pinned published 0.3.8 archive, then exercises genuine Squirrel replacement on fresh temporary copies (`0.3.8` → `0.3.9` → `1.0.0`). This component test sets `launchAfterInstallation=false`; it bypasses the complete HTTP/approval/relaunch flow. A separate harmless launcher fixture runs when a GUI session is available, with an explicit warning if not. Jobs retain source and test evidence as artifacts. A CI bridge source remains ineligible for release even if these tests pass.

The untouched published Electron app's complete migration remains **unverified**. Before native publication, run the isolated full chain described in [the migration guide](../migration/README.md), including both architectures and unsupported-macOS behavior. Also verify a signed native 1.0.0 → higher-build Sparkle upgrade. The ad-hoc Sparkle fixture's successful installation/relaunch is separate evidence and cannot substitute for either production-signature path.

## Explicit publication procedure

1. Review and merge the separate Electron 0.3.9 PR. Validate and publish its signed `v0.3.9` bridge release using that PR's procedure. Its missing-feed fallback must keep the legacy interface usable while 1.0.0 is not yet available. Do not publish native 1.0.0 first.
2. Inspect the published 0.3.9 release, archive hashes and exact tag commit, then add the reviewed `native/release/bridge-release-pins.json`. Review and merge the native-only PR, select the exact release commit, and dispatch its native workflow with version `1.0.0`, build `1000000`, and no `bridge_run_id`/`bridge_commit`. Require both native package and both migration component jobs to pass, with published bridge source evidence (`releaseEligible=true`).
3. Complete the isolated untouched-Electron download/approval/replacement/relaunch test, unsupported-macOS checks, and signed native Sparkle update test. Use the exact signed artifacts intended for release; retain their hashes and evidence. No production feed or installed user application may be used for this testing.
4. Download the two native architecture artifact bundles and migration/update evidence into a clean directory. Verify SHA-256 manifests, source commit, architectures, minimum OS, signing identity, notarization and installation evidence. Preserve signed appcasts byte-for-byte. Create tag `v1.0.0` at that tested commit and a draft native GitHub Release; upload the native ZIPs, PKGs and checksums. Write release notes explaining the macOS 14 minimum and separate 0.3.9 compatibility release. These are explicit maintainer actions, not workflow side effects.
5. Publish the reviewed native release, verify every final asset URL, then put the generated `electron-migration-*.json` and signed `appcast-*.xml` artifacts in `updates/` on `main` through a reviewed commit. Never edit or regenerate a signed XML feed during copying. Until these feeds are reachable, the bridge uses its documented fallback. Keep the native ZIP names unchanged so the legacy public service continues to select 0.3.9.
6. Verify the public legacy feed still selects the 0.3.9 bridge for both architectures, and check all four native feed URLs and their downloads. Keep the original 0.3.9 release, 1.0.0 native ZIPs and pinned migration JSON available. Monitor the public service's first-100-release limit; implement and verify durable legacy routing before it loses sight of 0.3.9.

For future native releases, increase the marketing version and numeric build and generate new Sparkle appcasts. Keep the first migration JSON pinned to 1.0.0. Do not add bridge assets to each new native release, and do not replace the migration target with a build requiring a newer OS or missing the compatibility launcher.

Before publication, rollback means discarding the candidate artifacts. After publication, remove an affected appcast item to stop new offers; a lower Sparkle build number will not automatically downgrade users who already updated. Keep signed 0.3.8/0.3.9 packages available for an explicit reinstall, and never rewrite an existing release tag or signed artifact in place.
