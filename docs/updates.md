# Native updates

Parachute uses the pinned official **Sparkle 2.10.1** distribution. The archive
URL and SHA-256 are recorded in `sparkle-version.json`; `fetch-sparkle.sh` verifies
the archive, framework signature, and both CPU architectures. Downloaded tools
and frameworks stay in ignored `build/cache/`.

Sparkle handles updates after native 1.0.0 (build 1000000) is installed. The [release procedure](release.md) covers the required preceding 0.3.9 publication, artifact provenance and feed promotion; [Electron migration](migration.md) is a separate upgrade path.

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
preferences. Builds compiled with `LOCAL_PREVIEW`, or launched with
`--preview`, never initialize Sparkle or request production updates.

Stable feeds:

- Apple Silicon: `https://raw.githubusercontent.com/Harrilee/parachute/main/updates/appcast-arm64.xml`
- Intel: `https://raw.githubusercontent.com/Harrilee/parachute/main/updates/appcast-x64.xml`

Compile/link with `-F "$SPARKLE_ROOT" -framework Sparkle` and runtime search path
`@executable_path/../Frameworks`. Copy `Sparkle.framework` with symlinks preserved
into `Contents/Frameworks`. Sign its nested XPC services, `Autoupdate`,
`Updater.app`, then the framework and containing application. The downloader XPC
must retain its existing entitlements. See `scripts/release/sign-app.sh`.

## Signing keys

The production account is `Harrilee.parachute`. Key generation is a one-time
operator action, separate from builds. Check for an existing key with:

```sh
SPARKLE_ROOT="$(scripts/updates/fetch-sparkle.sh)"
"$SPARKLE_ROOT/bin/generate_keys" --account Harrilee.parachute -p
```

If there is no existing account, run `generate_keys --account Harrilee.parachute`
once. It stores the private key in macOS Keychain and displays only the public
key. Copy the public key to `Resources/Sparkle/public-key.txt`. Export the private
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
Parachute-native-arm64-1.0.1.zip
Parachute-native-x64-1.0.1.zip
```

Generate each feed separately. In CI, pass the existing Secret through stdin;
do not enable shell tracing:

```sh
printf '%s' "$SPARKLE_PRIVATE_KEY" | scripts/updates/generate-appcast.py \
  --archive dist/Parachute-native-arm64-1.0.1.zip \
  --architecture arm64 --version 1.0.1 --build 1000001 \
  --download-base-url https://github.com/Harrilee/parachute/releases/download/v1.0.1/ \
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
build. The native publisher retains unchanged signed feeds in its CI evidence artifact; GitHub Release attachments contain only four installation files and a combined checksum file. Updating `updates/appcast-*.xml` on `main` remains a separate reviewed commit; publishing the Release alone does not activate a feed.
Never publish a feed before its referenced ZIP is available at its final URL. The first migration JSON feeds stay pinned to native 1.0.0; only the Sparkle feeds advance for subsequent native releases. See [the release procedure](release.md) for the published 0.3.9 prerequisite and review gates.

## Verification boundaries

Configuration tests do not contact a network or create an updater session.
The artifact helper verifies signatures and metadata, but that alone does not
prove installation/relaunch. Run all deterministic tests, including signed
appcast fixtures, with `NATIVE_TEST_SPARKLE=1 bash scripts/test.sh`.

`python3 Tests/Integration/SparkleUpgradeTest.py` performs an actual Sparkle upgrade
using two native fixture versions, a unique test bundle identifier, disposable
EdDSA key, and a loopback-only HTTP server. It enables signed-feed and
pre-extraction verification exactly as production does. The custom test user
driver accepts download and installation without showing updater dialogs. The
app is installed in an owned `build/sparkle-upgrade-<UUID>/Installed/`
folder. It neither launches Parachute nor accesses devices, production feeds,
production keys, or production preferences. The disposable private key is
deleted before launching the fixture. Only the test preference domain and test
cache are cleaned up afterward. A GUI login session is required for Launch
Services to relaunch the app; CI explicitly warns if that capability is absent.

The fixture records old/new process IDs, installed build and lifecycle events to establish download, replacement and relaunch at the same path. It uses ad-hoc signatures and a custom user driver, so it does not verify a notarized Developer ID app upgrade or the shipping UI's update interaction. `UpdaterConfigurationTests.swift` independently covers production HTTPS settings and preview isolation. Record results for each architecture and exact tested artifact; the [remaining publication gates](release.md#validation-boundaries) still apply.

Primary references: [programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/),
[publishing updates](https://sparkle-project.org/documentation/publishing/),
[configuration](https://sparkle-project.org/documentation/customization/), and
[Sparkle 2.10.1 release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1).
