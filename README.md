# Parachute

Parachute is a cross-platform application that allows users to change the virtual location of their iPhone and iPad. It is targeted on MacOS, Windows, and Linux, and compatible with latest iOS 26 version.

## Planned Features and Roadmap

-   [x] User interface for selecting location
-   [x] Device connection, developer mode detection
-   [x] Location mocking
-   [x] More map providers (OpenStreetMap)
-   [x] Decouple Python from package (replaced with [go-ios](https://github.com/danielpaulus/go-ios))
-   [ ] Icons
-   [ ] Elegant sudo enablement
-   [ ] Add support for Windows
-   [ ] Light and dark mode support
-   [ ] Multi-language support (Chinese, English, etc.)

## Current Architecture

| Component     | Description                                                              |
| ------------- | ------------------------------------------------------------------------ |
| Frontend      | Electron, React, Webpack, MUI                                           |
| Backend       | [go-ios](https://github.com/danielpaulus/go-ios) (compiled Go binary), Node.js |
| Communication | Electron IPC                                                             |
| Map           | AMap, Open Street Map                                                    |

## Installation

Download the latest release from the [GitHub Releases](https://github.com/Harrilee/parachute/releases) page.

### macOS (Apple Silicon)

1. Download the `.dmg` or `.zip` from the latest release.
2. Open the DMG and drag **Parachute** to your Applications folder, or extract the zip.
3. On first launch, macOS may block the unsigned app. Go to **System Settings > Privacy & Security** and click **Open Anyway**.
4. The app requires administrator privileges for USB device tunneling on iOS 17+. You will be prompted for your password on launch.

## Usage

1. Connect your iPhone via USB and trust the computer.
2. Enable developer mode if prompted.
3. Pick a location on the map.
4. Click the button to mock or restore your location.

## Development

Install dependencies and start the application:

```bash
npm install
sudo npm start
```

`sudo` is required for USB device tunneling on iOS 17+ devices.

### Building locally

```bash
npm run make
```

Distributable artifacts are written to `out/make/`.

### Releasing

Push a version tag to trigger the CI/CD pipeline:

```bash
npm version patch   # or minor / major
git push --follow-tags
```

The [GitHub Actions workflow](.github/workflows/release.yml) builds a macOS arm64 binary and uploads it to a GitHub Release.
