# CopyEverywhere — macOS

macOS 平台包含两个独立的 Swift Package Manager 应用：

| 目录 | 应用 | 角色 |
|------|------|------|
| [`CopyEverywhere/`](CopyEverywhere/) | 客户端 | MenuBarExtra 托盘应用，负责收发内容 |
| [`CopyEverywhereServer/`](CopyEverywhereServer/) | 服务器宿主 | 托管并管理 Go 中继服务器子进程 |

两个应用均无 `.xcodeproj`，使用 Swift Package Manager 直接构建，无需 Xcode GUI。

## 环境要求

| 依赖 | 最低版本 |
|------|---------|
| macOS | 13 (Ventura) |
| Xcode Command Line Tools | 含 Swift 5.9+ |
| Go | 1.22+（仅 CopyEverywhereServer 需要，用于编译服务端二进制） |

安装 Xcode Command Line Tools：

```bash
xcode-select --install
```

---

## CopyEverywhere 客户端

### 编译

```bash
cd macos/CopyEverywhere
swift build
```

Release 构建：

```bash
swift build -c release
```

产物位于 `.build/debug/CopyEverywhere` 或 `.build/release/CopyEverywhere`。

### 启动

```bash
swift run CopyEverywhere
```

或直接运行已编译的二进制：

```bash
.build/debug/CopyEverywhere
```

应用启动后会在菜单栏显示图标，不会在 Dock 中出现（通过 `NSApp.setActivationPolicy(.accessory)` 实现）。

### 配置

点击菜单栏图标打开面板，切换到"Config"标签页填写：

| 字段 | 说明 |
|------|------|
| Host URL | 中继服务器地址，例如 `http://192.168.1.100:8080` |
| Access Token | 服务器开启认证时所需的 Bearer Token（存入 Keychain） |
| Device Name | 本机设备名称 |
| Target Device | 发送目标设备 ID，留空广播 |
| Transfer Mode | `LAN Server` 或 `Bluetooth` |

配置通过 UserDefaults 持久化，Access Token 单独存入 macOS Keychain。

### 使用方式

- **发送剪贴板文字**：面板开启时按 `Cmd+V`，或在面板中点击"Send Clipboard"
- **发送文件**：拖放文件到菜单栏图标
- **接收内容**：后台 SSE 长连接监听推送，收到后自动写入剪贴板并发送系统通知
- **蓝牙模式**：切换到 Bluetooth 模式后，在面板中扫描并配对附近设备

### 项目结构

```
Package.swift
Sources/CopyEverywhere/
  CopyEverywhereApp.swift      # @main 入口 + AppDelegate（NSStatusItem + NSPopover）
  ConfigStore.swift            # @MainActor ObservableObject，持有全部运行时状态
  MenuBarView.swift            # 菜单栏弹出面板根视图
  MainPanelView.swift          # 队列展示、文件发送、进度显示
  ConfigView.swift             # 设置界面
  StatusItemDropView.swift     # 菜单栏图标拖放透明覆盖层
  BluetoothService.swift       # IOBluetooth RFCOMM 服务端/客户端
  BluetoothDiscovery.swift     # IOBluetoothDeviceInquiry 设备扫描
  BluetoothProtocol.swift      # 蓝牙线上协议定义
  BonjourBrowser.swift         # Bonjour/mDNS 服务发现
```

---

## CopyEverywhereServer 服务器宿主

该应用负责将 Go 中继服务器二进制作为子进程启动和管理，并在菜单栏提供状态显示与控制界面。

### 前置步骤：编译 Go 服务器

服务器宿主需要在同级目录找到 `copyeverywhere-server` 可执行文件，默认路径为与 Swift 可执行文件相邻的 `copyeverywhere-server`。

```bash
cd server
go build -o ../macos/CopyEverywhereServer/copyeverywhere-server .
```

如需指定自定义路径，可在宿主应用的配置界面修改二进制路径。

### 编译

```bash
cd macos/CopyEverywhereServer
swift build
```

Release 构建：

```bash
swift build -c release
```

### 启动

```bash
swift run CopyEverywhereServer
```

应用启动后在菜单栏显示图标，点击打开控制面板可以启动/停止/重启 Go 服务器并查看日志。

### 配置

在面板的 Config 标签页填写服务器参数：

| 字段 | 环境变量 | 默认值 |
|------|---------|--------|
| Port | `PORT` | `8080` |
| Bind Address | `BIND_ADDRESS` | `0.0.0.0` |
| Storage Path | `STORAGE_PATH` | `~/Library/Application Support/CopyEverywhereServer/data` |
| TTL (hours) | `TTL_HOURS` | `1` |
| Auth Enabled | `AUTH_ENABLED` | `false` |
| Access Token | `ACCESS_TOKEN` | — |

配置变更需要重启服务器才能生效。配置文件存储于 `~/Library/Application Support/CopyEverywhereServer/config.json`。

### 项目结构

```
Package.swift
Sources/CopyEverywhereServer/
  CopyEverywhereServerApp.swift   # @main 入口 + AppDelegate
  MenuBarView.swift               # 状态展示 + 启动/停止控制 + 日志视图
  ServerConfig.swift              # 配置持久化（端口、路径、认证等）
  ServerProcess.swift             # Foundation.Process 子进程生命周期管理
```

---

## 传输模式说明

### LAN Server 模式

```
[macOS 客户端] ──REST/SSE──► [Go 中继服务器] ◄──REST/SSE── [其他设备]
```

需要先运行 CopyEverywhereServer（或独立部署 Go 服务器）。客户端通过 mDNS 自动发现局域网内的服务器。

### Bluetooth 模式

```
[macOS 设备] ──RFCOMM── [其他设备]
```

无需服务器，两设备直接通过蓝牙 RFCOMM 点对点传输。线上协议：换行符分隔的 JSON 头 + 原始内容字节，与 Windows / Android 端完全兼容。
