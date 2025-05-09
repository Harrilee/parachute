# Parachute

Parachute is a cross-platform application that allows users to change the virtial location of their iPhone and iPad. It is targeted on MacOS, Windows, and Linux, and compatible with latest iOS 18 version.

## Planned Features and Roadmap

-   [x] User interface for selecting location
-   [x] Device connection, developer mode detection
-   [x] Location mocking
-   [x] More map providers (OpenStreetMap)
-   [ ] Decouple Python from package, publish package
    -  [ ] Plan B (Better): implement `pymobiledevice3` with `node`
-   [ ] Add support for Windows
-   [ ] Light and dark mode support
-   [ ] Multi-language support (Chinese, English, etc.)

## Current Architecture

| Component     | Description                                                                              |
| ------------- | ---------------------------------------------------------------------------------------- |
| Frontend      | Electron, React, Webpack, MUI                                                            |
| Backend       | Bundled Python ([pymobiledevice3](https://github.com/doronz88/pymobiledevice3)), Node.js |
| Communication | Electron IPC                                                                             |
| Map           | AMap, Open Street Map                                                                    |

## Development

Run `setup.sh` to install dependencies and Python virtual environment. Then run `npm start` to start the application.

## Quick Start Guide

While production usage is not supported, developers can test the feature by

```bash
sudo npm start
```

Note that `sudo` is required by connection to iDevices.
