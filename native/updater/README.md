# Native updates

Parachute uses the pinned official **Sparkle 2.10.1** distribution. The archive
URL and SHA-256 are recorded in `sparkle-version.json`; `fetch-sparkle.sh` verifies
the archive, framework signature, and both CPU architectures. Downloaded tools
and frameworks stay in ignored `native/build/cache/`.

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
Parachute-native-arm64-1.0.0.zip
Parachute-native-x64-1.0.0.zip
```

Generate each feed separately. In CI, pass the existing Secret through stdin;
do not enable shell tracing:

```sh
printf '%s' "$SPARKLE_PRIVATE_KEY" | native/updater/generate-appcast.py \
  --archive dist/Parachute-native-arm64-1.0.0.zip \
  --architecture arm64 --version 1.0.0 --build 1000000 \
  --download-base-url https://github.com/Harrilee/parachute/releases/download/v1.0.0/ \
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
Never publish a feed before its referenced ZIP is available at its final URL.

## Verification boundaries

Configuration tests do not contact a network or create an updater session.
The artifact helper verifies signatures and metadata, but that alone does not
prove installation/relaunch. A real Sparkle upgrade must be tested using two
isolated test builds and an isolated feed. Electron-to-native migration remains
a separate test and must not use the public update service during validation.

Primary references: [programmatic setup](https://sparkle-project.org/documentation/programmatic-setup/),
[publishing updates](https://sparkle-project.org/documentation/publishing/),
[configuration](https://sparkle-project.org/documentation/customization/), and
[Sparkle 2.10.1 release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1).
