# PRD: Embedded Server

## Introduction

Merge the standalone Go relay server into the macOS and Windows client apps, turning each desktop client into a "full node" that can both serve and consume clips. This eliminates the need for the separate CopyEverywhereServer host app and simplifies deployment — users install one app, toggle the server on, and they're ready to go. Android is explicitly excluded; mobile devices remain pure clients.

## Goals

- Eliminate the standalone CopyEverywhereServer app — one app does everything
- Desktop clients can optionally host the relay server as an embedded subprocess
- Server is off by default; users enable it in settings when they want to host
- When enabled, auto-connect to localhost but allow switching to a remote server
- Full server management panel: status, logs, storage stats, connected devices
- Pre-compiled Go binary bundled inside the app for zero-config setup

## User Stories

### US-069: macOS — Migrate ServerProcess into client app
**Description:** As a macOS user, I want the CopyEverywhere client to manage the Go server subprocess so I don't need a separate server host app.

**Acceptance Criteria:**
- [ ] `ServerProcess` class copied from CopyEverywhereServer into CopyEverywhere sources
- [ ] `ServerProcess` adapted to work within the client app's `@MainActor` context
- [ ] `binaryPath` defaults to a bundled `copyeverywhere-server` binary next to the client executable
- [ ] `start()` / `stop()` / `restart()` work correctly from the client app
- [ ] Log capture (stdout/stderr) works, max 500 lines retained
- [ ] Graceful shutdown via SIGTERM on app quit (`applicationWillTerminate`)
- [ ] `swift build` succeeds

### US-070: macOS — Migrate ServerConfig into client app
**Description:** As a macOS user, I want server settings stored alongside my client config so everything is in one place.

**Acceptance Criteria:**
- [ ] `ServerConfig` class copied from CopyEverywhereServer into CopyEverywhere sources
- [ ] Config persisted to `~/Library/Application Support/CopyEverywhere/server-config.json` (separate from client config)
- [ ] Properties: `port` (default 8080), `storagePath` (default `~/Library/Application Support/CopyEverywhere/server-data`), `bindAddress` (default `0.0.0.0`), `ttlHours` (default 24), `authEnabled` (default false), `accessToken`, `maxClipSizeMB` (default 50)
- [ ] `environment` computed property generates the env dict for subprocess
- [ ] `save()` / `load()` / `refreshUsedSpace()` work correctly
- [ ] `swift build` succeeds

### US-071: macOS — Server toggle and auto-connect
**Description:** As a macOS user, I want a toggle to enable/disable the embedded server, and when enabled, automatically connect to it.

**Acceptance Criteria:**
- [ ] `serverEnabled` boolean persisted in ServerConfig (default `false`)
- [ ] `autoStartServer` boolean persisted in ServerConfig (default `false`)
- [ ] When `serverEnabled` toggled ON: start the subprocess, set `hostURL` to `http://localhost:<port>`
- [ ] When `serverEnabled` toggled OFF: stop the subprocess, keep `hostURL` as-is (user may switch to remote)
- [ ] If `autoStartServer` is true, start server on app launch
- [ ] User can manually override `hostURL` to point to a remote server even when local server is running
- [ ] `swift build` succeeds

### US-072: macOS — Server configuration UI
**Description:** As a macOS user, I want to configure the embedded server from the same settings panel I use for client config.

**Acceptance Criteria:**
- [ ] New "Server" section in ConfigView, visible below the existing transfer mode sections
- [ ] Toggle: "Enable embedded server" (binds to `serverEnabled`)
- [ ] When enabled, show server config fields: Port, Bind Address, Storage Path, TTL (hours), Max Clip Size (MB)
- [ ] Toggle: "Require authentication" with Access Token field (shown when auth enabled)
- [ ] Toggle: "Auto-start server on launch"
- [ ] "Apply & Restart Server" button (saves config, restarts subprocess if running)
- [ ] Fields disabled when server is not enabled
- [ ] `swift build` succeeds

### US-073: macOS — Server management panel
**Description:** As a macOS user, I want a full management panel showing server status, logs, storage usage, and connected devices.

**Acceptance Criteria:**
- [ ] Server status indicator in MainPanelView header area: green dot = running, red dot = stopped, gray dot = disabled
- [ ] Start / Stop / Restart buttons (contextual: show Start when stopped, Stop+Restart when running)
- [ ] Expandable log viewer showing last 500 lines of server output, auto-scrolling
- [ ] Storage stats: used space (from `refreshUsedSpace()`), storage path displayed
- [ ] Connected devices list: fetched via `GET /api/v1/devices` from the local server (only when running)
- [ ] Panel section hidden when `serverEnabled` is false
- [ ] `swift build` succeeds

