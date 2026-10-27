# Native release preparation

The `Native macOS release artifacts` workflow is manually dispatched or called
by the manual legacy-workflow wrapper. It builds
Apple Silicon and Intel apps on matching disposable runners and retains all
outputs as Actions artifacts. It does **not** create a release, push a tag, or
change a public update feed.

The version is `1.0.0`; its initial native build number is `1000000`. Both apps
retain the published Electron identity `com.electron.parachute`, use the existing
Developer ID team, and require macOS 14.0 or newer. Build numbers must increase
for each Sparkle update. The workflow selects Xcode 26.2 because the source uses
the macOS 26 SDK with availability-guarded glass UI, and targets macOS 14.0.

## Artifacts and routing

Each architecture produces:

- `Parachute-native-{arm64,x64}-1.0.0.zip`: a root `Parachute.app`, whose nested
  code and main bundle are signed and whose notarization ticket is stapled.
- `Parachute-native-{arm64,x64}-1.0.0.pkg`: a Developer ID Installer-signed and
  notarized package installing to `/Applications`, with macOS and architecture
  requirements.
- An architecture-specific Sparkle appcast, checksums, go-ios provenance, and
  Apple notarization result/log JSON.

For the initial `1.0.0` transition only, parallel jobs stage the Electron `0.3.9`
bridge with its frozen npm lock and the exact architecture-specific go-ios from
the published `0.3.8` artifact. They build and notarize the bridge ZIP using
Electron Forge, build a signed PKG directly with `productbuild`, then
notarize/staple it and validate installation. Bridge ZIPs retain
the old `Parachute-darwin-{arm64,x64}-0.3.9.zip` naming. The main Electron package
version and source checkout are not overwritten by bridge staging. Later native
release versions skip these bridge jobs.

The native asset names deliberately omit `darwin`, `mac`, and `osx`: the current
Electron update service must not offer a macOS 14-only native app directly to
older macOS installations. The separate migration bridge and its compatibility
feeds handle that transition. A ZIP's layout alone does not establish that
Electron-to-native migration has passed an end-to-end test.

The app embeds `https://raw.githubusercontent.com/Harrilee/parachute/main/updates/appcast-{arm64,x64}.xml`.
Generated feeds reference the planned `v1.0.0` release assets; generating a feed
does not publish that release or make those URLs live. Publish assets before
updating a production feed, and only after reviewing both architecture builds,
migration behavior, installer checks, and the exact release commit.

The first native release is a **single `v1.0.0` GitHub Release** containing both native artifacts and the two `Parachute-darwin-{arm64,x64}-0.3.9.zip` bridge assets. The legacy public updater reads the release tag as its version but selects the bridge ZIP by platform/architecture. The bridge itself disables that public updater and uses the pinned migration JSON feed, so it does not repeatedly install itself. Every later latest release must retain the same bridge ZIP assets to support dormant Electron installations; native ZIPs must keep their `native-` names. The migration JSON feeds always target 1.0.0, while Sparkle feeds advance to newer native builds.

## Build contract

`build-go-ios.sh <arm64|x86_64> <output>` builds the existing pinned fork commit
`80ed9e1cb2c9dfd8af38efff54e0feaad6fe742b` (`v1.0.204`) with Go 1.24.4 and the
single success-acknowledgement patch. Fresh CI may download locked dependencies;
`-mod=readonly`, unchanged module/workspace-file checks, and an exact comparison
with `go-ios-dependencies.txt` reject dependency drift. This manifest contains the
26 embedded module records from the preserved local Electron `bin/ios` (SHA-256
`0d5d80df01f77b9c0532d6e95530ed07f7915159b0d363089038798ce8c80798`).
The original binary is ignored by Git and is never overwritten by this helper.
The original binary does not identify its source commit; the pinned source ref
is the existing repository build configuration, not a claim of recovered binary
provenance.

