# Parachute

[English](README.md) | 简体中文

[![GitHub Release](https://img.shields.io/github/v/release/Harrilee/parachute)](https://github.com/Harrilee/parachute/releases)
![License](https://camo.githubusercontent.com/234d91288de379a53976a1a22b2b9eb4830eeeece700a3a0d754e5013b2714e5/68747470733a2f2f696d672e736869656c64732e696f2f6769746875622f6c6963656e73652f48617272696c65652f7061726163687574653f)
![Platform](https://img.shields.io/badge/platform-macOS-blue)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub%20Sponsors-support%20this%20project-ea4aaa?logo=githubsponsors)](https://github.com/sponsors/Harrilee)

<img width="4507" height="2840" alt="MacBook Pro M5 16-inch Space Black" src="https://github.com/user-attachments/assets/1f3ea330-1c92-49c5-84b2-ae97c8e8e762" />

Parachute 是一款原生 macOS 应用，可以修改 iPhone 和 iPad 的虚拟定位。1.0.1 版本采用 SwiftUI 和 Apple 地图，支持中英文界面，并跟随系统切换浅色与深色外观。需要 macOS 14 或更高版本。

## 当前架构

| 组件 | 说明 |
| --- | --- |
| 前端 | SwiftUI、AppKit |
| 后端 | Swift 服务层与固定版本的 [go-ios](https://github.com/Harrilee/go-ios) 二进制 |
| 通信 | 通过参数数组异步调用子进程 |
| 地图 | Apple MapKit（标准地图、卫星图与地址搜索） |

## 安装

请从 [GitHub Releases](https://github.com/Harrilee/parachute/releases) 页面下载最新版本。

### macOS

1. 下载 `.pkg` 安装包，或者下载与你架构匹配的 `.zip`（Apple Silicon 用 **arm64**，Intel 用 **x64**）。
2. 安装 `.pkg`，或者解压 `.zip` 后将 **Parachute** 拖到 `Applications` 文件夹。
3. 连接设备并信任电脑，按提示开启开发者模式。原生应用使用用户态隧道，无需管理员密码；iOS 17.0–17.4.0 需要已运行的兼容隧道。

## 支持项目

如果 Parachute 对你有帮助，欢迎通过 [GitHub Sponsors](https://github.com/sponsors/Harrilee) 支持项目持续开发。

## 使用方法

1. 连接 iPhone 并信任电脑。USB 和无线同时可用时优先使用 USB；无线尝试失败时，请改用 USB 重试。
2. 如有提示，请开启开发者模式。
3. 在地图上选点、搜索地址，或手动输入经纬度。
4. 点击按钮设置或更新定位。

## 开发

应用源码位于 `Sources/`，测试位于 `Tests/`，应用资源位于 `Resources/`，构建及发布脚本位于 `scripts/`，设备工具补丁位于 `patches/`，详细说明位于 `docs/`。生成文件统一放在忽略提交的 `build/` 中。

### 前置条件

- macOS 26 或更高版本，以及 Xcode 26.2 或更高版本，用于编译分层图标（应用本身支持 macOS 14 或更高版本）
- [Go](https://go.dev/) 1.24.4，用于构建设备控制程序
- Python 3，用于构建和发布脚本

### 快速开始

```bash
bash scripts/release/build-go-ios.sh "$(uname -m)" "$PWD/build/ios-native"
NATIVE_GO_IOS_BINARY="$PWD/build/ios-native" bash scripts/build.sh
open build/Parachute.app
```

本地构建使用独立的应用标识，并关闭自动更新。设备控制程序沿用固定版本的 [go-ios](https://github.com/Harrilee/go-ios) 源码及依赖，增加用于成功动画的设备回执与明确的 USB／无线通道选择，不需要 `sudo`。

当前源码只包含原生 macOS 应用。[Electron 0.3.9 过渡版代码](https://github.com/Harrilee/parachute/tree/b8d4ddf66153c6508bb0ba85b7ff5548ed4ebf05)保留在其合并后的源码版本中。发布验证使用已发布的 0.3.9 和固定安装包校验值测试迁移，详见[原生发布说明](docs/release.md)。

### 本地构建

```bash
bash scripts/test.sh
NATIVE_GO_IOS_BINARY="$PWD/build/ios-native" bash scripts/build.sh
```

本地应用输出到 `build/Parachute.app`。签名发布版本使用 [scripts/release](docs/release.md) 中的脚本构建。

### 发布

确认 0.3.9 过渡版已发布、安装包校验值已固定后，构建原生 1.0.1 签名产物：

```bash
gh workflow run release.yml --ref <release-ref> -f version=1.0.1 -f build_number=1000001
```

构建成功后，使用[原生专用发布工作流](.github/workflows/publish.yml)校验产物或创建 GitHub Release 草稿：

```bash
gh workflow run publish.yml --ref main -f action=draft -f source_run_id=<successful-native-run-id> -f source_commit=<40-character-commit> -f version=1.0.1
```

`action=validate` 只做校验。审查草稿并完成[发布检查](docs/release.md)后，使用相同参数、将 action 改为 `publish` 正式发布。发布要求源码提交已进入 `main`，且迁移证据使用已发布的 0.3.9。发布工作流只上传四个 ZIP／PKG 文件和一份校验文件，内部验证记录保留在 CI 中。Sparkle 更新源通过单独审查的提交更新，Electron 迁移索引固定指向 1.0.0。现有 Electron 用户通过过渡版升级；低于 macOS 14 的系统保留 Electron 版本。
