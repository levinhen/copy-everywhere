# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Source of truth

- Two iterations have shipped and are now archived — there is no active `prd.json` in the repo root right now. Historical context only:
  - **MVP (US-001 … US-017)** under [archive/mvp/](archive/mvp/) — initial clipboard-relay feature set.
  - **Queue + frictionless UX (US-018 … US-034)** under [archive/queue-and-frictionless-ux/](archive/queue-and-frictionless-ux/) — device registration, targeted queue, SSE push, drag-and-drop, auto-receive.
- When a new iteration starts, drop its fresh `prd.json` + `progress.txt` at the repo root and its PRD doc at `tasks/prd-*.md`, then update this section to point at them.
- This repo is driven by the Ralph autonomous agent loop ([scripts/ralph/ralph.sh](scripts/ralph/ralph.sh) + [scripts/ralph/CLAUDE.md](scripts/ralph/CLAUDE.md)). One commit ≈ one user story; commit messages follow `feat: [US-XXX] - [Title]`. The hard-won "do this / don't do that" list lives in the **Conventions and gotchas** section below — add to it (don't replace) when you discover a new reusable pattern.

## Architecture

Three independent codebases share a single REST contract:

- **[server/](server/)** — Go 1.22+ / Gin relay. SQLite metadata (`modernc.org/sqlite`, pure-Go, no CGO) plus a content store on disk. The server is stateless beyond `STORAGE_PATH`; clients address content by 6-char alphanumeric Clip IDs. Layout: `config/` env loader, `db/` schema + helpers, `middleware/` Bearer auth, `handlers/` (`clips.go` for single-shot, `uploads.go` for chunked), `cleanup/` background TTL goroutine, `main.go` wiring.
- **[macos/CopyEverywhere/](macos/CopyEverywhere/)** — Swift Package Manager executable target (no .xcodeproj), macOS 13+ MenuBarExtra app. State lives in `ConfigStore` (`@MainActor` ObservableObject) and `HistoryStore`; views in `MenuBarView` / `MainPanelView` / `ConfigView`.
- **[macos/CopyEverywhereServer/](macos/CopyEverywhereServer/)** — Swift Package Manager executable target, macOS 13+ MenuBarExtra host app. Manages the Go server binary (`copyeverywhere-server`) as a child `Process`. `ServerProcess` (`@MainActor` ObservableObject) owns the subprocess lifecycle (start/stop/restart) and captures stdout/stderr via `Pipe`. `AppDelegate` drives the NSStatusItem + NSPopover (same pattern as the client app).
- **[windows/CopyEverywhere/](windows/CopyEverywhere/)** — .NET 8 WPF tray app using `Hardcodet.NotifyIcon.Wpf`. `Services/ApiClient.cs` mirrors the macOS networking layer; `Services/ConfigStore.cs` and `Services/HistoryStore.cs` are the persistence equivalents.

The REST contract (all under `/api/v1`, Bearer auth required, except `/health`):

```
POST   /clips                    multipart {type, content}     → small upload (< 50 MB)
GET    /clips/latest             → newest ready clip metadata
GET    /clips/:id                → metadata (no status field exposed)
GET    /clips/:id/raw            → streamed body; 403 if upload failed
POST   /uploads/init             {filename,size_bytes,chunk_size} → {upload_id, chunk_count}
PUT    /uploads/:id/parts/:n     binary chunk; 409 = already uploaded
POST   /uploads/:id/complete     → merges parts, returns Clip ID
GET    /uploads/:id/status       → {received_parts, total_parts, status}
```

50 MB is the hard threshold separating single-POST from chunked-upload flows on **both** clients. The client receive flow is two-step everywhere: `GET /clips/latest` for metadata, then `GET /clips/:id/raw` for content.

## Commands

Server (run from [server/](server/)):
```bash
go build ./...                          # build
go test ./...                           # all tests
go test ./handlers -run TestUploadPart  # single test
go run .                                # local run, no auth (also reads PORT, BIND_ADDRESS, STORAGE_PATH, MAX_CLIP_SIZE_MB, TTL_HOURS)
AUTH_ENABLED=true ACCESS_TOKEN=dev go run .  # local run with auth enabled
docker compose up --build               # containerized
```

macOS (run from [macos/CopyEverywhere/](macos/CopyEverywhere/)):
```bash
swift build
swift run CopyEverywhere
```

Windows (run from [windows/CopyEverywhere/](windows/CopyEverywhere/), Windows host required):
```bash
dotnet build
dotnet run
```

Note: Docker, the .NET SDK, and a Windows host are **not** present on this dev machine — those builds can only be verified on the appropriate platform. Don't claim "build verified" if you couldn't actually run it.

## Conventions and gotchas

These are load-bearing — most were learned the hard way during the MVP. Read before any non-trivial change; add to (don't replace) when you discover a new reusable pattern.

**Server (Go):**

- **`BIND_ADDRESS` env var (default `0.0.0.0`)** controls which interface the server listens on. The listen address is `BIND_ADDRESS:PORT`. MenuBarExtra config panel exposes this as the "Bind address" field; value forwarded to the Go subprocess via `ServerConfig.environment`.
- **Auth is opt-in via `AUTH_ENABLED` env var (default `false`).** When false, the auth middleware is not applied and clients should not send `Authorization` headers. The `/health` endpoint exposes `"auth": true|false` so clients can discover whether auth is required. Both macOS `ConfigStore.setAuthHeader()` and Windows `ApiClient.SetAuthHeader()` skip the header when `accessToken` is empty.
- **SSE broker is a shared singleton.** `sse.NewBroker()` is created once in `main.go` and injected into `ClipHandler`, `UploadHandler`, and `DeviceHandler`. Targeted clip notifications flow through `Broker.Notify(targetDeviceID, event)` — call it after a clip with `TargetDeviceID != nil` becomes `ready` (single-shot upload or chunked complete). SSE tests need `httptest.NewServer` (not `NewRecorder`) because streaming requires a real HTTP connection.
- **mDNS service broadcast.** `discovery/` package wraps `github.com/hashicorp/mdns` (pure-Go, no CGO). Service type is `_copyeverywhere._tcp`. TXT records carry `version` and `auth` fields. `main.go` starts mDNS after config load and deregisters on SIGINT/SIGTERM.
- **Gin route order matters.** Register `/clips/latest` *before* `/clips/:id`, otherwise `latest` is captured as an `:id` param.
- **`clipResponse` vs `Clip`.** Handlers return a trimmed `clipResponse` struct so internal fields (`StoragePath`, `Status`) don't leak. Don't return the raw model.
- **SQLite single writer.** `db.Open` sets `SetMaxOpenConns(1)`. Don't crank it up — `modernc.org/sqlite` corrupts under concurrent writes otherwise.
- **Tests use `t.TempDir()`** for isolated DB instances and `gin.New()` (no middleware) for handler isolation.
- **Chunked-upload disk layout.** Parts land at `STORAGE_PATH/uploads/<upload_id>/part_N` (1-indexed). On `complete`, parts are merged into `STORAGE_PATH/<clip_id>/<filename>` and the parts dir is `os.RemoveAll`'d. The clip row is created at `init` with `status=uploading` and flipped to `ready` via `UpdateClip` on complete.

**Shared protocol:**

- **Chunked-upload resume:** a `409` from `PUT /uploads/:id/parts/:n` means the chunk is already on the server — treat it as success. Pause = cancel current task + remember done parts; resume = ask the server which parts it has via `/status`.
- **Text clip wire format.** A clipboard text send is just a normal clip with filename `"clipboard.txt"` and content type `"text/plain"`. Both clients and the server depend on this convention — don't invent a new one.

**macOS:**

- `NSApp.setActivationPolicy(.accessory)` is how the dock icon is hidden (no Info.plist needed for SPM builds).
- **MenuBarExtra replaced with manual NSStatusItem + NSPopover** (US-024). `AppDelegate` (`@MainActor`) owns the status item, popover, and `ConfigStore`. `StatusItemDropView` is a transparent overlay on the button for drag-and-drop. `MenuBarView` is hosted via `NSHostingController`. The popover uses `.applicationDefined` behavior + `NSEvent.addGlobalMonitorForEvents` to avoid the double-toggle issue with `.transient`.
- Use `UserNotifications` (not the deprecated `NSUserNotification`).
- Multipart bodies are built by hand with a UUID boundary — there is no Swift helper.
- **`HistoryStore` removed (US-027).** The panel now shows the live server queue via `GET /clips?device_id=<self>` (polled every 5s while open). `QueueItem` model and `fetchQueue()`/`receiveQueueItem()` live in `ConfigStore`. Receive is atomic — first caller gets 200, subsequent get 410 Gone.
- **`URLSession` progress → `AsyncStream` bridge.** `UploadProgressDelegate` / `DownloadProgressDelegate` (in `ApiClient`) implement `URLSessionTaskDelegate` / `URLSessionDownloadDelegate` and surface progress as `AsyncStream<Double>` so views can `for await` over it. Reuse this pattern — don't roll a new delegate per call site.
- **Stream chunks with `FileHandle`.** The chunked uploader opens a `FileHandle` and `read(upToCount:)`s one chunk at a time. Don't `Data(contentsOf:)` the whole file — large uploads will OOM.
- **SSE client uses `URLSession.shared.bytes(for:)` + `bytes.lines`** for async line-by-line streaming. Set `request.timeoutInterval = .infinity` for long-lived SSE. Parse events by empty-line boundaries, `event:` prefix, and `data:` prefix.
- **`appendDeviceFields(to:boundary:)`** is a shared helper that appends `sender_device_id` and `target_device_id` multipart fields to any outgoing clip POST body. Chunked uploads add device IDs directly to the JSON init body instead.
- **SSE reconnect loop** lives in `ConfigStore.sseLoop()` with exponential backoff (1s → 2s → 4s → capped at 30s). `startSSE()` is idempotent (checks `sseTask != nil`). Call `stopSSE()` before `startSSE()` when credentials change.
- **Bluetooth RFCOMM protocol.** `BluetoothProtocol.swift` defines the app-layer protocol on top of RFCOMM connections. `BluetoothSession` wraps an `IOBluetoothRFCOMMChannel` and manages the handshake + transfer lifecycle. Wire format: newline-delimited JSON headers (`\n` = `0x0A`) followed by raw content bytes. Handshake: `{"app":"CopyEverywhere","version":"3.0"}\n`. Transfer: `BluetoothTransferHeader` JSON (`type`, `filename`, `size`) + `\n` + content bytes.
- **`BluetoothSession` is `IOBluetoothRFCOMMChannelDelegate`.** Data arrives via `rfcommChannelData(_:data:length:)` on a non-main thread — bridged to `@MainActor` via `Task`. Receive uses a buffer-based state machine: handshake phase → header phase → content accumulation.
- **`BluetoothService` owns `activeSession`.** On RFCOMM connect (server accept or client connect), `createSession(channel:device:)` creates a `BluetoothSession` that auto-starts the handshake. Delegate chain: `BluetoothSession` → `BluetoothService` (as `BluetoothSessionDelegate`) → `BluetoothServiceDelegate`.
- **IOBluetooth `closeChannel()` is obsoleted** — use `channel.close()` (returns `IOReturn`, discard with `_ =`).
- **`BluetoothDiscovery`** wraps `IOBluetoothDeviceInquiry` for scanning nearby devices. Found devices are filtered via SDP query for the CopyEverywhere UUID before appearing in the UI. `IOBluetoothDeviceInquiry(delegate:)` returns optional — use `guard let`.
- **`BluetoothPairHelper`** manages the system-level pairing flow. `device.openConnection(self)` triggers the macOS pairing dialog. After pairing, it initiates RFCOMM connection via `BluetoothService.connect(to:)`. The delegate chain is: `BluetoothPairHelper` → `BluetoothService` → `ConfigStore` (as `BluetoothServiceDelegate`).
- **`TransferMode`** enum (`.lanServer` / `.bluetooth`) persisted in UserDefaults. `ConfigView` uses a segmented `Picker` to switch modes. Paired Bluetooth devices persisted as JSON in UserDefaults (`PairedBluetoothDevice` Codable struct).
- **Send routing via `transferMode`.** All send entry points (`sendClipboardText`, `sendText`, `sendFile`, AppDelegate drop handlers, Cmd+V) check `transferMode` at the top and dispatch to private `*Bluetooth()` methods or existing LAN API calls. `isSendReady` computed property returns true when the active mode's transport is ready (LAN configured or Bluetooth connected+handshake complete).
- **Bluetooth send progress.** `BluetoothSession.sendText(_:)` and `sendFile(url:)` return `AsyncStream<Double>` for progress. Bluetooth send methods in `ConfigStore` reuse existing `fileUploadProgress`/`fileUploadSpeed` published properties so the same progress UI works for both modes.
- **Bluetooth receive.** `BluetoothService` forwards `session(_:didReceive:)` and `session(_:receiveProgress:header:)` to `BluetoothServiceDelegate`. `ConfigStore` handles received text (clipboard + notification) and files (saved to ~/Downloads + notification). `bluetoothReceiveProgress`/`bluetoothReceiveFilename` drive the receive progress UI in `MainPanelView`. Size is verified against the header-declared size on completion.
- **RFCOMM server auto-start.** In Bluetooth mode, `ConfigStore` starts the RFCOMM server via `startBluetoothServerIfNeeded()` both in `autoReconnectBluetooth()` (on launch) and `setTransferMode(_:)` (on mode switch). This allows the device to accept inbound Bluetooth connections.

**macOS Server Host App (`macos/CopyEverywhereServer/`):**

- **Go subprocess management.** `ServerProcess` (`@MainActor` ObservableObject) wraps `Foundation.Process` to launch/stop/restart the Go binary. Stdout and stderr are captured via `Pipe` with `readabilityHandler` and surfaced as `@Published logLines: [String]`.
- **Binary path convention.** `ServerProcess.binaryPath` defaults to a sibling `copyeverywhere-server` next to the Swift executable. The Go binary is compiled independently (`go build -o copyeverywhere-server .` in `server/`).
- **Environment forwarding.** `ServerProcess.config` (`ServerConfig`) provides the environment dict, which is merged with the current process env before launching the Go binary. This is how `PORT`, `STORAGE_PATH`, `BIND_ADDRESS`, `AUTH_ENABLED`, etc. are passed to the server.
- **ServerConfig persistence.** `ServerConfig` (`@MainActor` ObservableObject) persists port, storage path, TTL, auth settings to `~/Library/Application Support/CopyEverywhereServer/config.json`. Default storage path is `~/Library/Application Support/CopyEverywhereServer/data`. Config changes require a server restart to take effect.
- **Graceful shutdown.** `process.terminate()` sends SIGTERM (Go server already handles SIGTERM for mDNS deregistration). `applicationWillTerminate` calls `stop()` to clean up on app quit.
- **Same popover pattern as the client app.** `AppDelegate` owns `NSStatusItem` + `NSPopover` with `.applicationDefined` behavior + global event monitor for dismiss-on-click-outside.

**Windows:**

- WPF `PasswordBox` doesn't support two-way binding — sync via the `PasswordChanged` event.
- Set `ShutdownMode="OnExplicitShutdown"` so hiding the main window to tray doesn't kill the app.
- `Microsoft.Toolkit.Uwp.Notifications` v7.1.3 *does* work in .NET 8 WPF despite the "Uwp" name.
- There is no built-in progress-tracking `HttpContent` in .NET — use the in-repo `ProgressStreamContent` (lives in `Services/ApiClient.cs`).
- `OpenFileDialog`/`SaveFileDialog` are in `Microsoft.Win32`, not `System.Windows.Forms`.
- **`MultipartFormDataContent`** in `ApiClient` is what the server's `multipart/form-data` parsing expects — use it, don't hand-roll boundaries like the macOS client does.
- **`SendService`** is the shared send helper used by `FloatingBallWindow`, `MainWindow` (drop + Ctrl+V), and any future send paths. It reads `ConfigStore.DeviceId` / `ConfigStore.TargetDeviceId` and passes them to all API calls.
- **SSE client** uses `HttpClient` with `HttpCompletionOption.ResponseHeadersRead` + `StreamReader.ReadLineAsync()` loop. `Timeout` set to `Timeout.InfiniteTimeSpan` for the long-lived connection. Reconnect with exponential backoff (1s → 2s → 4s → capped at 30s). `StartSSE()` is idempotent (checks `_sseTask != null`).
- **FloatingBallWindow** is a 64x64 borderless, transparent, always-on-top WPF window that accepts file and text drops. Position persisted in `config.json`. Toggle in MainWindow config section.
- **mDNS discovery** uses `Zeroconf` NuGet (v3.6.11). `MdnsDiscoveryService` runs a periodic scan loop for `_copyeverywhere._tcp.local.` services. `DiscoveredServer` model matches macOS `DiscoveredServer` struct. TXT records provide `auth` and `version` fields.
- **`ConfigStore.ServerAuthRequired`** (nullable bool) controls Access Token field visibility: `null` = unknown (show as optional), `true` = shown as required, `false` = hidden. Populated from mDNS TXT `auth` field or `/health` response `auth` field.

**Cross-platform:**

- **Secrets storage:** macOS → Keychain via the Security framework (delete-before-add for updates). Windows → Credential Manager via the `CredentialManagement` NuGet.
- **History storage (MVP):** Both macOS and Windows HistoryStore removed — replaced by live server queue view (`GET /clips?device_id=<self>`). macOS removed in US-027, Windows in US-033.
