# Parachute

Parachute is a cross-platform application that allows users to change the virtial location of their iPhone and iPad. It is targeted on MacOS, Windows, and Linux, and compatible with latest iOS 18 version.

## Planned Features and Roadmap

-   [x] User interface for selecting location
-   [x] Device connection, developer mode detection
-   [ ] Location mocking
-   [ ] Decouple Python from package
-   [ ] Add support for Windows
-   [ ] Light and dark mode support
-   [ ] Multi-language support (Chinese, English, etc.)
-   [ ] More map providers (OpenStreetMap)

## Current Architecture

| Component     | Description                                                                              |
| ------------- | ---------------------------------------------------------------------------------------- |
| Frontend      | Electron, React, Webpack, MUI                                                            |
| Backend       | Bundled Python ([pymobiledevice3](https://github.com/doronz88/pymobiledevice3)), Node.js |
| Communication | Electron IPC                                                                             |
| Map           | AMap                                                                                     |
