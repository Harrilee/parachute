
# Parachute

English | [简体中文](./README.zh-CN.md)

[![GitHub Release](https://img.shields.io/github/v/release/Harrilee/parachute)](https://github.com/Harrilee/parachute/releases)
![License](https://camo.githubusercontent.com/234d91288de379a53976a1a22b2b9eb4830eeeece700a3a0d754e5013b2714e5/68747470733a2f2f696d672e736869656c64732e696f2f6769746875622f6c6963656e73652f48617272696c65652f7061726163687574653f)
![Platform](https://img.shields.io/badge/platform-macOS-blue)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub%20Sponsors-support%20this%20project-ea4aaa?logo=githubsponsors)](https://github.com/sponsors/Harrilee)

<img width="4507" height="2840" alt="MacBook Pro M5 16-inch Space Black" src="https://github.com/user-attachments/assets/1f3ea330-1c92-49c5-84b2-ae97c8e8e762" />



Parachute is a native macOS application for changing the virtual location of an iPhone or iPad. Version 1.0.0 uses SwiftUI and Apple Maps, with English and Chinese interfaces and automatic light and dark appearance. Requires macOS 14 or later.

## Current Architecture

| Component     | Description                                                              |
| ------------- | ------------------------------------------------------------------------ |
| Frontend      | SwiftUI and AppKit                                           |
| Backend       | Swift services and pinned [go-ios](https://github.com/Harrilee/go-ios) binary |
| Communication | Asynchronous subprocesses with structured arguments                                                             |
| Map           | Apple MapKit (standard and satellite maps, address search)                                                    |

## Installation

Download the latest release from the [GitHub Releases](https://github.com/Harrilee/parachute/releases) page.

### macOS

1. Download the `.pkg` installer, or the `.zip` for your architecture (**arm64** for Apple Silicon, **x64** for Intel).
2. Install the `.pkg`, or extract the `.zip` and move **Parachute** to your Applications folder.
3. Connect and trust your device, then enable Developer Mode when prompted. The native app uses a userspace tunnel without an administrator password; iOS 17.0–17.4 requires an existing compatible tunnel.

## Support

If Parachute is useful to you, please consider supporting its development via [GitHub Sponsors](https://github.com/sponsors/Harrilee).

## Usage

1. Connect your iPhone via USB and trust the computer.
2. Enable developer mode if prompted.
3. Pick a location on the map, search for an address, or enter coordinates.
4. Click the button to set or update your location.

## Development

### Prerequisites

- macOS 26 or later with Xcode 26.2 or later to compile the layered app icon (the app itself runs on macOS 14 or later)
- [Go](https://go.dev/) 1.24.4 for the pinned device helper
- Python 3 for build and release scripts

### Getting started

```bash
bash native/release/build-go-ios.sh "$(uname -m)" "$PWD/native/build/ios-native"
NATIVE_GO_IOS_BINARY="$PWD/native/build/ios-native" bash native/build.sh
open native/build/Parachute.app
```

The local build uses a separate application identity with automatic updates disabled. The native helper retains the pinned [go-ios](https://github.com/Harrilee/go-ios) source and dependencies, adding a device acknowledgement for the success animation. It does not require `sudo`.

This source tree contains the native macOS application. The [Electron 0.3.9 transition implementation](https://github.com/Harrilee/parachute/tree/b8d4ddf66153c6508bb0ba85b7ff5548ed4ebf05) is retained at its merged source revision. Release validation checks migration from published 0.3.9 using pinned archive hashes; see the [native release procedure](native/release/README.md).

### Building locally

```bash
bash native/test.sh
NATIVE_GO_IOS_BINARY="$PWD/native/build/ios-native" bash native/build.sh
```

The local app is written to `native/build/Parachute.app`. Signed release builds use the scripts in [native/release](native/release/README.md).

### Releasing

Build signed native 1.0.0 artifacts after the published 0.3.9 bridge and its archive pins are available:

```bash
gh workflow run release.yml --ref <release-ref> -f version=1.0.0 -f build_number=1000000
```

After the build succeeds, the [native-only publisher](.github/workflows/publish.yml) can validate its artifacts or create a GitHub Release draft:

```bash
gh workflow run publish.yml --ref main -f action=draft -f source_run_id=<successful-native-run-id> -f source_commit=<40-character-commit> -f version=1.0.0
```

Use `action=validate` for a read-only check. After reviewing the draft and completing the [release checks](native/release/README.md), run the same publisher inputs with `action=publish`. Publication requires the source commit on `main` and migration evidence from the published 0.3.9 bridge. The publisher uploads existing signed artifacts without rebuilding them; updating the migration and Sparkle feeds remains a separate reviewed commit. Existing Electron users migrate through the bridge; systems below macOS 14 retain the Electron version.
