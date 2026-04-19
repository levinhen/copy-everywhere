# PRD: LAN Server Auto-Discovery Reliability

## 1. Introduction / Overview

CopyEverywhere 的局域网模式理论上已经具备 mDNS/Bonjour 自动发现能力，但当前产品行为并没有真正解决用户在 DHCP 网络下的实际痛点。只要 server 的 IP 变化，client 侧就经常退化回“手动输入 IP/端口”，这让局域网模式的日常使用成本非常高。

仓库现状并不是“完全没有发现能力”：

- Go server 已经会广播 `_copyeverywhere._tcp`
- macOS、Windows、Android 都已经有各自的发现实现
- 配置页里也已经能看到 discovered servers

真正缺的是一个稳定、统一、可恢复的产品契约：

1. client 应该如何识别“这是同一台 server，只是 IP 变了”
2. 当局域网里只有一个 server 时，client 应该自动接管，而不是等用户手填 URL
3. 当局域网里有多个 server 时，不应该强行弹窗打断用户，而应在配置页中让用户自己选择
4. app 重启后，client 应该重新发现并恢复连接，而不是继续依赖陈旧的 IP

本次迭代目标不是重新设计传输协议，而是把现有 mDNS 能力补齐成可依赖的产品行为，让 DHCP 网络下的 server 发现和连接恢复变成“默认可用”。

## 2. Goals

- 消除在 DHCP 局域网环境下频繁手动输入 server IP 的需求。
- 当局域网内只有一个可用 CopyEverywhere server 时，client 自动发现并自动连接。
- 当局域网内存在多个 server 时，不弹窗打断用户，只在配置页中展示并让用户手动选择。
- 让 client 记住“选中过哪台 server”，并在 app 重启后基于稳定标识重新发现，即使 IP 已变化也能恢复连接。
- 保留手动填写 Host URL 的兜底能力，但不再把它作为 DHCP 网络的主路径。

## 3. User Stories

User stories continue the existing numbering from the Windows embedded server iteration (last story was US-089).

### US-090: Server — stable server identity for discovery
**Description:** As a client developer, I need each LAN server to expose a stable identity so clients can recognize the same server even when DHCP changes its IP address.

**Acceptance Criteria:**
- [ ] Go server exposes a stable `server_id` that persists across restarts on the same host unless storage/config is explicitly reset
- [ ] `server_id` is included in mDNS TXT records together with existing metadata such as `version` and `auth`
- [ ] `/health` or another lightweight existing endpoint returns the same `server_id` for verification after the client connects
- [ ] Stable identity is documented for all clients as the canonical selection key; `host:port` is not treated as durable identity
- [ ] `go test ./...` passes

### US-091: Shared discovery contract — auto-select and restore rules
**Description:** As a user, I want all clients to follow the same discovery rules so the product behaves predictably across macOS, Windows, and Android.

**Acceptance Criteria:**
- [ ] Define one shared selection contract for LAN mode:
  fresh state + exactly one discovered server => auto-select and auto-connect
  fresh state + multiple discovered servers => no auto-select, no popup, wait for user to choose in config
  previously selected `server_id` rediscovered on app restart => auto-restore selection and update host URL
- [ ] If the previously selected `server_id` is not rediscovered at startup, the client keeps the prior/manual URL as a fallback and surfaces that discovery did not restore the selection
- [ ] Discovery never silently overwrites a user’s explicit manual selection with some other server when multiple servers are present
- [ ] Contract is written down in repo docs/comments so platform implementations stay aligned

### US-092: macOS — startup discovery and selection restore
**Description:** As a macOS user, I want the menu bar app to reconnect to my LAN server after restart without making me re-enter a changed DHCP address.

**Acceptance Criteria:**
- [ ] macOS persists the selected server by stable `server_id` plus last known display metadata
- [ ] On app launch, LAN mode starts discovery automatically without requiring the user to open Config
- [ ] If exactly one server is discovered and there is no prior selection, macOS auto-fills `hostURL` and reconnects
- [ ] If a previously selected `server_id` is rediscovered at a different host/port, macOS updates `hostURL` automatically
- [ ] If multiple servers are discovered and no prior selection exists, the app does not show a modal/popup chooser
- [ ] Config UI clearly shows discovered servers, which one is currently selected, and whether the current connection is auto-discovered or manual
- [ ] `swift build` succeeds

### US-093: Windows — startup discovery and selection restore
**Description:** As a Windows user, I want the tray app to recover from server IP changes after restart instead of forcing me to reconfigure the host URL.

