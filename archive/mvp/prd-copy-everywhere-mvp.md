# PRD: Copy Everywhere MVP

## Introduction

Copy Everywhere 是一个跨设备内容传输工具，允许用户通过一个指定的中间主机，将剪贴板文本、图片及各种文件从一台设备快速传输到另一台设备。

**核心场景：** 用户在 Mac A 上复制了一段代码或一个文件，打开 Copy Everywhere App，点击"发送"，然后在 Windows B 上打开 App 点击"接收"，内容立即出现在 B 的剪贴板或指定目录中。

中间主机由用户自行指定（可以是公网 VPS、NAS 或内网服务器），负责临时暂存内容（TTL 可配置，默认 1 小时），传输全程走 TLS 加密。

**MVP 客户端平台：** macOS（Swift + SwiftUI）+ Windows（C# + WPF），两端独立原生实现，共享同一套服务端 API。

---

## Goals

- 支持剪贴板文本、富文本、图片的跨设备发送与接收
- 支持任意规模文件（小文件直传，大文件分片上传/下载）
- 通过用户指定的中间主机中转，服务端 TLS 加密传输
- macOS 原生 App（菜单栏）+ Windows 原生 App（系统托盘）
- 内容临时存储，TTL 到期后自动清理
- MVP 阶段：手动触发发送/接收，无自动监听

---

## User Stories

### US-001: 配置中间主机
**Description:** As a user, I want to configure my relay server so that all transfers go through my own infrastructure.

**Acceptance Criteria:**
- [ ] App 首次启动时显示配置界面，要求填写：Host URL、Access Token
- [ ] 配置保存到本地 Keychain
- [ ] 点击"测试连接"可验证服务端可达性并返回延迟
- [ ] 配置错误时显示具体错误信息（无法连接 / 认证失败 / 版本不兼容）
- [ ] Typecheck passes

### US-002: 发送剪贴板文本
**Description:** As a user, I want to send my clipboard text to the relay server so that another device can receive it.

**Acceptance Criteria:**
- [ ] 菜单栏图标点击后显示主面板
- [ ] 主面板显示当前剪贴板内容预览（最多 500 字符，超出截断显示）
- [ ] 点击"发送剪贴板"按钮，内容上传至中间主机
- [ ] 上传成功后显示 Clip ID（短码，如 `abc123`）及过期时间
- [ ] 失败时展示错误原因并提供重试按钮
- [ ] Verify in browser using dev-browser skill

### US-003: 接收剪贴板文本
**Description:** As a user, I want to receive text from the relay server and paste it into my clipboard so I can use it immediately.

**Acceptance Criteria:**
- [ ] 主面板显示"接收最新"按钮，拉取服务端最新一条内容
- [ ] 收到文本后自动写入本地剪贴板，并弹出通知"已复制到剪贴板"
- [ ] 若无可用内容，提示"暂无内容或已过期"
- [ ] 支持手动输入 Clip ID 精确接收指定内容
- [ ] Verify in browser using dev-browser skill

### US-004: 发送文件（小文件 < 50MB）
**Description:** As a user, I want to send a file under 50MB to the relay server in one shot.

**Acceptance Criteria:**
- [ ] 支持从 Finder 拖拽文件到 App 窗口触发发送
- [ ] 支持点击"选择文件"按钮通过文件选择器选择
- [ ] 显示上传进度条（百分比 + 速度）
- [ ] 上传完成后显示 Clip ID 及文件名、大小、过期时间
- [ ] Verify in browser using dev-browser skill

### US-005: 发送大文件（≥ 50MB）
**Description:** As a user, I want to send large files via chunked upload so that network interruptions don't require restarting from scratch.

**Acceptance Criteria:**
- [ ] 文件 ≥ 50MB 时自动切换为分片上传（分片大小 10MB）
- [ ] 显示分片进度（如"分片 3/24"）
- [ ] 支持暂停/继续上传
- [ ] 网络中断后重连可从断点续传（服务端记录已接收分片）
- [ ] Typecheck passes

### US-006: 接收文件
**Description:** As a user, I want to download a file from the relay server to a local directory.

**Acceptance Criteria:**
- [ ] 输入 Clip ID 后显示文件名、大小、类型、上传时间
- [ ] 点击"下载"弹出保存路径选择器
- [ ] 显示下载进度条（百分比 + 速度）
- [ ] 大文件自动分片下载并合并
- [ ] 下载完成后在 Finder 中高亮显示该文件
- [ ] Verify in browser using dev-browser skill

### US-007: 内容列表与管理
**Description:** As a user, I want to see a list of items I've sent so I can resend or share their IDs.

**Acceptance Criteria:**
- [ ] 主面板显示本设备发送过的内容历史（仅本地记录，包含 Clip ID、类型、时间、是否已过期）
- [ ] 点击某条记录可复制其 Clip ID 到剪贴板
- [ ] 已过期条目显示灰色并标注"已过期"
- [ ] 支持手动删除本地历史记录
- [ ] Verify in browser using dev-browser skill

### US-008: 服务端部署
**Description:** As a developer/power user, I want to deploy the relay server on my own host with a single command.

**Acceptance Criteria:**
- [ ] 提供 Docker Compose 一键部署方案
- [ ] 服务端支持环境变量配置：`ACCESS_TOKEN`、`MAX_CLIP_SIZE_MB`、`TTL_HOURS`、`STORAGE_PATH`
- [ ] 服务端提供 `/health` 端点返回版本和存储用量
- [ ] 内容 TTL 到期后自动清理，支持 cron 清理或写入时惰性清理
- [ ] 分片上传失败的文件遵循相同 TTL 清理策略，但在客户端列表中标记为"上传失败"，不允许下载
- [ ] Typecheck passes

