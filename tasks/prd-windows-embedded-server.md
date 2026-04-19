# PRD: Windows Embedded Server (US-083 … US-089)

## Overview

The Windows WPF client currently connects only to **external** relay servers — the user must run the Go server separately (or use a remote host) and manually enter its URL. The macOS client gained an optional embedded server in the Embedded Server iteration (US-069–US-075), but the Windows equivalent was never implemented.

This iteration ports that capability to Windows: the WPF client gains a `ServerProcess` service that manages `copyeverywhere-server.exe` as a child process, a `ServerConfig` model that persists server settings, and UI sections for configuration, management, and live logging. The user can optionally register the app to launch at Windows startup.

## Goals

- Windows users can host a relay server from the same tray app they use to send/receive content.
- Enabling the embedded server automatically points the client's Host URL at `http://localhost:<port>`.
- Server config (port, storage path, auth, TTL, etc.) is editable without leaving the app.
- Live stdout/stderr logs are visible in the panel for debugging.
- Optional "Run at Windows startup" setting mirrors the macOS Launch at Login feature.

## Non-Goals

- Cross-platform changes (macOS, Android, server Go code) are out of scope.
- Bundling the Go binary inside the EXE (e.g., embedded resource) — binary ships alongside the EXE.
- Automatic server updates or version management.
- Windows Service installation (runs as a tray process, not a background service).

## Binary distribution convention

`copyeverywhere-server.exe` must reside in the same directory as `CopyEverywhere.exe`. It is compiled separately (`go build -o copyeverywhere-server.exe .` from `server/`). `ServerProcess.BinaryPath` defaults to `Path.Combine(AppContext.BaseDirectory, "copyeverywhere-server.exe")`. If the file is missing, enabling the server shows an error and aborts — no silent failure.

---

## User Stories

### US-083 — Windows: ServerProcess service

**As a** Windows user,  
**I want** the WPF app to manage the Go server subprocess,  
**so that** I can host the relay server from my Windows machine without a separate tool.

#### Acceptance Criteria

- New `Services/ServerProcess.cs` class implementing `INotifyPropertyChanged`.
- `IsRunning: bool` — updated when process starts and when the `Exited` event fires.
- `LogLines: ObservableCollection<string>` (max 500 lines; when the 501st line is added, the oldest is removed).
- `BinaryPath: string` — defaults to `Path.Combine(AppContext.BaseDirectory, "copyeverywhere-server.exe")`.
- `ServerConfig` reference injected via constructor; used by `GetEnvironment()`.
- `Start()`:
  - Checks `File.Exists(BinaryPath)`; if missing, logs an error line and returns without setting `IsRunning`.
  - Creates a new `Process` with `RedirectStandardOutput = true`, `RedirectStandardError = true`, `UseShellExecute = false`, `CreateNoWindow = true`.
  - Populates `StartInfo.Environment` from `GetEnvironment()` (merges over the inherited environment).
  - Enables `EnableRaisingEvents = true` and subscribes to `OutputDataReceived`, `ErrorDataReceived`, and `Exited`.
  - Starts the process; sets `IsRunning = true`.
- `OutputDataReceived` / `ErrorDataReceived` handlers append non-null lines to `LogLines` via `Application.Current.Dispatcher.Invoke` (UI-thread safety). Trim to 500 lines in the same dispatch call.
- `Exited` handler: sets `IsRunning = false`, appends `"[server exited with code N]"` to `LogLines` via Dispatcher.
- `Stop()`: if process is running, calls `process.Kill(entireProcessTree: true)`; sets `IsRunning = false`. No-op if already stopped.
- `Restart()`: calls `Stop()`, waits 500 ms (`await Task.Delay(500)`), calls `Start()`.
- `GetEnvironment()` delegates to `ServerConfig.GetEnvironment()`.
- `Application.Current.Exit` event handler registered in constructor calls `Stop()`.
- `dotnet build` succeeds.

---

### US-084 — Windows: ServerConfig persistence

**As a** Windows user,  
**I want** server settings persisted in a dedicated config file,  
**so that** my server configuration survives restarts without touching the client config.

#### Acceptance Criteria

- New `Services/ServerConfig.cs` class implementing `INotifyPropertyChanged`.
- Properties with defaults:

  | Property | Type | Default |
  |---|---|---|
  | `Port` | `string` | `"8080"` |
  | `BindAddress` | `string` | `"0.0.0.0"` |
  | `StoragePath` | `string` | `%APPDATA%\CopyEverywhere\server-data` |
  | `TtlHours` | `int` | `24` |
  | `AuthEnabled` | `bool` | `false` |
  | `AccessToken` | `string` | `""` |
  | `MaxClipSizeMB` | `int` | `50` |
  | `ServerEnabled` | `bool` | `false` |
  | `AutoStartServer` | `bool` | `false` |

