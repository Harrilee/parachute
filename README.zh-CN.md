# Parachute

[English](./README.md) | 简体中文

[![GitHub Release](https://img.shields.io/github/v/release/Harrilee/parachute)](https://github.com/Harrilee/parachute/releases)
![License](https://img.shields.io/github/license/Harrilee/parachute)
![Platform](https://img.shields.io/badge/platform-macOS-blue)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub%20Sponsors-support%20this%20project-ea4aaa?logo=githubsponsors)](https://github.com/sponsors/Harrilee)

<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/0a0b6d2b-7f96-4a1a-8e50-28ecd1fe8861" />

Parachute 是一个 macOS 应用，可以帮助用户修改 iPhone 和 iPad 的虚拟定位，兼容最新的 iOS 26。

## 当前架构

| 组件 | 说明 |
| --- | --- |
| 前端 | Electron、React、Webpack、MUI |
| 后端 | [go-ios](https://github.com/danielpaulus/go-ios)（编译后的 Go 二进制）和 Node.js |
| 通信 | Electron IPC |
| 地图 | 高德地图、Open Street Map |

## 安装

请从 [GitHub Releases](https://github.com/Harrilee/parachute/releases) 页面下载最新版本。

### macOS

1. 下载 `.pkg` 安装包，或者下载与你架构匹配的 `.zip`（Apple Silicon 用 **arm64**，Intel 用 **x64**）。
2. 安装 `.pkg`，或者解压 `.zip` 后将 **Parachute** 拖到 `Applications` 文件夹。
3. iOS 17+ 的 USB 隧道功能需要管理员权限，首次启动时会提示你输入密码。

## 支持项目

如果 Parachute 对你有帮助，欢迎通过 [GitHub Sponsors](https://github.com/sponsors/Harrilee) 支持项目持续开发。

## 使用方法

1. 用 USB 连接 iPhone，并在设备上点击“信任这台电脑”。
2. 如有提示，请开启开发者模式。
3. 在地图上选择一个位置。
4. 点击按钮设置或更新定位。

## 开发

### 前置条件

- [Node.js](https://nodejs.org/) 20+
- [Go](https://go.dev/) 1.22+（`brew install go`）

### 快速开始

```bash
npm install    # 安装依赖并自动编译 go-ios 到 bin/
sudo npm start
```

`npm install` 会通过 `postinstall` 脚本自动克隆并编译 [go-ios](https://github.com/Harrilee/go-ios)（分支 `v1.0.204`）。如需强制重新编译：

```bash
FORCE_REBUILD=1 ./scripts/download-go-ios.sh
```

`sudo` 用于支持 iOS 17+ 设备的 USB 隧道能力。

### 本地构建

```bash
npm run make
```

构建产物会输出到 `out/make/`。

### 发布

推送版本 tag 后会自动触发 CI/CD 流程：

```bash
npm version patch   # 或 minor / major
git push --follow-tags
```

[GitHub Actions workflow](.github/workflows/release.yml) 会为 arm64 和 x64 构建 macOS 版本，并上传到 GitHub Release。