**Acceptance Criteria:**
- [ ] Windows persists the selected server by stable `server_id` instead of only storing `host:port`
- [ ] On app launch, LAN mode starts discovery automatically
- [ ] If exactly one server is discovered and there is no prior selection, Windows auto-fills `HostUrl` and reconnects
- [ ] If a previously selected `server_id` is rediscovered at a different IP/port, Windows updates `HostUrl` automatically
- [ ] If multiple servers are present and there is no prior selection, the app does not interrupt the user with a dialog
- [ ] Main/config UI shows discovered servers, current selection, and whether the current endpoint came from auto-discovery or manual fallback
- [ ] `dotnet build` succeeds on a Windows host

### US-094: Android — startup/service discovery and selection restore
**Description:** As an Android user, I want the app to rediscover my LAN server after app restart so DHCP changes do not force me to edit the config again.

**Acceptance Criteria:**
- [ ] Android persists the selected server by stable `server_id`
- [ ] When the app enters LAN mode and the relevant app/service lifecycle starts, discovery begins automatically without requiring manual scan input
- [ ] If exactly one server is discovered and there is no prior selection, Android auto-fills `hostUrl` and reconnects
- [ ] If the selected `server_id` is rediscovered at a new IP/port after app restart, Android updates `hostUrl` automatically
- [ ] If multiple servers are present and no prior selection exists, Android does not show a blocking chooser; selection remains in Config screen
- [ ] Config screen shows discovered servers, current selection, and manual fallback state
- [ ] `./gradlew assembleDebug` succeeds

### US-095: Shared UX — config-driven multi-server selection, no popup
**Description:** As a user, I want multi-server handling to stay calm and explicit so discovery helps me without interrupting me.

**Acceptance Criteria:**
- [ ] When more than one server is discovered and no prior selection exists, the user sees a passive status such as `Found multiple servers. Open Config to choose one.`
- [ ] No platform shows a modal dialog, forced picker, or startup interruption for multi-server discovery
- [ ] Config screens on all three clients list the discovered servers with enough information to distinguish them, including at minimum display name, host, port, auth requirement, and selection state
- [ ] The selected server can be changed explicitly from the Config screen
- [ ] UI copy is aligned across macOS, Windows, and Android

### US-096: Shared fallback — manual URL remains first-class
**Description:** As a user, I want manual host configuration to remain available when discovery fails or my network blocks mDNS.

**Acceptance Criteria:**
- [ ] All clients keep manual Host URL editing available in LAN mode
- [ ] If startup discovery finds no matching selected server, the client does not erase the manual URL already stored
- [ ] UI distinguishes:
  auto-discovered active server
  restored selected server
  manual fallback URL
  discovery unavailable / no servers found
- [ ] A user can switch from auto-discovered selection back to manual URL deliberately
- [ ] Discovery failures are non-fatal and do not block send/receive when manual URL is valid

### US-097: Diagnostics, regression coverage, and documentation
**Description:** As a developer, I need enough logging and tests to debug discovery failures and prevent DHCP-related regressions.

**Acceptance Criteria:**
- [ ] Server logs its `server_id` on startup and logs mDNS advertisement start/stop with enough detail to diagnose duplicate or missing registrations
- [ ] Clients log discovery lifecycle events: search start, server resolved, auto-selected unique server, restored selected `server_id`, multi-server deferred to config, no match found
- [ ] Automated coverage exists for the shared selection rules where practical:
  unique discovered server auto-selects
  persisted `server_id` restores when host changes
  multiple servers do not trigger auto-selection on fresh state
  no discovered match preserves manual fallback
- [ ] Manual verification checklist exists for macOS, Windows, and Android using a DHCP-style host change scenario
- [ ] AGENTS/README/source-of-truth docs are updated so the intended discovery contract is explicit

## 4. Functional Requirements

- FR-1: Every LAN server must expose a stable `server_id` that survives DHCP address changes.
- FR-2: `server_id` must be discoverable before or immediately after connection using lightweight metadata already appropriate for startup flows.
- FR-3: A client in LAN mode must automatically start discovery during startup or equivalent mode-entry lifecycle, not only when the Config page is open.
- FR-4: If exactly one server is discovered and the user has no prior selected server, the client must auto-select it and update the effective host URL.
- FR-5: If the user previously selected a server, the client must prefer matching that persisted `server_id` over host/port string equality.
- FR-6: If the selected `server_id` is rediscovered on a different IP or port after app restart, the client must update the effective host URL automatically.
- FR-7: If multiple servers are discovered and there is no prior selection, the client must not auto-pick one.
- FR-8: Multi-server discovery must not block startup with a modal or forced selection flow.
- FR-9: Config UI must show the discovered server list and allow explicit selection on all three platforms.
- FR-10: Manual Host URL entry must remain available as a fallback on all three platforms.
- FR-11: Discovery must not erase a valid manual fallback URL unless the user explicitly changes selection or the product contract says an exact selected `server_id` match has been restored.
- FR-12: The UI must indicate whether the active connection came from auto-discovery, restored selection, or manual fallback.
- FR-13: Discovery errors or absence of mDNS results must be non-fatal for LAN mode.
- FR-14: This iteration only guarantees re-discovery and restore on app restart or mode re-entry; it does not require live in-session hot switching when the server IP changes mid-session.