- `UsedSpaceBytes: long` property (default 0; refreshed async).
- Config file path: `Path.Combine(Environment.GetFolderPath(SpecialFolder.ApplicationData), "CopyEverywhere", "server-config.json")`.
- `GetEnvironment()` returns `Dictionary<string, string>`:
  - `PORT` → `Port`
  - `BIND_ADDRESS` → `BindAddress`
  - `STORAGE_PATH` → `StoragePath`
  - `TTL_HOURS` → `TtlHours.ToString()`
  - `AUTH_ENABLED` → `AuthEnabled ? "true" : "false"`
  - `ACCESS_TOKEN` → `AccessToken` (omitted entirely when `AuthEnabled=false` or token is empty)
  - `MAX_CLIP_SIZE_MB` → `MaxClipSizeMB.ToString()`
- `Save()`: serialises all properties to JSON (using `System.Text.Json`), writes atomically (temp file + `File.Replace`). Creates the config directory if it does not exist.
- `Load()`: deserialises from JSON. Missing file returns defaults silently.
- `RefreshUsedSpaceAsync()`: sums file sizes under `StoragePath` in a `Task.Run` background call; updates `UsedSpaceBytes` via Dispatcher on completion. No-op if directory does not exist.
- `dotnet build` succeeds.

---

### US-085 — Windows: Server toggle and auto-connect

**As a** Windows user,  
**I want** the client to automatically connect to the embedded server when I enable it,  
**so that** I don't have to copy-paste a localhost URL.

#### Acceptance Criteria

- `App.xaml.cs` creates `ServerConfig` and `ServerProcess` instances and passes them to `MainWindow`.
- On app launch (after `ServerConfig.Load()`):
  - If `AutoStartServer = true`: call `ServerProcess.Start()`.
  - If `ServerEnabled = true` (including just started): set `ConfigStore.HostUrl = $"http://localhost:{ServerConfig.Port}"` and save `ConfigStore`.
- In `MainWindow`, when the "Enable embedded server" `CheckBox` is toggled **ON**:
  - Call `ServerProcess.Start()`.
  - Set `ConfigStore.HostUrl = $"http://localhost:{ServerConfig.Port}"` and save `ConfigStore`.
  - Save `ServerConfig`.
- When toggled **OFF**:
  - Call `ServerProcess.Stop()`.
  - `HostUrl` is **not** cleared — user keeps their last-used URL.
  - Save `ServerConfig`.
- If `BinaryPath` does not exist on toggle ON: show an error `Border` ("Server binary not found at \<path\>") and revert `ServerEnabled = false`.
- Manual edits to the Host URL `TextBox` always take effect regardless of server state.
- `dotnet build` succeeds.

---

### US-086 — Windows: Server configuration UI

**As a** Windows user,  
**I want** to configure the embedded server from the same settings panel,  
**so that** I don't need a separate host app.

#### Acceptance Criteria

- New `GroupBox` with header "Embedded Server" added to `MainWindow.xaml` below the existing transfer mode section.
- `CheckBox` "Enable embedded server" at the top of the group; toggling invokes the logic from US-085.
- All child controls inside the group have `IsEnabled="{Binding ServerEnabled}"` so they grey out when the server is disabled.
- Fields:
  - "Port" label + `TextBox` bound to `ServerConfig.Port`.
  - "Bind Address" label + `TextBox` bound to `ServerConfig.BindAddress`.
  - "Storage Path" label + `TextBox` bound to `ServerConfig.StoragePath` + "Browse…" `Button` (opens `FolderBrowserDialog` and writes selected path to `ServerConfig.StoragePath`).
  - "TTL (hours)" label + `TextBox` bound to `ServerConfig.TtlHours`.
  - "Max Clip Size (MB)" label + `TextBox` bound to `ServerConfig.MaxClipSizeMB`.
  - `CheckBox` "Require authentication" bound to `ServerConfig.AuthEnabled`.
  - When `AuthEnabled=true`: "Access Token" label + `PasswordBox` (synced via `PasswordChanged` event).
  - `CheckBox` "Auto-start server on app launch" bound to `ServerConfig.AutoStartServer`.
  - `CheckBox` "Run at Windows startup" bound to `ServerConfig.RunAtWindowsStartup` (added in US-088); toggling calls `ServerConfig.SetRunAtStartup(bool)`.
- "Apply & Restart Server" `Button`:
  - Saves `ServerConfig`.
  - If `IsRunning`: calls `ServerProcess.Restart()`.
  - If not running and `ServerEnabled=true`: calls `ServerProcess.Start()`.
- `dotnet build` succeeds.

---

### US-087 — Windows: Server management panel

**As a** Windows user,  
**I want** a status panel with live logs and start/stop controls,  
**so that** I can monitor and manage the embedded server.

#### Acceptance Criteria

- "Server Status" section in `MainWindow.xaml`, positioned immediately after the configuration `GroupBox` (US-086); the entire section has `Visibility` bound to `ServerEnabled` (collapsed when false).
- Status row: small `Ellipse` (12×12, green `Fill` when `IsRunning`, red when stopped) + `TextBlock` ("Running" / "Stopped").
- Listen address `TextBlock` shows `$"{ServerConfig.BindAddress}:{ServerConfig.Port}"`; visible only when `IsRunning`.
- Storage used `TextBlock` shows `FormatBytes(ServerConfig.UsedSpaceBytes)` (same helper used elsewhere in the project). `ServerConfig.RefreshUsedSpaceAsync()` called when server starts and every 30 seconds while running (use a `DispatcherTimer`).
- Button row:
  - "Start Server" `Button` — visible when `!IsRunning`; calls `ServerProcess.Start()`.
  - "Stop Server" `Button` — visible when `IsRunning`; calls `ServerProcess.Stop()`.
  - "Restart" `Button` — visible when `IsRunning`; calls `ServerProcess.Restart()`.
