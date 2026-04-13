# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Source of truth

- Five iterations have shipped and are now archived — there is no active `prd.json` in the repo root right now. Historical context only:
  - **MVP (US-001 … US-017)** under [archive/mvp/](archive/mvp/) — initial clipboard-relay feature set.
  - **Queue + frictionless UX (US-018 … US-034)** under [archive/queue-and-frictionless-ux/](archive/queue-and-frictionless-ux/) — device registration, targeted queue, SSE push, drag-and-drop, auto-receive.
  - **LAN & Bluetooth (US-035 … US-050)** under [archive/lan-and-bluetooth/](archive/lan-and-bluetooth/) — LAN self-hosted server, mDNS discovery, MenuBarExtra host app, Bluetooth RFCOMM peer-to-peer mode.
  - **Android Client (US-051 … US-068)** under [archive/android-client/](archive/android-client/) — Kotlin + Jetpack Compose Android client with LAN server mode, Bluetooth RFCOMM, share sheet, foreground service, boot receiver.
  - **Embedded Server (US-069 … US-082)** under [archive/embedded-server/](archive/embedded-server/) — Go relay server merged into macOS and Windows client apps as an optional subprocess, removing the standalone CopyEverywhereServer host app.
- When a new iteration starts, drop its fresh `prd.json` + `progress.txt` at the repo root and its PRD doc at `tasks/prd-*.md`, then update this section to point at them.
- This repo is driven by the Ralph autonomous agent loop ([scripts/ralph/ralph.sh](scripts/ralph/ralph.sh) + [scripts/ralph/CLAUDE.md](scripts/ralph/CLAUDE.md)). One commit ≈ one user story; commit messages follow `feat: [US-XXX] - [Title]`. The hard-won "do this / don't do that" list lives in the **Conventions and gotchas** section below — add to it (don't replace) when you discover a new reusable pattern.

## Architecture

Four independent codebases share a single REST contract:

- **[server/](server/)** — Go 1.22+ / Gin relay. SQLite metadata (`modernc.org/sqlite`, pure-Go, no CGO) plus a content store on disk. The server is stateless beyond `STORAGE_PATH`; clients address content by 6-char alphanumeric Clip IDs. Layout: `config/` env loader, `db/` schema + helpers, `middleware/` Bearer auth, `handlers/` (`clips.go` for single-shot, `uploads.go` for chunked), `cleanup/` background TTL goroutine, `main.go` wiring.
- **[macos/CopyEverywhere/](macos/CopyEverywhere/)** — Swift Package Manager executable target (no .xcodeproj), macOS 13+ MenuBarExtra app. State lives in `ConfigStore` (`@MainActor` ObservableObject) and `HistoryStore`; views in `MenuBarView` / `MainPanelView` / `ConfigView`.
- **[macos/CopyEverywhereServer/](macos/CopyEverywhereServer/)** — Swift Package Manager executable target, macOS 13+ MenuBarExtra host app. Manages the Go server binary (`copyeverywhere-server`) as a child `Process`. `ServerProcess` (`@MainActor` ObservableObject) owns the subprocess lifecycle (start/stop/restart) and captures stdout/stderr via `Pipe`. `AppDelegate` drives the NSStatusItem + NSPopover (same pattern as the client app).
- **[windows/CopyEverywhere/](windows/CopyEverywhere/)** — .NET 8 WPF tray app using `Hardcodet.NotifyIcon.Wpf`. `Services/ApiClient.cs` mirrors the macOS networking layer; `Services/ConfigStore.cs` and `Services/HistoryStore.cs` are the persistence equivalents.
<<<<<<< HEAD
=======
- **[android/](android/)** — Kotlin + Jetpack Compose, minSdk 29, targetSdk 35. Single-module Gradle (Kotlin DSL) with version catalog (`gradle/libs.versions.toml`). Material 3 + dynamic color theming. Package: `com.copyeverywhere.app`.
>>>>>>> ralph/android-client

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

<<<<<<< HEAD
=======
Android (run from [android/](android/)):
```bash
./gradlew assembleDebug                 # debug build
./gradlew assembleRelease               # release build
```

>>>>>>> ralph/android-client
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

- **SDK compatibility.** Project targets `net8.0-windows10.0.19041.0` but builds fine under .NET 10 SDK with three fixes applied: (1) `Buffer.BlockCopy` → `System.Buffer.BlockCopy` in `BluetoothSession.cs` to resolve ambiguity with WinRT `Windows.Storage.Streams.Buffer`; (2) `CancellationToken` args in `SendFileAsync`/`InitChunkedUploadAsync` calls use named parameter `ct:` because positional order changed; (3) `FloatingBallCheckBox_Changed` guards against null `_configStore` during XAML load.
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

- **Bluetooth RFCOMM** uses WinRT APIs (`Windows.Devices.Bluetooth.Rfcomm`). The project TFM is `net8.0-windows10.0.19041.0` to access WinRT projections (no extra NuGet needed). `BluetoothService` (`INotifyPropertyChanged + IDisposable`) mirrors the macOS `BluetoothService` — server mode via `RfcommServiceProvider` + `StreamSocketListener`, client mode via `RfcommDeviceService` + `StreamSocket`.
- **RFCOMM Service UUID** is `CE000001-1000-1000-8000-00805F9B34FB` — defined as `BluetoothService.CopyEverywhereServiceUuid` (System.Guid). Must match macOS `kCopyEverywhereServiceUUID` exactly.
- **RFCOMM server SDP attributes.** `RfcommServiceProvider.SdpRawAttributes[0x0100]` writes the service name. Format: `0x25` (UTF-8 type byte) + length byte + string bytes.
- **RFCOMM client discovery.** `RfcommDeviceService.GetDeviceSelector(RfcommServiceId)` builds a selector for `DeviceInformation.FindAllAsync()`. For reconnecting by address, use `BluetoothDevice.FromBluetoothAddressAsync()` + `GetRfcommServicesForIdAsync()`.
- **StreamSocket I/O.** `DataWriter(socket.OutputStream)` / `DataReader(socket.InputStream)` are the WinRT equivalents of IOBluetooth's `writeAsync`/`rfcommChannelData`. Set `DataReader.InputStreamOptions = InputStreamOptions.Partial` for streaming reads.
- **Bluetooth RFCOMM protocol (Windows).** `BluetoothSession` mirrors macOS `BluetoothProtocol.swift`. Same wire format: newline-delimited JSON headers (`0x0A`) + raw content bytes. Handshake: `{"app":"CopyEverywhere","version":"3.0"}\n`. Transfer: `BluetoothTransferHeader` JSON + `\n` + content bytes. Cross-platform interop with macOS.
- **`BluetoothSession` lifecycle.** Created by `BluetoothService.CreateSession()` on RFCOMM connect. `StartAsync()` sends handshake and starts the receive loop. Events: `HandshakeCompleted`, `HandshakeFailed`, `TransferReceived`, `ReceiveProgress`, `ReceiveFailed`. `BluetoothService` exposes `ActiveSession`, `SessionReady`, `SessionHandshakeFailed`.
- **`BluetoothTransferHeader.Type` serialization.** Uses a string-backed `TypeString` property for JSON (`"text"`/`"file"` lowercase) with a `[JsonIgnore]` convenience `Type` property mapping to `BluetoothContentType` enum.
- **`TransferMode` enum** (`LanServer`/`Bluetooth`) in `ConfigStore.cs`. `PairedBluetoothDevice` model persisted in `config.json` alongside device config. `BluetoothConnectionStatus` enum mirrors macOS pattern. `AddPairedDevice()`/`RemovePairedDevice()` helpers manage the list and auto-persist.
- **Bluetooth pairing flow (Windows).** `BluetoothService.ConnectAsync(DeviceInformation)` triggers the Windows system pairing dialog if needed. On `SessionReady`, the device is added to `PairedDevices`. Reconnection uses `ConnectByAddressAsync(ulong)`.
- **Bluetooth UI in MainWindow.** Transfer mode ComboBox controls `BluetoothSection` visibility. Scan uses `BluetoothService.FindDevicesAsync()` (static). Paired device list rendered programmatically with Connect/Disconnect/Forget buttons. Status badge shows connection state via colored dot.

<<<<<<< HEAD
**Cross-platform:**

- **Secrets storage:** macOS → Keychain via the Security framework (delete-before-add for updates). Windows → Credential Manager via the `CredentialManagement` NuGet.
=======
**Android:**

- **Gradle version catalog** at `android/gradle/libs.versions.toml` is the single source of truth for dependency versions. Use `libs.` references in `build.gradle.kts`, never hardcode version strings.
- **Gradle wrapper (8.9)** — always use `./gradlew`, never bare `gradle`. AGP 8.7.3 + Kotlin 2.0.21 + Compose compiler via `kotlin-compose` plugin.
- **Adaptive launcher icon** uses vector drawables (`ic_launcher_foreground.xml` + `ic_launcher_background.xml`) via `mipmap-anydpi-v26/ic_launcher.xml`. No raster PNGs needed.
- **Theme** uses Material 3 dynamic color (Android 12+ `dynamicLightColorScheme`/`dynamicDarkColorScheme`) with fallback to default light/dark schemes.
- **Config persistence.** `ConfigStore` (`data/ConfigStore.kt`) uses DataStore Preferences for non-secret config (host URL, device name, device ID, target device ID) and `EncryptedSharedPreferences` (Keystore-backed) for the access token. Access token API is synchronous; wrap in `MutableStateFlow` for Compose observation.
- **API client.** `ApiClient` (`data/ApiClient.kt`) uses OkHttp + Gson. Bearer auth header skipped when token is empty. All network calls are `suspend` functions dispatched to `Dispatchers.IO`.
- **Navigation.** `NavHost` in `MainActivity` with string routes (`"main"`, `"config"`). `ConfigScreen` gets its own `ConfigViewModel` (`AndroidViewModel` for app context access).
- **Server platform value.** Device registration sends `platform = "android"` — the Go server's `/api/v1/devices/register` handler needs to accept `"android"` in its platform whitelist.
- **mDNS discovery.** `MdnsDiscoveryService` (`data/MdnsDiscoveryService.kt`) wraps `NsdManager` to browse for `_copyeverywhere._tcp.` services. `DiscoveredServer` data class holds name, host, port, authRequired, version. TXT record attributes parsed from `NsdServiceInfo.attributes`. Discovery lifecycle tied to ConfigScreen via `DisposableEffect`. No extra permissions needed beyond `INTERNET`.
- **Receive flow.** `fetchQueue()` lists unconsumed clips via `GET /clips?device_id=<self>`. `downloadClipRaw()` does a two-step fetch: metadata (`GET /clips/:id`) then raw content (`GET /clips/:id/raw`). Raw download atomically consumes the clip — 410 Gone means already consumed (`ClipAlreadyConsumedException`). Download progress via suspend callback using metadata `sizeBytes` as total.
- **SSE client.** `SseClient` (`data/SseClient.kt`) uses OkHttp with `readTimeout(0)` for infinite timeout. Parses SSE events line-by-line via `BufferedReader`. Exponential backoff reconnect (1s → 2s → 4s → capped 30s). `connect()` suspends forever — cancel the coroutine to stop.
- **Foreground service.** `CopyEverywhereService` (`service/CopyEverywhereService.kt`) hosts SSE client. Uses `foregroundServiceType="dataSync"`. Two notification channels: `copyeverywhere_service` (ongoing, low importance) and `copyeverywhere_transfers` (high importance). Static `start(context)`/`stop(context)` helpers. `startSse()`/`stopSse()` public for transfer mode switching.
- **Clipboard trampoline.** Android 10+ restricts `ClipboardManager.primaryClip` to foreground activities. The "Send clipboard" notification action launches `ClipboardTrampolineActivity` (transparent, `excludeFromRecents`, `noHistory`) which reads clipboard → sends via `ApiClient` → toasts "Sent!" → updates service notification briefly → auto-finishes. `CopyEverywhereService.buildServiceNotificationStatic()` is the shared notification builder used by both the service and the trampoline.
- **File save to Downloads.** Uses `MediaStore.Downloads.EXTERNAL_CONTENT_URI` — no storage permissions needed on API 29+.
- **POST_NOTIFICATIONS permission.** Android 13+ requires runtime permission. Requested in `MainActivity` on launch via `ActivityResultContracts.RequestPermission()`. Service starts regardless of grant result.
- **Share sheet integration.** `ShareReceiverActivity` handles `ACTION_SEND` (single file/text) and `ACTION_SEND_MULTIPLE` (multiple files) with `*/*` MIME type. Text extras sent as text clips; file URIs routed to single or chunked upload based on 50 MB threshold. Minimal Compose UI shows progress and auto-finishes on success.
- **`TransferMode` enum** (`LanServer`/`Bluetooth`) persisted in DataStore. `ConfigStore.transferMode` is a `Flow<TransferMode>`. `CopyEverywhereService.switchMode(mode)` handles stopping/starting SSE and RFCOMM server. `ConfigViewModel.updateTransferMode()` persists the change and notifies the running service via `CopyEverywhereService.instance?.switchMode()`.
- **`CopyEverywhereService.instance`** static reference (set in `onCreate`, cleared in `onDestroy`) allows ViewModels to call service methods directly without binding. Used for `switchMode()`.
- **Config screen conditional sections.** `FilterChip` segmented control switches between LAN and Bluetooth sections. LAN section shows Host URL, discovered servers, access token, target device, test connection. Bluetooth section shows device pairing UI (placeholder until US-062+).
- **Mode switch service lifecycle (Android).** LAN→BT stops SSE + starts RFCOMM server; BT→LAN stops RFCOMM server + starts SSE. Queue polling in `MainViewModel` only runs in LAN mode. Notification text reflects active mode.
- **Bluetooth RFCOMM protocol (Android).** `BluetoothProtocol.kt` defines the wire protocol. Same format as macOS/Windows: newline-delimited JSON headers (`0x0A`) + raw content bytes. Handshake: `{"app":"CopyEverywhere","version":"3.0"}\n`. Transfer: `BluetoothTransferHeader` JSON (`type`, `filename`, `size`) + `\n` + content bytes.
- **`BluetoothSession` wraps `BluetoothSocket`.** `start()` performs handshake with 5s timeout, then enters a receive loop. Receive uses a buffer-based state machine: handshake → header → content accumulation. `sendText()` and `sendFile()` return `Flow<Double>` for progress. File sends stream from content URI via `contentResolver.openInputStream()` in 16 KB chunks.
- **`BluetoothService` owns `activeSession`.** On RFCOMM connect (server accept or client connect), `createSession()` creates a `BluetoothSession` that auto-starts handshake. Delegate chain: `BluetoothSession` → `BluetoothService` (as `BluetoothSession.Listener`) → `BluetoothService.Listener`.
- **`CopyEverywhereService.bluetoothService`** is the live `BluetoothService` instance. `startBluetoothServer()` / `stopBluetoothServer()` manage the RFCOMM server lifecycle in `switchMode()`. `BluetoothService.destroy()` called in `onDestroy()`.
- **RFCOMM Service UUID** is `CE000001-1000-1000-8000-00805F9B34FB` — defined in `BluetoothProtocol.SERVICE_UUID`. Must match macOS `kCopyEverywhereServiceUUID` and Windows `BluetoothService.CopyEverywhereServiceUuid` exactly.
- **Bluetooth permissions (Android 12+).** `BLUETOOTH` + `BLUETOOTH_ADMIN` (maxSdkVersion 30) for pre-12, `BLUETOOTH_CONNECT` + `BLUETOOTH_SCAN` for 12+. Runtime permissions requested in US-063.
- **`@SuppressLint("MissingPermission")`** on `BluetoothService` methods that use Bluetooth APIs. Actual runtime permission checks happen in the UI layer (US-063).
- **Bluetooth device scanning.** `ConfigViewModel` manages `BluetoothAdapter.startDiscovery()` + `BroadcastReceiver(ACTION_FOUND)`. On API 33+ register with `Context.RECEIVER_EXPORTED`. `BluetoothDevice.name` can throw `SecurityException` — catch and skip unnamed devices. Stop scanning in `onCleared()`.
- **Paired device persistence.** `PairedBluetoothDevice(name, address)` stored as JSON list in DataStore via Gson. `ConfigStore.addPairedDevice()`/`removePairedDevice()` manage the list. `lastConnectedBtAddress` tracks the most recently connected device for auto-reconnect (US-064).
- **`BluetoothService.listener` ownership.** `CopyEverywhereService` implements `BluetoothService.Listener` and sets itself as listener in `onCreate()`. `ConfigViewModel` temporarily overrides the listener in `init` and restores the service as listener in `onCleared()`. This ensures the service always receives connection status events for notification updates.
- **Bluetooth auto-reconnect.** `BluetoothService.autoReconnect(address, onStatusChange)` uses exponential backoff (2s → 4s → 8s → 16s → capped 30s), max 5 attempts. Called by `CopyEverywhereService.autoReconnectBluetooth()` on launch in BT mode and on mode switch to BT. Checks `isSessionReady` before each attempt to bail out if an inbound RFCOMM connection was accepted.
- **`stopBluetoothServer()` calls `cancelReconnect()`.** Switching from BT to LAN must cancel in-progress reconnect attempts.
- **Bluetooth runtime permissions (Android 12+).** `BLUETOOTH_CONNECT` + `BLUETOOTH_SCAN` requested via `ActivityResultContracts.RequestMultiplePermissions` in ConfigScreen before scanning. `BLUETOOTH_SCAN` has `neverForLocation` flag to avoid location permission requirement.
- **Send routing via `transferMode` (Android).** All send entry points (`ClipboardTrampolineActivity`, `MainViewModel.sendText()`/`sendFile()`, `ShareReceiverActivity`) check `transferMode` at the top and dispatch to `BluetoothSession` or `ApiClient`. Pattern: `CopyEverywhereService.instance?.bluetoothService?.activeSession` → verify `isHandshakeComplete` → send. Error: "No Bluetooth device connected" if no ready session.
- **Bluetooth send progress (Android).** `MainViewModel.sendFileBluetooth()` reuses `_uploadProgress` (same `UploadProgress` data class as LAN chunked uploads). Speed calculated from elapsed time + progress fraction × file size. `BluetoothSession.sendText()` / `sendFile()` return `Flow<Double>` — must `collect` even if progress isn't displayed (Flow is cold).
- **Bluetooth receive (Android).** `CopyEverywhereService` handles `onTransferReceived` from `BluetoothService.Listener`: text → `ClipboardManager.setPrimaryClip()` + notification, file → `MediaStore.Downloads` + notification with Share action. `btReceiveProgress`/`btReceiveFilename` `StateFlow`s on the service drive the receive progress UI in `MainScreen`. `MainViewModel.startBtReceiveObserving()` collects these flows. MIME type guessed via `ApiClient.guessMimeType(filename)`. File size verified against header in both `BluetoothSession.readContent()` and `onTransferReceived`. Sequential transfers work because `BluetoothSession`'s receive loop continues after each transfer.

**Cross-platform:**

- **Secrets storage:** macOS → Keychain via the Security framework (delete-before-add for updates). Windows → Credential Manager via the `CredentialManagement` NuGet. Android → EncryptedSharedPreferences (Keystore-backed).
>>>>>>> ralph/android-client
- **History storage (MVP):** Both macOS and Windows HistoryStore removed — replaced by live server queue view (`GET /clips?device_id=<self>`). macOS removed in US-027, Windows in US-033.
- **Send routing via `TransferMode` (Windows).** `SendService` checks `ConfigStore.TransferMode` at the top of `SendTextAsync`/`SendFileAsync` and dispatches to `BluetoothSession` or `ApiClient`. `IsSendReady` property on `ConfigStore` returns true when the active mode's transport is ready (LAN configured or Bluetooth connected+handshake complete). All send entry points (Ctrl+V, drag-drop, FloatingBall drop) go through `SendService`.
- **Bluetooth send progress (Windows).** `SendService.BluetoothSendProgress` event (0.0–1.0) drives the same `UploadProgressPanel` used for chunked uploads. `MainWindow` subscribes via the `SendService` property setter.
- **Bluetooth receive (Windows).** `BluetoothService` forwards `TransferReceived`, `ReceiveProgress`, `ReceiveFailed` events from `BluetoothSession`. `MainWindow` subscribes in the constructor. Received text → `Clipboard.SetText()` + toast. Received files → saved to `~/Downloads` with duplicate-name avoidance + toast. `BtReceiveProgressPanel` in the XAML Bluetooth section shows receive progress.
- **RFCOMM server auto-start (Windows).** `StartBluetoothServerIfNeeded()` starts the RFCOMM server in Bluetooth mode. Called from `InitializeTransferModeUI()` (on launch) and `TransferModeComboBox_SelectionChanged` (on mode switch). Mirrors macOS `startBluetoothServerIfNeeded()`.
- **Mode switch service lifecycle.** On both macOS and Windows, switching transfer mode must stop/start background services: LAN→BT stops SSE + queue polling, starts RFCOMM server; BT→LAN stops RFCOMM server, restarts SSE + queue polling. `UpdateMainPanelState()` (Windows) / `MainPanelView` (macOS) conditionally shows queue (LAN) or BT status section.
- **`UpdateBtStatusPanel()` (Windows)** mirrors macOS `bluetoothStatusColor`/`bluetoothStatusText` helpers. Called from `UpdateBluetoothStatus()` when in BT mode and from `UpdateMainPanelState()`. Updates `BtStatusDot`, `BtStatusLabel`, `BtConnectedDeviceText`, `BtPairHintText`.
<<<<<<< HEAD
=======
- **Boot receiver (Android).** `BootReceiver` listens for `BOOT_COMPLETED` and starts the foreground service. Registered in manifest with `exported="true"`. Requires `RECEIVE_BOOT_COMPLETED` permission.
- **Battery optimization (Android).** `MainActivity.requestBatteryOptimizationExemption()` uses `Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` to prompt the user. Checks `PowerManager.isIgnoringBatteryOptimizations()` first to avoid re-prompting. Requires `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission.
- **WakeLock (Android).** `CopyEverywhereService.acquireWakeLock()`/`releaseWakeLock()` with nested holder counting. Acquired around SSE clip downloads and Bluetooth receive transfers. 10-minute safety timeout on `acquire()`. `releaseWakeLockFully()` in `onDestroy()` as cleanup.
>>>>>>> ralph/android-client
