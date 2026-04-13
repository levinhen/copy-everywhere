# CopyEverywhere — Windows 客户端

基于 .NET 8 WPF 的 Windows 系统托盘应用，支持通过 LAN 中继服务器或蓝牙 RFCOMM 在设备间传输剪贴板内容与文件。

## 环境要求

| 依赖 | 最低版本 |
|------|---------|
| Windows | 10 (build 19041 / 20H1) 或更高 |
| .NET SDK | 8.0 |
| Git | 任意版本 |

> 不需要安装 Visual Studio，但可以用于调试。

## 编译

```bash
cd windows/CopyEverywhere
dotnet restore
dotnet build
```

编译产物位于 `bin/Debug/net8.0-windows10.0.19041.0/`。

### 发布为单文件可执行程序

```bash
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true
```

产物位于 `bin/Release/net8.0-windows10.0.19041.0/win-x64/publish/CopyEverywhere.exe`。

## 启动

### 开发模式

```bash
dotnet run
```

### 直接运行

双击编译/发布后生成的 `CopyEverywhere.exe`，程序会最小化到系统托盘，不会出现在任务栏。

## 配置

首次启动后，点击系统托盘图标打开主窗口，在配置区填写以下信息：

| 字段 | 说明 |
|------|------|
| Host URL | 中继服务器地址，例如 `http://192.168.1.100:8080` |
| Access Token | 服务器开启认证时所需的 Bearer Token，不需要认证时留空 |
| Device Name | 本机设备名称，用于在设备列表中识别 |
| Target Device | 发送目标设备 ID，留空则广播给所有设备 |
| Transfer Mode | `LAN Server`（通过中继）或 `Bluetooth`（直连） |
| Floating Ball | 是否显示悬浮球窗口（支持拖放发送） |

配置持久化存储于 `%APPDATA%\CopyEverywhere\config.json`，Access Token 单独存入 Windows 凭据管理器。

## 使用方式

- **发送剪贴板文字**：在主窗口点击"发送"，或按 `Ctrl+V`（当主窗口获得焦点时）
- **发送文件**：拖拽文件到托盘图标或悬浮球
- **接收内容**：应用在后台通过 SSE 长连接监听服务器推送，收到内容后自动写入剪贴板并弹出通知
- **LAN 服务发现**：配置界面自动通过 mDNS 扫描局域网中的 CopyEverywhere 服务器

## 传输模式

### LAN Server 模式

需要先部署 [Go 中继服务器](../../server/)，客户端通过 REST API + SSE 与服务器通信。

### Bluetooth 模式

无需服务器，直接通过蓝牙 RFCOMM 与其他设备点对点传输。需要：

1. 在"配置"界面切换到 Bluetooth 模式
2. 点击"扫描"发现附近设备
3. 选择目标设备并配对
4. 配对成功后即可发送/接收

## 项目结构

```
CopyEverywhere.csproj          # 项目配置，目标框架 net8.0-windows10.0.19041.0
App.xaml / App.xaml.cs         # 应用入口，初始化托盘图标
MainWindow.xaml / .xaml.cs     # 主窗口（配置 + 队列 + 发送）
FloatingBallWindow.xaml / .cs  # 悬浮球窗口
Services/
  ApiClient.cs                 # REST API 客户端（含分块上传、进度回调）
  ConfigStore.cs               # 配置持久化与设备状态
  SendService.cs               # 统一发送入口（LAN / 蓝牙路由）
  BluetoothService.cs          # WinRT RFCOMM 服务端/客户端
  BluetoothSession.cs          # 蓝牙会话（握手 + 传输状态机）
  MdnsDiscoveryService.cs      # mDNS 服务发现（Zeroconf）
```

## 主要依赖

| 包 | 版本 | 用途 |
|----|------|------|
| `Hardcodet.NotifyIcon.Wpf` | 1.1.0 | 系统托盘图标 |
| `CredentialManagement` | 1.0.2 | Windows 凭据管理器（存储 Token） |
| `Microsoft.Toolkit.Uwp.Notifications` | 7.1.3 | Toast 通知 |
| `Zeroconf` | 3.6.11 | mDNS 服务发现 |

蓝牙功能使用 WinRT 原生 API（`Windows.Devices.Bluetooth.Rfcomm`），无需额外 NuGet 包。