- Log viewer:
  - `ScrollViewer` (max height 200) containing a `TextBlock` with `FontFamily="Consolas"`, `FontSize="11"`, text bound to `LogLines` joined with `"\n"` (or use an `ItemsControl` with `TextBlock` per line).
  - Auto-scrolls to bottom on each `LogLines.CollectionChanged` event via `ScrollViewer.ScrollToEnd()`.
- "Clear Logs" `Button` calls `ServerProcess.LogLines.Clear()`.
- `dotnet build` succeeds.

---

### US-088 — Windows: Run at Windows startup

**As a** Windows user,  
**I want** the app to launch automatically when Windows starts,  
**so that** the relay server is always available.

#### Acceptance Criteria

- `RunAtWindowsStartup: bool` property added to `ServerConfig` (default `false`), persisted in `server-config.json`.
- `SetRunAtStartup(bool enabled)` method on `ServerConfig`:
  - `enabled=true`: opens `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` with write access; sets value `"CopyEverywhere"` = `"\"<full path to CopyEverywhere.exe>\" --minimized"`.
  - `enabled=false`: opens the same key and deletes value `"CopyEverywhere"` if present; swallows `IOException` if key/value does not exist.
  - Uses `Microsoft.Win32.Registry` — no extra NuGet required.
- `CheckBox` "Run at Windows startup" in the server config UI (US-086) is bound to `RunAtWindowsStartup`; toggling calls `SetRunAtStartup(bool)` and saves `ServerConfig`.
- In `App.xaml.cs`, on startup: check `Environment.GetCommandLineArgs()` for `"--minimized"`; if present, skip `mainWindow.Show()` so the app starts directly to tray.
- `dotnet build` succeeds.

---

### US-089 — Windows: CLAUDE.md conventions update

**As a** developer,  
**I want** CLAUDE.md updated to document the new embedded server patterns,  
**so that** future agents implement consistent patterns.

#### Acceptance Criteria

- Architecture section: Windows client entry updated to note that `ServerProcess` and `ServerConfig` provide optional embedded server support when `copyeverywhere-server.exe` is present as a sibling.
- Windows conventions section gets new entries:
  - `ServerProcess` lifecycle: `Kill(entireProcessTree: true)`, `Dispatcher.Invoke` for log line appends, `AppContext.BaseDirectory` for binary path, `Application.Current.Exit` handler for cleanup.
  - `ServerConfig.GetEnvironment()` env var key mapping.
  - Atomic JSON write pattern (temp file + `File.Replace`).
  - Registry startup key: `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\CopyEverywhere`.
  - `--minimized` arg: skip `mainWindow.Show()` in `App.xaml.cs`.
  - `FolderBrowserDialog` requires `<UseWindowsForms>true</UseWindowsForms>` in csproj (or use WPF-native alternative).
- Source of truth section: active iteration points at `prd.json` and `tasks/prd-windows-embedded-server.md` (US-083 … US-089).

---

## Architecture notes

```
App.xaml.cs
  └── creates ServerConfig (Load())
  └── creates ServerProcess(serverConfig)
  └── if AutoStartServer → ServerProcess.Start()
  └── passes both to MainWindow

MainWindow
  ├── [Embedded Server GroupBox]  ← US-086
  │     Enable checkbox, Port, BindAddress, StoragePath, TTL, MaxClipSize,
  │     AuthEnabled + AccessToken, AutoStartServer, RunAtWindowsStartup,
  │     Apply & Restart button
  └── [Server Status Section]     ← US-087
        Status dot + text, Listen address, Storage used,
        Start/Stop/Restart buttons,
        Log viewer (ScrollViewer + TextBlock, Consolas, auto-scroll),
        Clear Logs button

Services/
  ServerConfig.cs    ← US-084 + US-088 (SetRunAtStartup)
  ServerProcess.cs   ← US-083
```

## Environment variable mapping (GetEnvironment)

| ServerConfig property | Env var key      | Notes                                     |
|-----------------------|------------------|-------------------------------------------|
| `Port`                | `PORT`           |                                           |
| `BindAddress`         | `BIND_ADDRESS`   |                                           |
| `StoragePath`         | `STORAGE_PATH`   |                                           |
| `TtlHours`            | `TTL_HOURS`      |                                           |
| `AuthEnabled`         | `AUTH_ENABLED`   | `"true"` / `"false"`                      |
| `AccessToken`         | `ACCESS_TOKEN`   | Omitted when `AuthEnabled=false` or empty |
| `MaxClipSizeMB`       | `MAX_CLIP_SIZE_MB` |                                         |
