# Native updates

Parachute uses the pinned official **Sparkle 2.10.1** distribution. The archive
URL and SHA-256 are recorded in `sparkle-version.json`; `fetch-sparkle.sh` verifies
the archive, framework signature, and both CPU architectures. Downloaded tools
and frameworks stay in ignored `native/build/cache/`.

Native 0.4.0 (build 400000) follows the separately reviewed and published Electron 0.3.9 bridge release. Sparkle handles updates after the first native installation; it does not replace the bridge or its migration checks. This branch contains no Electron build pipeline.

## Application integration

`UpdaterService` owns the standard Sparkle UI and scheduler. Create it once with
`@StateObject`, call `start()` after application launch, and connect a native
“Check for Updates…” menu item to `checkForUpdates()`, enabled only when
`canCheckForUpdates` is true. The English, Simplified Chinese, and Traditional
Chinese menu labels use `update.check` in native localization resources. Sparkle
provides its own localized update dialogs.

Production configuration belongs in the signed application's Info.plist:

- `ParachuteUpdatesEnabled`: true
- `SUFeedURL`: one of the architecture-specific URLs below
- `SUPublicEDKey`: the contents of `public-key.txt`
- `SUEnableAutomaticChecks`: true (default checks, no silent installation)
- `SUAutomaticallyUpdate`: false
- `SUVerifyUpdateBeforeExtraction`: true
- `SURequireSignedFeed`: true (the helper signs both ZIP and appcast)

Sparkle retains the user's preferences. The service does not reset them on
launch. The validated feed in the signed bundle also overrides stale feed URL
preferences. Builds compiled with `LOCAL_PREVIEW` or `LOCAL_QA`, or launched with
`--preview`, never initialize Sparkle or request production updates.

Stable feeds:

- Apple Silicon: `https://raw.githubusercontent.com/Harrilee/parachute/main/updates/appcast-arm64.xml`
- Intel: `https://raw.githubusercontent.com/Harrilee/parachute/main/updates/appcast-x64.xml`

Compile/link with `-F "$SPARKLE_ROOT" -framework Sparkle` and runtime search path
`@executable_path/../Frameworks`. Copy `Sparkle.framework` with symlinks preserved
into `Contents/Frameworks`. Sign its nested XPC services, `Autoupdate`,
`Updater.app`, then the framework and containing application. The downloader XPC
must retain its existing entitlements. See `native/release/sign-app.sh`.

## Signing keys

The production account is `Harrilee.parachute`. Key generation is a one-time
operator action, separate from builds. Check for an existing key with:

```sh
SPARKLE_ROOT="$(native/updater/fetch-sparkle.sh)"
"$SPARKLE_ROOT/bin/generate_keys" --account Harrilee.parachute -p
```

If there is no existing account, run `generate_keys --account Harrilee.parachute`
once. It stores the private key in macOS Keychain and displays only the public
key. Copy the public key to `native/updater/public-key.txt`. Export the private
key with `generate_keys --account Harrilee.parachute -x <protected-temp-file>`
only when configuring or backing up `SPARKLE_PRIVATE_KEY`; use a temporary
directory with mode 0700 and file mode 0600. Supply that file to
`gh secret set SPARKLE_PRIVATE_KEY --repo Harrilee/parachute` through stdin, then
delete it. Never log the file contents, use the private key as a command-line
argument, or commit it. Do not generate a fresh production key on every build.

## Appcast artifacts

After signing, notarization, and stapling, package the application with `ditto`
to preserve framework symlinks. Native ZIP names deliberately do not match the
old Electron update service's macOS pattern:

```text
Parachute-native-arm64-0.4.0.zip
Parachute-native-x64-0.4.0.zip
```

Generate each feed separately. In CI, pass the existing Secret through stdin;
do not enable shell tracing:

```sh
printf '%s' "$SPARKLE_PRIVATE_KEY" | native/updater/generate-appcast.py \
  --archive dist/Parachute-native-arm64-0.4.0.zip \
  --architecture arm64 --version 0.4.0 --build 400000 \
  --download-base-url https://github.com/Harrilee/parachute/releases/download/v0.4.0/ \
  --output dist/appcast-arm64.xml
```

The helper validates bundle identity, version, build number, minimum macOS
version, feed, public key, and main/helper CPU architectures before signing.
It then verifies the ZIP signature against the checked-in public key using
CryptoKit, signs and verifies the XML feed, and writes the output atomically.
The feed records `14.0.0` as its minimum system version and restricts the Apple
Silicon feed to `arm64`. `--sha256` can require an expected final ZIP digest;
`--notes` embeds plain-text release notes without a separate unsigned URL.

Only the latest release is included in these initial feeds. A future release
that raises hardware or macOS requirements must preserve compatible older
items or explicitly plan retirement before replacing the production feed.
The build number must increase for every published update, including a rollback
build. Generating artifacts does not publish them: uploading release assets and
updating `updates/appcast-*.xml` on `main` require the explicit release step.
Never publish a feed before its referenced ZIP is available at its final URL. The first migration JSON feeds stay pinned to native 0.4.0; only the Sparkle feeds advance for subsequent native releases. See [the release procedure](../release/README.md) for the published 0.3.9 prerequisite and review gates.

## Verification boundaries

Configuration tests do not contact a network or create an updater session.
The artifact helper verifies signatures and metadata, but that alone does not
prove installation/relaunch. Run all deterministic tests, including signed
appcast fixtures, with `NATIVE_TEST_SPARKLE=1 bash native/test.sh`.

`python3 native/Tests/SparkleUpgradeTest.py` performs an actual Sparkle upgrade
using two native fixture versions, a unique test bundle identifier, disposable
EdDSA key, and a loopback-only HTTP server. It enables signed-feed and
pre-extraction verification exactly as production does. The custom test user
driver accepts download and installation without showing updater dialogs. The
app is installed in an owned `native/build/sparkle-upgrade-<UUID>/Installed/`
folder. It neither launches Parachute nor accesses devices, production feeds,
production keys, or production preferences. The disposable private key is
deleted before launching the fixture. Only the test preference domain and test
cache are cleaned up afterward. A GUI login session is required for Launch
Services to relaunch the app; CI explicitly warns if that capability is absent.

On 2026-10-26, the Apple Silicon local run passed download, signed feed/ZIP
verification, extraction, replacement, and relaunch: build `1` terminated and
build `2` started at the same installed app path with a different process ID.
The recorded run was `sparkle-upgrade-b95a7d5c-c2f8-4ad5-9ce1-5d1318f1465c`;
its `result.json` records both loopback requests, old/new PIDs, installed bundle
version, and lifecycle events. This is an **ad-hoc signed fixture** test. It does
not verify a notarized Developer ID production application update, the actual
Parachute UI's update interaction, or Intel installation/relaunch. CI results
for each architecture provide separate evidence and must not be inferred from
this local result. The service's production HTTPS configuration and preview
isolation are covered independently by `UpdaterConfigurationTests.swift`.

Historical signed-package and fixture results from the superseded 1.0.0 candidate are preparation evidence only; that candidate was not a production release. They do not establish that the current 0.4.0 packages or a signed 0.4.0-to-higher-build update have passed. Record results for the exact new artifact hashes before publication.

Electron-to-native migration remains a separate, still-unverified complete end-to-end test and must not use the public update service during validation. Before native publication, verify the untouched published Electron app through download, approval, replacement and relaunch, as well as the signed native Sparkle upgrade separately.

Primary references: [programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/),
[publishing updates](https://sparkle-project.org/documentation/publishing/),
[configuration](https://sparkle-project.org/documentation/customization/), and
[Sparkle 2.10.1 release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1).