`native/build.sh` accepts `NATIVE_RELEASE=1`, `NATIVE_ARCH`,
`NATIVE_GO_IOS_BINARY`, `NATIVE_GO_IOS_BUILD_INFO`, `SPARKLE_FRAMEWORK_PATH`,
`RELEASE_VERSION`, `BUILD_NUMBER`, `BUNDLE_ID`, `SPARKLE_PUBLIC_KEY`,
`SPARKLE_FEED_URL`, and `RELEASE_TEAM_ID`. The migration launcher is staged next.
`package.sh <app> <output>` then signs, notarizes and packages that complete app.
Its optional third argument selects `sign`, `notarize-app`, `build-pkg`, or
`notarize-pkg`; omitting it runs all phases. CI uses separate steps so API-visible
job status distinguishes signing, Apple notarization, and installer construction.
Bridge packaging similarly exposes `prepare`, `build-pkg`, and `notarize-pkg`.

Signing and `productbuild` run under a 10-minute process timeout. A timeout logs
only the owned process group's names/state (not arguments or environment), then
terminates only that group. The helper's tests cover success output, nonzero
exits, child cleanup and preservation of an unrelated process. Apple notarization
has a separate 30-minute wait limit. Submission IDs are written before waiting,
and result/log JSON plus packaging logs are uploaded even after a job failure.

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
prompt, including when the two certificates share a private key. The setup logs
only whether their public keys match. This policy applies only inside the
disposable signing keychain.

Sparkle reads `SPARKLE_PRIVATE_KEY` through standard input. Its public counterpart
is checked in at `native/updater/public-key.txt`. Private key material must never
be written into the repository, artifact directory, command-line arguments, or
logs.

## Validation boundaries

Local validation can compile both go-ios architectures and inspect module locks
without touching a connected device. Certificate validity, Apple notarization,
and actual PKG installation require the signed CI jobs to succeed. A passing
package job does not demonstrate old Electron upgrade/relaunch or a later
Sparkle upgrade; those require the isolated migration/update tests described by
the migration and updater documentation.

For `1.0.0`, a dependent matrix job downloads both signed CI artifacts and the
checksum-pinned published `0.3.8` archive, then exercises genuine Squirrel
replacement on fresh temporary copies (`0.3.8` → bridge → native). This is a
component test with `launchAfterInstallation=false`; it does not claim the
complete HTTP/approval/relaunch flow. A separate harmless launcher fixture runs
when the runner has a GUI session, with an explicit warning if unavailable.
Both jobs retain their evidence as Actions artifacts.

## Explicit publication procedure

1. Merge the reviewed PR, select the exact release commit, and dispatch `release.yml` for that commit with version `1.0.0` and build `1000000`. Require both native and both bridge jobs to pass. Complete the isolated signed migration test described in `native/migration/README.md` before exposing the release to legacy users.
2. Download the four artifact bundles from that run into a clean directory. Verify their SHA-256 manifests, source commit, architectures, minimum OS, notarization results and PKG installation evidence. Keep the generated signed appcasts byte-for-byte unchanged. The unsigned fixture update tests are separate evidence, not a substitute for checking the production packages.
3. Create `v1.0.0` at the tested commit and a **draft** GitHub Release. Upload both native ZIPs and PKGs, both bridge ZIPs, and the checksums. Bridge PKGs are for compatibility testing/rollback; do not present them as the recommended 1.0 installer. Write English release notes that identify macOS 14 as the native minimum. These are explicit maintainer actions; no workflow performs them.
4. Publish the complete release after all assets are present. Then copy the two generated `electron-migration-*.json` and the two signed `appcast-*.xml` artifacts into `updates/` on `main` in a reviewed commit. Do not regenerate or edit a signed XML feed. Asset URLs must be live before the feed commit; bridge checks during the short transition fall back to the existing UI and retry on the next launch.
5. Verify the public legacy feed selects a bridge ZIP for both architectures, and check all four published feed URLs and their downloads. Keep the 1.0.0 native ZIPs, pinned migration JSON and the bridge ZIPs permanently available for skipped-version upgrades.

For future native releases, increase both the marketing version and numeric build, generate new Sparkle appcasts, and retain the original bridge ZIPs on the latest Release. Do not advance the Electron migration feed to a future build with a higher system requirement.

Rollback before publication means discarding the CI artifacts. After publication, remove the affected appcast item to stop new offers; a lower Sparkle build number will not automatically downgrade users who already updated. Keep the signed 0.3.8/0.3.9 packages available for an explicit reinstall, and never rewrite an existing release tag or signed artifact in place.
