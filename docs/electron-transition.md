# Electron 0.3.9 transition

This is the first of two changes: ship Electron **0.3.9**, then replace the application with native macOS **0.4.0** in a separate PR. This checkout remains the existing Electron application. It preserves the device protocol and uses the exact go-ios executable from the published 0.3.8 app for each architecture; it does not rebuild or upgrade go-ios.

## Behavior before and after the native release

The bridge registers its renderer IPC and opens the existing interface before device administrator authorization. Cancelling that authorization keeps the interface and migration checks available; privileged device work still requires authorization. macOS 14 or later checks an architecture-specific HTTPS manifest in the background, then retries every ten minutes while no download is in progress. The manifest preflight has a ten-second abort deadline. Empty, missing, and not-yet-published feeds leave the working interface available; failures are logged without a modal error.

The two files initially committed under `updates/` deliberately offer no update:

```json
{"currentRelease":"0.3.9","releases":[]}
```

The future native destination is permanently pinned to **0.4.0**. Only these manifest/asset pairs are accepted:

| Architecture | Manifest on `main` | Native asset in release `v0.4.0` |
| --- | --- | --- |
| Apple Silicon | `updates/electron-migration-arm64.json` | `Parachute-native-arm64-0.4.0.zip` |
| Intel | `updates/electron-migration-x64.json` | `Parachute-native-x64-0.4.0.zip` |

The full feed prefix is `https://raw.githubusercontent.com/Harrilee/parachute/main/`. After preflight, Electron's native Squirrel updater downloads the release and validates the application identity and publisher. A completed download presents the native restart dialog; choosing Later keeps the current session open, and Squirrel may install the staged update on the next normal quit. An already-started Squirrel download cannot be cancelled through Electron's API. A hung updater request is not overlapped by another request.

Earlier macOS versions and unsupported architectures never request the native manifest. Packaged macOS 0.3.9 disables its previous public updater to prevent an update loop. Other platform updater behavior remains unchanged. This release removes the Mac-location control, its IP/GPS lookup code, location usage descriptions and entitlement, and denies renderer permission requests. Device location simulation remains available.

## Build and verify 0.3.9

`.github/workflows/release.yml` is manually dispatched and produces review artifacts only. It does not push a tag, create a Release, or activate a native feed. Apple Silicon and Intel jobs use macOS 26 hosts; the Electron application's existing minimum OS remains unchanged. Each job:

1. Validates the transition policy and packaging helpers.
2. Downloads the published 0.3.8 ZIP, verifies its pinned SHA-256, and extracts the architecture's pinned go-ios executable before `npm ci`. The committed lock preserves the existing dependencies.
3. Imports the existing Apple credentials into an ephemeral keychain, builds/signs the app, then notarizes and staples it through the shared release helpers.
4. Builds a signed PKG with relocation disabled, notarizes/staples it, and checks a real `/Applications/Parachute.app` installation on the disposable CI runner without launching it.
5. Uses the genuine published 0.3.8 ShipIt executable to replace a fresh temporary application copy with the signed 0.3.9 ZIP, with application launch disabled.

Ticket stapling retries four times only for explicit transient network errors (15/45/90-second backoffs, 120 seconds per attempt). Invalid tickets, signatures, and trust failures fail immediately. Repeated network failure also fails the job; it is not accepted as successful validation.

Artifact names are `electron-bridge-macos-{arm64,x64}-0.3.9`. Each successful artifact contains:

- `Parachute-darwin-{arch}-0.3.9.zip` and `Parachute-0.3.9-{arch}.pkg`.
- `bridge-{arch}-manifest.json` with the exact source commit, workflow run, version, bundle ID, architecture and ZIP/PKG checksums.
- Notarization results/logs, signing/build logs, installer evidence and isolated migration evidence.

The later native PR should consume a successful run and exact reviewed commit from this workflow. It should download these immutable 0.3.9 ZIPs, rather than retaining or rebuilding Electron in the native checkout.

Local checks, which do not launch the app or touch a phone:

```sh
npm test
npm run lint
python3 scripts/release/test-run-bounded.py
python3 scripts/release/test-stapler-retry.py
python3 scripts/release/test-component-package.py
```

The release workflow checks actual signing, notarization, installation and replacement. Local policy tests alone do not establish those results. The ShipIt component test bypasses the original updater's HTTP download, approval and relaunch flow. The complete untouched 0.3.8 → 0.3.9 → native 0.4.0 flow, including OS compatibility and relaunch, still needs isolated signed-artifact validation before native migration is enabled. No earlier 1.0.0 prototype test should be presented as proof for 0.4.0.

## Publication order

1. Merge and release the reviewed Electron 0.3.9 commit after both architecture jobs pass. Publish its signed `Parachute-darwin-*.zip` assets under `v0.3.9`; leave the two manifests at their no-update values. Existing 0.3.8 users can then update to a functioning 0.3.9 while native work continues.
2. Review the native 0.4.0 PR separately. It removes the legacy Electron source/build and consumes the signed 0.3.9 artifacts for migration testing. Preserve the no-update JSON until native assets and the full migration test are ready.
3. Publish the verified native assets under `v0.4.0`. Keep native ZIP names free of `-darwin`, `-mac` and `-osx`. Only after their public URLs are available, replace each migration JSON with `currentRelease: "0.4.0"` and a matching `releases` entry whose `updateTo` has version `0.4.0` and the exact architecture-specific URL above. Changing that manifest activates migration for already-installed 0.3.9 users; a GitHub prerelease flag does not disable this direct feed.
4. Keep the 0.3.9 Release/assets and the first native 0.4.0 ZIPs permanently available. The migration JSON remains pinned to 0.4.0; later native updates use Sparkle.

## Dormant Electron clients

The current public updater scans the GitHub releases list for the first matching asset **per platform**, not just the newest Release. Thus a native 0.4.0 Release containing only `Parachute-native-*.zip` is skipped for legacy macOS clients; they still receive the prior 0.3.9 `darwin` ZIP. There is no need to copy bridge ZIPs into 0.4.0.

This fallback has a concrete limit: the service fetches only the first **100** Releases and does not paginate. Keep the 0.3.9 Release in that set and monitor the legacy feed for both architectures. Before it could fall outside that set, establish and test another retention/routing arrangement. The GitHub Latest badge does not pin this selection, and the current upstream service has no Parachute-specific transition route. Do not promise indefinite skipped-version support without maintaining that condition.

Source evidence, checked against upstream commit `9652cd82a680d695de6658524873b57843b631f7`:

- [Asset classifier](https://github.com/electron/update.electronjs.org/blob/9652cd82a680d695de6658524873b57843b631f7/src/asset-platform.ts#L3-L9): mac/darwin/osx ZIP naming and architecture matching.
- [Release scan](https://github.com/electron/update.electronjs.org/blob/9652cd82a680d695de6658524873b57843b631f7/src/updates.ts#L390-L431): the 100-release request, draft/prerelease exclusion and first compatible asset across releases.
- [Squirrel static JSON handling](https://github.com/Squirrel/Squirrel.Mac/blob/0e5d146ba13101a1302d59ea6e6e0b3cace4ae38/Squirrel/SQRLUpdater.m#L263-L285): a feed whose current release equals the running version produces no update.
