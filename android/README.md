# CopyEverywhere — Android 客户端

基于 Kotlin + Jetpack Compose 的 Android 应用，支持通过 LAN 中继服务器或蓝牙 RFCOMM 在设备间传输剪贴板内容与文件。

## 环境要求

| 依赖 | 最低版本 |
|------|---------|
| Android | 10 (API 29) |
| JDK | 11（Gradle 构建时使用）|
| Android SDK | API 35（编译目标）|
| Gradle Wrapper | 8.9（项目内置，无需单独安装）|

> 推荐使用 Android Studio Ladybug (2024.2) 或更高版本进行开发调试。也可以只安装命令行工具（`sdkmanager`）在 CI 环境中构建。

## 编译

所有构建命令均在 `android/` 目录下执行，使用项目内置的 Gradle Wrapper：

```bash
cd android
```

### Debug APK

```bash
./gradlew assembleDebug
```

产物路径：`app/build/outputs/apk/debug/app-debug.apk`

### Release APK

```bash
./gradlew assembleRelease
```

产物路径：`app/build/outputs/apk/release/app-release-unsigned.apk`

> Release 构建需要配置签名。在 `app/build.gradle.kts` 的 `signingConfigs` 块中配置 keystore，或通过 Android Studio 的 "Generate Signed APK" 向导完成签名。

### 编译检查（不生成 APK）

```bash
./gradlew build
```

### 运行单元测试

```bash
./gradlew test
```

## 部署到设备

### 通过 ADB 安装（Debug）

确保设备已开启"USB 调试"并通过 USB 连接：

```bash
adb install app/build/outputs/apk/debug/app-debug.apk
```

已安装旧版本时覆盖安装：

```bash
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

### 通过 Android Studio 一键运行

打开 `android/` 目录，选择目标设备后点击 ▶ 按钮，会自动编译并安装到设备。

### 通过 Gradle 直接安装并启动

```bash
./gradlew installDebug
adb shell am start -n com.copyeverywhere.app/.MainActivity
```

## 首次启动配置

1. 安装后打开应用，会请求"发送通知"权限（Android 13+），建议允许以接收传输通知
2. 应用可能请求"忽略电池优化"，允许后后台服务（SSE / 蓝牙）更稳定
3. 点击右上角齿轮图标进入配置界面，填写以下信息：

| 字段 | 说明 |
|------|------|
| Host URL | 中继服务器地址，例如 `http://192.168.1.100:8080` |
| Access Token | 服务器开启认证时所需的 Bearer Token（加密存储）|
| Device Name | 本机设备名称 |
| Target Device | 发送目标设备 ID，留空广播给所有设备 |
| Transfer Mode | `LAN Server`（通过中继）或 `Bluetooth`（直连）|

- 配置通过 DataStore Preferences 持久化，Access Token 使用 EncryptedSharedPreferences（Keystore 加密）存储
- 局域网内的服务器可通过"发现"功能自动扫描（mDNS）

## 使用方式

### 发送内容

- **发送剪贴板文字**：点击主界面"Send Clipboard"按钮，或通过通知栏快捷操作
- **发送文件**：从系统分享菜单选择"CopyEverywhere"发送任意文件
- **发送多文件**：支持分享菜单的多选发送（`ACTION_SEND_MULTIPLE`）

> 超过 50 MB 的文件自动切换为分块上传模式，主界面会显示上传进度。

### 接收内容

- 后台服务（`CopyEverywhereService`）通过 SSE 长连接监听服务器推送
- 收到文字内容时自动写入剪贴板并发送通知
- 收到文件时自动保存到"下载"目录并发送含"分享"操作的通知

### 蓝牙模式

1. 在配置界面切换到 Bluetooth 模式
2. 授予蓝牙权限（`BLUETOOTH_CONNECT` + `BLUETOOTH_SCAN`，Android 12+）
3. 点击"扫描"发现附近设备，选择目标设备配对
4. 配对成功后即可直接收发，无需服务器

## 后台服务

应用依赖前台服务（`foregroundServiceType="dataSync"`）保持 SSE 连接和蓝牙服务器持续运行：

- 设备重启后通过 `BootReceiver` 自动重启服务
- 服务通知常驻通知栏，显示当前运行状态和传输模式
- 通知栏快捷操作"Send Clipboard"通过 `ClipboardTrampolineActivity` 实现（Android 10+ 剪贴板访问限制的兼容方案）

## 项目结构

```
app/
  build.gradle.kts                      # 模块配置（minSdk 29, targetSdk 35）
  src/main/
    AndroidManifest.xml                 # 权限声明 + 组件注册
    java/com/copyeverywhere/app/
      MainActivity.kt                   # 主 Activity（NavHost 导航容器）
      data/
        ApiClient.kt                    # OkHttp REST 客户端（含分块上传）
        ConfigStore.kt                  # DataStore 配置持久化 + EncryptedSharedPreferences
        SseClient.kt                    # SSE 客户端（OkHttp + 指数退避重连）
        MdnsDiscoveryService.kt         # NsdManager mDNS 服务发现
        BluetoothProtocol.kt            # 蓝牙线上协议常量
        BluetoothService.kt             # BluetoothAdapter RFCOMM 服务端/客户端
        BluetoothSession.kt             # 蓝牙会话（握手 + 传输状态机）
      service/
        CopyEverywhereService.kt        # 前台服务（SSE + 蓝牙服务器宿主）
        BootReceiver.kt                 # 开机自启
        ClipboardTrampolineActivity.kt  # 剪贴板读取跳板 Activity
        ShareReceiverActivity.kt        # 系统分享接收 Activity
      ui/
        main/                           # 主界面（队列、发送、进度）
        config/                         # 配置界面
        theme/Theme.kt                  # Material 3 动态颜色主题
gradle/
  libs.versions.toml                    # 版本目录（AGP 8.7.3, Kotlin 2.0.21）
```

## 主要依赖

| 依赖 | 版本 | 用途 |
|------|------|------|
| Jetpack Compose BOM | 2024.12.01 | UI 框架 |
| OkHttp | 4.12.0 | HTTP 客户端 |
| Gson | 2.11.0 | JSON 序列化 |
| DataStore Preferences | 1.1.1 | 配置持久化 |
| Security Crypto | 1.1.0-alpha06 | EncryptedSharedPreferences |
| Navigation Compose | 2.8.5 | 界面导航 |
| Material Icons Extended | 1.7.6 | 图标库 |
