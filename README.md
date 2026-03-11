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

## Development

Install dependencies and start the application:

```bash
npm install
sudo npm start
```

Note that `sudo` is required for USB device tunneling on iOS 17+ devices.

## Quick Start Guide

```bash
sudo npm start
```

1. Connect your iPhone via USB and trust the computer.
2. Enable developer mode if prompted.
3. Pick a location on the map.
4. Click the button to mock or restore your location.