## 5. Non-Goals (Out of Scope)

- No redesign of the LAN transport, upload flow, SSE flow, or targeted delivery flow.
- No replacement of mDNS with a new discovery mechanism such as broadcast UDP probing, cloud rendezvous, or QR-based pairing.
- No modal startup wizard or popup chooser for multiple discovered servers.
- No promise of seamless hot failover while the app is already running and connected; this iteration only covers startup/mode-entry restore.
- No removal of manual Host URL entry.
- No server fleet management, priority ranking, or auto-promotion among multiple discovered servers beyond explicit user choice.

## 6. Design Considerations

- 这个功能的目标是“减少打扰”，不是“增加一层智能弹窗”。
- 多 server 情况下，产品应该克制，只给出状态提示，把真正的选择动作放到用户主动打开的配置页里。
- 发现列表里需要足够的辨识信息，避免多个 server 只显示同名服务导致无法区分。
- “当前连接来源”应该可见，否则用户不知道自己现在连的是自动发现结果还是残留的手填地址。
- 如果未来要支持更强的运行时自动切换，本次 PRD 的 `server_id` 契约应该可直接复用，不要只为这次做一次性逻辑。

## 7. Technical Considerations

- 现有三端都已有 discovery 基础设施：
  macOS 使用 `NWBrowser`
  Windows 使用 `Zeroconf`
  Android 使用 `NsdManager`
- 现有 server mDNS TXT 记录只有 `version` 和 `auth`，对“跨 DHCP 识别同一台 server”还不够；本次建议增加稳定 `server_id`
- 当前很多实现把 `host:port` 当作 discovered item 的主键，这适合展示，不适合做持久选择键
- 需要谨慎处理 discovery 生命周期，避免只在 Config 页面打开时才发现 server，导致“主流程一直依赖旧 IP”
- 若平台 API 只能拿到服务名和新地址，也必须在连接后通过 `/health` 等轻量接口确认 `server_id`，避免误认其他 server
- 如果 embedded server 与独立 Go server 共用同一发现协议，client 侧无需区分两者来源，只按统一 contract 工作

## 8. Success Metrics

- 在单 server、DHCP 会变更 IP 的家庭/办公室局域网中，用户在 app 重启后无需再次手填 IP 即可恢复连接。
- 在 fresh install 或清空选择状态后，单 server 环境下三端 client 都能自动连接。
- 多 server 环境下不出现误连到错误 server 的情况。
- 手动输入 IP 的使用频率显著下降，成为 mDNS 失败时的兜底路径，而不是默认工作流。
- Discovery 相关问题能从 UI 状态和日志中直接判断是“未发现”、“多 server 未选择”还是“已回退到 manual URL”。

## 9. Open Questions

- `server_id` 应该持久化在 `STORAGE_PATH` 下的单独文件、server config 中，还是由已有设备/实例信息推导生成？
- Config 列表里是否还需要显示最近成功连接时间，帮助用户区分多个 server？
- Android 的自动发现启动点应以 Activity 进入 LAN 模式为准，还是应由前台服务在 LAN 模式下独立维护更长期的发现？
- 当用户手动输入了一个 URL，但同时发现到了唯一 server，首次启动是否应该自动覆盖到 discovered server，还是只在“没有显式 manual override”时才接管？

## 10. Recommended Product Decision

本次迭代采用“在现有 mDNS 基础上补齐稳定身份和统一选择规则”的路径：

- server 新增稳定 `server_id`
- client 用 `server_id` 记住已选 server，而不是记住 IP
- 单 server 自动连接
- 多 server 不弹窗，只在配置页里选
- 重启后自动重新发现并恢复
- manual URL 永远保留为兜底

这条路径改动集中、风险可控，并且直接命中 DHCP 网络下“IP 总变、每次都要重新填”的核心问题。
