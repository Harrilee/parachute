# Parachute

[English](./README.md) | 简体中文

[![GitHub Release](https://img.shields.io/github/v/release/Harrilee/parachute)](https://github.com/Harrilee/parachute/releases)
![License](https://camo.githubusercontent.com/234d91288de379a53976a1a22b2b9eb4830eeeece700a3a0d754e5013b2714e5/68747470733a2f2f696d672e736869656c64732e696f2f6769746875622f6c6963656e73652f48617272696c65652f7061726163687574653f)
![Platform](https://img.shields.io/badge/platform-macOS-blue)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub%20Sponsors-support%20this%20project-ea4aaa?logo=githubsponsors)](https://github.com/sponsors/Harrilee)

<img width="4507" height="2840" alt="MacBook Pro M5 16-inch Space Black" src="https://github.com/user-attachments/assets/1f3ea330-1c92-49c5-84b2-ae97c8e8e762" />

Parachute 是一款原生 macOS 应用，可以修改 iPhone 和 iPad 的虚拟定位。1.0.0 版本采用 SwiftUI 和 Apple 地图，支持中英文界面，并跟随系统切换浅色与深色外观。需要 macOS 14 或更高版本。

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
3. 连接设备并信任电脑，按提示开启开发者模式。原生应用使用用户态隧道，无需管理员密码；iOS 17.0–17.4 需要已运行的兼容隧道。

## 支持项目

如果 Parachute 对你有帮助，欢迎通过 [GitHub Sponsors](https://github.com/sponsors/Harrilee) 支持项目持续开发。

## 使用方法

1. 用 USB 连接 iPhone，并在设备上点击“信任这台电脑”。
2. 如有提示，请开启开发者模式。
3. 在地图上选点、搜索地址，或手动输入经纬度。
4. 点击按钮设置或更新定位。

## 开发

### 前置条件

- macOS 26 或更高版本，以及 Xcode 26.2 或更高版本，用于编译分层图标（应用本身支持 macOS 14 或更高版本）
- [Go](https://go.dev/) 1.24.4，用于构建设备控制程序
- Python 3，用于构建和发布脚本

### 快速开始

```bash
bash native/release/build-go-ios.sh "$(uname -m)" "$PWD/native/build/ios-native"
NATIVE_GO_IOS_BINARY="$PWD/native/build/ios-native" bash native/build.sh
open native/build/Parachute.app
```

本地构建使用独立的应用标识，并关闭自动更新。设备控制程序沿用固定版本的 [go-ios](https://github.com/Harrilee/go-ios) 源码及依赖，只增加用于成功动画的设备回执，不需要 `sudo`。

当前源码只包含原生 macOS 应用。[Electron 0.3.9 过渡版代码](https://github.com/Harrilee/parachute/tree/b8d4ddf66153c6508bb0ba85b7ff5548ed4ebf05)保留在其合并后的源码版本中。请按[过渡版发布说明](https://github.com/Harrilee/parachute/blob/b8d4ddf66153c6508bb0ba85b7ff5548ed4ebf05/docs/electron-transition.md)先发布并验证 0.3.9，再发布原生 1.0.0。

### 本地构建

```bash
bash native/test.sh
NATIVE_GO_IOS_BINARY="$PWD/native/build/ios-native" bash native/build.sh
```

本地应用输出到 `native/build/Parachute.app`。签名发布版本使用 [native/release](native/release/README.md) 中的脚本构建。

### 发布

手动运行工作流，准备原生 1.0.0 的审查产物。正式发布要求先发布 0.3.9；在此之前，可用过渡版成功的 CI run ID 和对应提交验证迁移：

```bash
gh workflow run release.yml --ref <release-branch> -f version=1.0.0 -f build_number=1000000 -f bridge_run_id=<successful-0.3.9-run-id> -f bridge_commit=<tested-0.3.9-commit>
```

[GitHub Actions workflow](.github/workflows/release.yml) 会为 Apple Silicon 和 Intel 构建应用及 `.pkg` 安装包，完成签名和公证后上传 CI artifacts 供审查，不会自动发布 release 或更新源。按[发布说明](native/release/README.md)发布审查后的产物及签名的 Sparkle 更新索引。现有 Electron 用户通过兼容过渡版本升级；较旧的 macOS 系统保留 Electron 版本。