### US-009: Windows 客户端 - 系统托盘与配置
**Description:** As a Windows user, I want a system tray app so I can quickly send and receive clipboard content.

**Acceptance Criteria:**
- [ ] App 以系统托盘图标运行，左键单击弹出主面板
- [ ] 首次启动显示配置界面（Host URL + Access Token），保存到 Windows Credential Manager
- [ ] "测试连接"按钮验证可达性
- [ ] 主面板功能与 macOS 版一致：发送剪贴板、接收最新、文件拖拽发送、历史列表
- [ ] 支持 Windows 10 (1809+) 和 Windows 11

### US-010: Windows 客户端 - 剪贴板与文件操作
**Description:** As a Windows user, I want to send/receive clipboard text and files the same way macOS users do.

**Acceptance Criteria:**
- [ ] 读写 Windows 剪贴板（`System.Windows.Clipboard`）支持纯文本和文件
- [ ] 支持从 Explorer 拖拽文件到 App 窗口
- [ ] 大文件分片上传/下载逻辑与 macOS 一致
- [ ] 下载完成后在 Explorer 中打开文件所在目录并选中文件
- [ ] 上传/下载进度条显示百分比和速度

---

## Functional Requirements

- **FR-1:** 客户端通过 HTTPS（TLS）与服务端通信，所有请求携带 Bearer Token 认证
- **FR-2:** 服务端为每条内容生成唯一 Clip ID（6位 alphanumeric），TTL 默认 3600 秒，可配置
- **FR-3:** 文本/小文件（< 50MB）使用单次 multipart/form-data 上传
- **FR-4:** 大文件（≥ 50MB）使用分片上传协议：初始化 → 逐片上传 → 合并完成
- **FR-5:** 服务端存储内容类型枚举：`text`、`image`、`file`
- **FR-6:** 客户端"接收最新"接口拉取服务端最新一条未过期内容（按上传时间倒序）
- **FR-7:** 剪贴板写入支持纯文本（`NSPasteboard.general.string`）和文件（`NSPasteboard.writeObjects`）
- **FR-8:** macOS App 以菜单栏（Menu Bar Extra）形式运行，无 Dock 图标（可在设置中切换）
- **FR-9:** 服务端 API 版本通过 `/health` 端点暴露，客户端连接时校验兼容性

---

## API 设计（MVP）

```
POST   /api/v1/clips          上传文本或小文件
GET    /api/v1/clips/latest   获取最新一条内容
GET    /api/v1/clips/:id      获取指定内容元数据
GET    /api/v1/clips/:id/raw  下载内容原始数据

POST   /api/v1/uploads/init          初始化分片上传，返回 upload_id
PUT    /api/v1/uploads/:id/parts/:n  上传第 n 个分片
POST   /api/v1/uploads/:id/complete  合并分片，生成 Clip ID

GET    /health   健康检查
```

---

## Non-Goals（MVP 范围外）

- 不支持自动监听剪贴板变化并实时推送
- 不支持端到端加密（E2EE），服务端可见明文
- 不支持多用户/团队协作（单 Token 单用户）
- 不支持 iOS / Android / Linux 客户端
- 不支持剪贴板历史浏览（仅发送历史）
- 不支持内容预览（图片缩略图等）
- 不支持 WebSocket 实时推送/通知
- 不支持服务端 Web UI 管理界面
- 不支持大文件边下载边解压（用户自行处理）

---

## Technical Considerations

### 客户端（macOS App）
- **语言/框架：** Swift + SwiftUI，使用 `MenuBarExtra` (macOS 13+)
- **网络：** URLSession，支持后台下载任务（`URLSessionDownloadTask`）
- **Keychain：** 存储 Host URL 和 Access Token
- **分片上传：** 客户端切片后顺序上传，支持暂停（取消当前任务，记录已完成分片数）

### 客户端（Windows App）
- **语言/框架：** C# + WPF（.NET 8），系统托盘使用 `NotifyIcon`
- **网络：** HttpClient，大文件使用 `StreamContent` 分片
- **凭证存储：** Windows Credential Manager（`CredentialManager` NuGet）
- **最低支持：** Windows 10 1809+

### 服务端
- **语言/框架：** Go + `net/http` 标准库 或 Gin
- **存储：** 本地文件系统（`STORAGE_PATH`），元数据存 SQLite
- **TLS：** 用户自行在反向代理（Nginx/Caddy）层终止 TLS，服务端监听 HTTP
- **清理策略：** 后台 goroutine 每 10 分钟扫描过期 clips 并删除文件；分片上传失败的文件同样遵循 TTL 清理

### 依赖
- 服务端需 Docker（用于一键部署）
- macOS 客户端最低支持 macOS 13 Ventura
- Windows 客户端最低支持 Windows 10 1809，需 .NET 8 Runtime

---

## Success Metrics

- 文本从发送到在另一台设备接收完成 < 3 秒（局域网中间主机）
- 50MB 文件上传成功率 > 99%（稳定网络环境）
- 首次配置到成功传输第一条内容 < 5 分钟
- 服务端内存占用 < 50MB（空闲状态）

---

## Resolved Decisions

| # | 问题 | 决策 |
|---|------|------|
| 1 | 大文件下载是否支持边下载边解压？ | 否，只保证文件完整性，解压交给用户 |
| 2 | 服务端是否需要 Web UI？ | 否，纯 API 服务 |
| 3 | 菜单栏/托盘是否显示待接收角标？ | 否 |
| 4 | 分片上传失败的分片保留多久？ | 与普通文件 TTL 一致；客户端列表中标记"上传失败"，不允许下载 |

## Open Questions

（暂无）