### US-074: macOS — mDNS broadcast from embedded server
**Description:** As a macOS user hosting the server, I want other devices to discover my server via mDNS automatically.

**Acceptance Criteria:**
- [ ] When embedded server starts, the Go binary's built-in mDNS broadcast activates (already in server code)
- [ ] Verify that other clients (macOS, Windows, Android) discover the embedded server via mDNS
- [ ] When server stops, mDNS deregisters (already handled by Go server's SIGTERM handler)
- [ ] No duplicate mDNS registrations on restart
- [ ] `swift build` succeeds

### US-075: macOS — Remove standalone CopyEverywhereServer app
**Description:** As a developer, I want to remove the standalone server host app since its functionality is now in the client.

**Acceptance Criteria:**
- [ ] `macos/CopyEverywhereServer/` directory deleted
- [ ] References to CopyEverywhereServer removed from CLAUDE.md architecture section
- [ ] CLAUDE.md updated to document the embedded server architecture in the client app
- [ ] `swift build` succeeds for CopyEverywhere

### US-076: Windows — Add ServerProcess management
**Description:** As a Windows user, I want the CopyEverywhere WPF app to manage the Go server subprocess.

**Acceptance Criteria:**
- [ ] New `Services/ServerProcess.cs` class using `System.Diagnostics.Process`
- [ ] Properties: `IsRunning`, `LogLines` (ObservableCollection, max 500)
- [ ] Methods: `Start()`, `Stop()`, `Restart()`
- [ ] Stdout/stderr captured via `OutputDataReceived` / `ErrorDataReceived` events
- [ ] `BinaryPath` defaults to `copyeverywhere-server.exe` next to the client executable
- [ ] Environment variables forwarded from ServerConfig
- [ ] Process killed on app exit (`Application.Current.Exit` handler)
- [ ] `dotnet build` succeeds

### US-077: Windows — Add ServerConfig persistence
**Description:** As a Windows user, I want server settings stored alongside my client config.

**Acceptance Criteria:**
- [ ] New `Services/ServerConfig.cs` class (INotifyPropertyChanged)
- [ ] Properties: `Port` (default 8080), `StoragePath` (default `%APPDATA%/CopyEverywhere/server-data`), `BindAddress` (default `0.0.0.0`), `TtlHours` (default 24), `AuthEnabled` (default false), `AccessToken`, `MaxClipSizeMB` (default 50)
- [ ] `ServerEnabled` (default false), `AutoStartServer` (default false)
- [ ] Config persisted to `%APPDATA%/CopyEverywhere/server-config.json`
- [ ] `GetEnvironment()` method returns `Dictionary<string, string>` for subprocess
- [ ] `Save()` / `Load()` / `RefreshUsedSpace()` methods
- [ ] `dotnet build` succeeds

### US-078: Windows — Server toggle and auto-connect
**Description:** As a Windows user, I want a toggle to enable/disable the embedded server, and when enabled, automatically connect to it.

**Acceptance Criteria:**
- [ ] When `ServerEnabled` toggled ON: start subprocess, set `HostUrl` to `http://localhost:<port>`
- [ ] When `ServerEnabled` toggled OFF: stop subprocess, keep `HostUrl` as-is
- [ ] If `AutoStartServer` is true, start server on app launch
- [ ] User can manually override `HostUrl` to point to a remote server
- [ ] `dotnet build` succeeds

### US-079: Windows — Server configuration UI
**Description:** As a Windows user, I want to configure the embedded server from the same settings panel.

**Acceptance Criteria:**
- [ ] New "Server" section in MainWindow XAML, below existing config sections
- [ ] CheckBox: "Enable embedded server" (binds to `ServerEnabled`)
- [ ] When enabled, show fields: Port, Bind Address, Storage Path (with Browse button), TTL, Max Clip Size
- [ ] CheckBox: "Require authentication" with PasswordBox for token
- [ ] CheckBox: "Auto-start server on launch"
- [ ] "Apply & Restart Server" button
- [ ] Fields disabled when server is not enabled
- [ ] `dotnet build` succeeds

### US-080: Windows — Server management panel
**Description:** As a Windows user, I want a management panel showing server status, logs, storage, and connected devices.

**Acceptance Criteria:**
- [ ] Server status indicator: colored dot (green/red/gray) + status text
- [ ] Start / Stop / Restart buttons (contextual)
- [ ] Expandable log viewer (ScrollViewer + TextBlock, auto-scroll, max 500 lines)
- [ ] Storage stats: used space + storage path
- [ ] Connected devices list fetched from local server `GET /api/v1/devices`
- [ ] Section hidden when `ServerEnabled` is false
- [ ] `dotnet build` succeeds

### US-081: Windows — mDNS broadcast verification
**Description:** As a Windows user hosting the server, I want other devices to discover my server via mDNS.

**Acceptance Criteria:**
- [ ] When embedded server starts, Go binary's mDNS broadcast activates (already in server code)
- [ ] Verify other clients discover the Windows-hosted embedded server
- [ ] mDNS deregisters on server stop (Go handles SIGTERM/process exit)
- [ ] `dotnet build` succeeds

### US-082: Documentation and CLAUDE.md update
**Description:** As a developer, I want CLAUDE.md updated to reflect the new embedded server architecture.

**Acceptance Criteria:**
- [ ] Architecture section updated: macOS and Windows clients now embed the server as an optional subprocess
- [ ] CopyEverywhereServer references removed or marked as removed
- [ ] New conventions added for ServerProcess/ServerConfig patterns on both platforms
- [ ] Android exclusion documented
- [ ] Binary bundling strategy documented

## Functional Requirements

- FR-1: macOS client must manage the Go server binary as a child `Process`, mirroring the existing CopyEverywhereServer `ServerProcess` pattern
- FR-2: Windows client must manage the Go server binary via `System.Diagnostics.Process` with stdout/stderr capture
- FR-3: Server is disabled by default; user must explicitly enable it in settings
- FR-4: When server is enabled, client auto-sets `hostURL` to `http://localhost:<port>` but allows manual override to a remote server
- FR-5: Server config (port, bind address, storage path, TTL, auth, max clip size) persisted separately from client config on both platforms
- FR-6: Full management panel on both platforms: status indicator, start/stop/restart, log viewer, storage stats, connected devices list
- FR-7: Auto-start server on app launch is optional (off by default)
- FR-8: Graceful shutdown: macOS via SIGTERM, Windows via process kill on app exit
- FR-9: mDNS service broadcast handled by the Go binary itself (no client-side mDNS needed)
- FR-10: Go binary bundled alongside the client executable (pre-compiled, zero config)
- FR-11: The standalone `macos/CopyEverywhereServer/` app is removed after macOS migration is complete
- FR-12: Android client is unaffected — no server functionality added

## Non-Goals

- No server functionality on Android (mobile devices are pure clients)
- No embedding Go via FFI/CGO — the server remains a separate subprocess
- No web-based admin dashboard for the server
- No automatic Go binary updates or version management
- No multi-server load balancing or clustering
- No server-to-server relay or federation

## Technical Considerations

- **Go binary path**: macOS — sibling to the Swift executable in the app bundle. Windows — sibling `copyeverywhere-server.exe` next to the .NET executable.
- **Config isolation**: Server config stored in a separate JSON file from client config to avoid conflicts and keep concerns separated.
- **Port conflicts**: If the configured port is in use, the Go binary will fail to start — surface this error clearly in the management panel logs.
- **Storage path**: Defaults under the app's Application Support (macOS) or AppData (Windows) directory. User can change via config.
- **SQLite single-writer**: Unchanged — only one Go server process should run at a time per storage path.
- **Process lifecycle edge cases**: Handle crash recovery (detect unexpected termination, update UI), prevent double-start, handle config changes requiring restart.
- **Existing CopyEverywhereServer code**: `ServerProcess` and `ServerConfig` from `macos/CopyEverywhereServer/` are the reference implementation. Copy and adapt, don't rewrite from scratch.

## Success Metrics

- macOS and Windows users can enable, configure, and manage the server from within the client app
- No separate app installation needed to host the server
- Other devices (including Android) can discover and connect to the embedded server via mDNS
- Standalone CopyEverywhereServer app fully removed from the codebase
- Zero regressions in existing client functionality (send, receive, Bluetooth, SSE, queue)

## Open Questions

- Should there be a visual indicator in the menu bar / system tray icon itself showing server status (e.g., different icon when hosting)?
- Should the log viewer support search/filter for easier debugging?
- Should we add a "Reset server data" button to clear the storage path?
