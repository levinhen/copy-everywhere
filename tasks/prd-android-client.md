# PRD: Android Client

## Introduction

Add an Android client to CopyEverywhere, achieving full feature parity with the existing macOS and Windows clients. The Android app supports both LAN Server mode (relay via self-hosted Go server with mDNS discovery) and Bluetooth RFCOMM peer-to-peer mode. The primary interaction surface is a persistent notification that sends clipboard content with one tap, plus Android share-sheet integration for files. A main Activity provides configuration, mode switching, a text input for manual sends, and file upload.

## Goals

- Full feature parity with macOS/Windows clients (LAN + Bluetooth, send + receive)
- One-tap clipboard send via persistent notification
- Share-sheet integration for sending files from any Android app
- Foreground service for SSE/Bluetooth background connectivity
- Cross-platform Bluetooth interop with macOS and Windows (shared RFCOMM protocol)
- Clean Material 3 / Jetpack Compose UI, minSdk 29 (Android 10+)

## User Stories

### US-051: Android project scaffold and build pipeline
**Description:** As a developer, I need a working Android project skeleton so that subsequent stories have a compilable base.

**Acceptance Criteria:**
- [ ] New `android/` directory with Kotlin + Jetpack Compose project, minSdk 29, targetSdk 35
- [ ] Single-module Gradle setup (app module) with Material 3 dependency
- [ ] Empty `MainActivity` with Compose `setContent {}` launches successfully
- [ ] `./gradlew assembleDebug` succeeds

### US-052: Configuration screen and persistence
**Description:** As a user, I want to configure server URL, access token, device name, and target device so the app knows where to send/receive.

**Acceptance Criteria:**
- [ ] Compose screen with fields: Host URL, Access Token (masked), Device Name, Target Device dropdown
- [ ] Config persisted via DataStore (Preferences)
- [ ] Access token stored in Android Keystore-backed EncryptedSharedPreferences
- [ ] "Test Connection" button calls `/health`, shows latency and auth requirement
- [ ] When server reports `auth: false`, access token field is hidden
- [ ] Device auto-registers on first launch via `POST /api/v1/devices/register` (platform = "android")
- [ ] Target device dropdown populated from `GET /api/v1/devices`
- [ ] `./gradlew assembleDebug` succeeds

### US-053: mDNS server discovery
**Description:** As a user, I want the app to auto-discover CopyEverywhere servers on my LAN so I don't have to type an IP address.

**Acceptance Criteria:**
- [ ] Uses Android NSD (`NsdManager`) to browse for `_copyeverywhere._tcp.` services
- [ ] Discovered servers shown in a "Discovered Servers" list on the config screen
- [ ] Tapping a discovered server auto-fills Host URL (and sets auth requirement from TXT record)
- [ ] Discovery starts when config screen is visible, stops when navigated away
- [ ] `./gradlew assembleDebug` succeeds

### US-054: API client — small clip send (text + file < 50 MB)
**Description:** As a user, I want to send text and small files to the server so they appear on my other devices.

**Acceptance Criteria:**
- [ ] `ApiClient` class with OkHttp, handles Bearer auth header (skip when token empty)
- [ ] `sendClip(type, filename, content)` sends multipart POST to `/api/v1/clips` with `sender_device_id` and `target_device_id` fields
- [ ] Text clips use filename `clipboard.txt`, content type `text/plain`
- [ ] File clips stream from URI (no full-file `ByteArray` load)
- [ ] Returns clip metadata on success, throws on error
- [ ] `./gradlew assembleDebug` succeeds

### US-055: API client — chunked upload (file >= 50 MB)
**Description:** As a user, I want to upload large files without OOM or timeout so I can share videos and archives.

**Acceptance Criteria:**
- [ ] `POST /uploads/init` with filename, size_bytes, chunk_size → upload_id, chunk_count
- [ ] `PUT /uploads/:id/parts/:n` streams each chunk from file descriptor (16 KB read buffer)
- [ ] 409 response treated as success (chunk already uploaded)
- [ ] `POST /uploads/:id/complete` finalizes upload
- [ ] Progress reported as `Flow<Double>` (0.0 to 1.0)
- [ ] Upload speed (MB/s) calculated and exposed
- [ ] Pause/resume: cancel coroutine job, resume queries `/uploads/:id/status` for completed parts
- [ ] `./gradlew assembleDebug` succeeds

### US-056: API client — receive clip (metadata + download)
**Description:** As a user, I want to receive clips sent to my device so I can access content from other machines.

**Acceptance Criteria:**
- [ ] `GET /api/v1/clips?device_id=<self>` returns unconsumed clip list
- [ ] `GET /api/v1/clips/:id/raw` downloads and atomically consumes the clip
- [ ] Text clips → copy to system clipboard via `ClipboardManager`
- [ ] File clips → save to Downloads via `MediaStore` or `Environment.DIRECTORY_DOWNLOADS`, show notification with "Share" action using `Intent.ACTION_SEND`
- [ ] Download progress reported as `Flow<Double>`
- [ ] 410 Gone handled gracefully (clip already consumed)
- [ ] `./gradlew assembleDebug` succeeds

### US-057: SSE client and auto-receive
**Description:** As a user, I want to auto-receive targeted clips without manually refreshing so the experience is instant.

**Acceptance Criteria:**
- [ ] SSE client connects to `GET /api/v1/devices/:id/stream` using OkHttp with infinite timeout
- [ ] Parses `event: clip` + `data: {json}` events
- [ ] On clip event, auto-downloads via `/clips/:id/raw` and processes (text → clipboard, file → Downloads + notification)
- [ ] Exponential backoff reconnect (1s → 2s → 4s → capped 30s)
- [ ] Runs inside a Foreground Service with persistent notification
- [ ] `./gradlew assembleDebug` succeeds

### US-058: Foreground service and persistent notification (LAN mode)
**Description:** As a user, I want a persistent notification that lets me send clipboard content with one tap.

**Acceptance Criteria:**
- [ ] `CopyEverywhereService` extends `Service`, runs as foreground service with ongoing notification
- [ ] Notification shows "Tap to send clipboard" action
- [ ] Tapping the action reads `ClipboardManager.primaryClip`, sends text via `ApiClient.sendClip()`
- [ ] Notification updates briefly to show "Sent!" or error
- [ ] Service started on app launch, survives app backgrounding
- [ ] Notification channel created with appropriate importance level
- [ ] `./gradlew assembleDebug` succeeds

### US-059: Main Activity — text input and file upload
**Description:** As a user, I want a main screen where I can paste text and pick files to send, plus see my queue.

**Acceptance Criteria:**
- [ ] Main screen has: text input field with "Send" button, "Upload File" button, queue list
- [ ] Text input sends via `ApiClient.sendClip()` with type `text`
- [ ] "Upload File" opens system file picker (`ACTION_OPEN_DOCUMENT`), routes to single or chunked upload based on 50 MB threshold
- [ ] Upload progress bar shown with speed (MB/s) and pause/resume button for chunked uploads
- [ ] Queue list shows unconsumed clips for this device (polled every 5s while screen visible)
- [ ] Tapping a queue item receives it (text → clipboard + toast, file → Downloads + share prompt)
- [ ] `./gradlew assembleDebug` succeeds

### US-060: Share sheet integration (send files from other apps)
**Description:** As a user, I want to share files to CopyEverywhere from any app's share menu.

**Acceptance Criteria:**
- [ ] `AndroidManifest.xml` declares intent filter for `ACTION_SEND` and `ACTION_SEND_MULTIPLE` with `*/*` MIME type
- [ ] `ShareReceiverActivity` extracts URI(s) from intent, routes to single or chunked upload
- [ ] Shows a minimal UI with progress bar during upload, auto-finishes on completion
- [ ] Handles `text/plain` intent extras (shared text) as text clip send
- [ ] `./gradlew assembleDebug` succeeds

### US-061: Transfer mode switch (LAN <-> Bluetooth)
**Description:** As a user, I want to switch between LAN Server and Bluetooth modes in the app settings.

**Acceptance Criteria:**
- [ ] `TransferMode` enum: `LanServer`, `Bluetooth` — persisted in DataStore
- [ ] Segmented control / toggle on config screen to switch modes
- [ ] Switching to Bluetooth: stops SSE + queue polling, starts RFCOMM server
- [ ] Switching to LAN: stops RFCOMM server, starts SSE + queue polling
- [ ] Config screen conditionally shows LAN fields or Bluetooth section based on active mode
- [ ] Persistent notification text updates to reflect active mode
- [ ] `./gradlew assembleDebug` succeeds

### US-062: Bluetooth RFCOMM service and session protocol
**Description:** As a developer, I need the core Bluetooth RFCOMM transport layer so the app can connect to macOS/Windows peers.

**Acceptance Criteria:**
- [ ] `BluetoothService` class manages RFCOMM server (listen) and client (connect) roles
- [ ] Service UUID: `CE000001-1000-1000-8000-00805F9B34FB` (matches macOS/Windows)
- [ ] Server mode: `BluetoothServerSocket.accept()` loop in coroutine
- [ ] Client mode: `BluetoothDevice.createRfcommSocketToServiceRecord(uuid)` connect
- [ ] `BluetoothSession` wraps `BluetoothSocket`, implements handshake + transfer protocol
- [ ] Handshake: send/receive `{"app":"CopyEverywhere","version":"3.0"}\n` with 5s timeout
- [ ] Transfer: newline-delimited JSON header (`type`, `filename`, `size`) + raw content bytes
- [ ] Receive state machine: handshake phase → header phase → content accumulation (buffer-based)
- [ ] Send text: `Flow<Double>` progress, filename `clipboard.txt`
- [ ] Send file: streams from URI in 16 KB chunks, `Flow<Double>` progress
- [ ] `./gradlew assembleDebug` succeeds

### US-063: Bluetooth device scanning and pairing
**Description:** As a user, I want to scan for nearby Bluetooth devices and pair with them.

**Acceptance Criteria:**
- [ ] Scan uses `BluetoothAdapter.startDiscovery()` + `BroadcastReceiver` for `ACTION_FOUND`
- [ ] Discovered devices shown in a list (filtered to show only those with CopyEverywhere SDP record when possible)
- [ ] Tapping a device triggers system pairing dialog if not bonded
- [ ] After pairing, initiates RFCOMM connection via `BluetoothService`
- [ ] Paired devices persisted in DataStore (name, address)
- [ ] Paired device list in config screen with Connect / Disconnect / Forget actions
- [ ] Connection status indicator (colored dot: green=connected, yellow=connecting, gray=disconnected)
- [ ] Runtime permission requests for `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN` (Android 12+)
- [ ] `./gradlew assembleDebug` succeeds

### US-064: Bluetooth auto-reconnect and RFCOMM server auto-start
**Description:** As a user, I want the app to auto-reconnect to my paired Bluetooth device and accept incoming connections.

**Acceptance Criteria:**
- [ ] On app launch in Bluetooth mode, starts RFCOMM server listener
- [ ] On app launch, attempts reconnect to last-connected paired device
- [ ] Reconnect uses exponential backoff (2s → 4s → 8s → capped 30s), max 5 attempts
- [ ] RFCOMM server accepts inbound connections from paired macOS/Windows peers
- [ ] Foreground service notification updates to show Bluetooth connection status
- [ ] `./gradlew assembleDebug` succeeds

### US-065: Bluetooth send — text and files
**Description:** As a user, I want to send clipboard text and files over Bluetooth to my paired device.

**Acceptance Criteria:**
- [ ] Persistent notification "Tap to send clipboard" works in Bluetooth mode (sends via `BluetoothSession`)
- [ ] Main Activity text input and file upload route through `BluetoothSession` when in BT mode
- [ ] Share sheet sends route through `BluetoothSession` when in BT mode
- [ ] Send progress shown on same UI elements as LAN uploads (progress bar + speed)
- [ ] Error handling: if no active session, show toast "No Bluetooth device connected"
- [ ] `./gradlew assembleDebug` succeeds

### US-066: Bluetooth receive — text and files
**Description:** As a user, I want to receive content over Bluetooth and have it placed on my clipboard or saved to Downloads.

**Acceptance Criteria:**
- [ ] Received text → `ClipboardManager.setPrimaryClip()` + notification
- [ ] Received file → saved to Downloads folder + notification with "Share" action (opens share sheet)
- [ ] Receive progress shown in Main Activity when visible (progress bar + filename)
- [ ] File size verified against header-declared size on completion
- [ ] Works for sequential transfers on the same RFCOMM connection
- [ ] `./gradlew assembleDebug` succeeds

### US-067: Notifications and user feedback
**Description:** As a user, I want clear notifications for received content and transfer status.

**Acceptance Criteria:**
- [ ] Notification channels: "Service" (ongoing, low importance), "Transfers" (high importance)
- [ ] Text received: notification with "Copied to clipboard" message
- [ ] File received: notification with filename, "Share" action (opens Android share sheet), "Open" action
- [ ] Send success: brief notification or toast "Sent!"
- [ ] Send/receive errors: notification with error message
- [ ] `./gradlew assembleDebug` succeeds

### US-068: Boot receiver and battery optimization
**Description:** As a user, I want the service to survive reboots and not be killed by battery optimization.

**Acceptance Criteria:**
- [ ] `RECEIVE_BOOT_COMPLETED` permission + `BootReceiver` starts the foreground service on boot
- [ ] App requests exemption from battery optimization (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) with user prompt
- [ ] WakeLock acquired during active transfers to prevent CPU sleep
- [ ] Service uses `START_STICKY` to restart if killed by system
- [ ] `./gradlew assembleDebug` succeeds

## Functional Requirements

- FR-1: Android app uses Kotlin + Jetpack Compose, minSdk 29, targetSdk 35
- FR-2: Persistent foreground service notification with one-tap clipboard send
- FR-3: Share sheet receiver for `ACTION_SEND` / `ACTION_SEND_MULTIPLE` (any MIME type)
- FR-4: Config screen with: Host URL, Access Token, Device Name, Target Device, Transfer Mode toggle
- FR-5: mDNS discovery via `NsdManager` for `_copyeverywhere._tcp.` services
- FR-6: API client (OkHttp) supporting single-shot and chunked uploads with progress/pause/resume
- FR-7: SSE client with exponential backoff reconnect for auto-receive
- FR-8: Bluetooth RFCOMM with UUID `CE000001-1000-1000-8000-00805F9B34FB`, same wire protocol as macOS/Windows
- FR-9: Bluetooth device scanning, pairing, auto-reconnect, RFCOMM server accept
- FR-10: Transfer mode switch stops/starts appropriate background services (SSE vs RFCOMM)
- FR-11: Files saved to Downloads folder; received files prompt user to share to other apps
- FR-12: Text received → copied to system clipboard + notification
- FR-13: Credentials stored in EncryptedSharedPreferences (Android Keystore-backed)
- FR-14: 50 MB threshold for single vs chunked upload (same as macOS/Windows)
- FR-15: Boot receiver restarts foreground service on device reboot

## Non-Goals

- No macOS/Windows Server Host App equivalent (server management) — Android is client-only
- No floating ball / overlay window (Android restricts `SYSTEM_ALERT_WINDOW`)
- No background clipboard monitoring — Android 10+ restricts clipboard access to foreground apps; send is manual (notification tap or in-app)
- No Wear OS companion
- No widget (may be added later)
- No tablet-specific layout (single-column Compose layout adapts naturally)

## Technical Considerations

- **Clipboard access:** Android 10+ only allows clipboard read from foreground apps or IMEs. The persistent notification action must briefly bring a transparent Activity to foreground, read clipboard, send, then finish. Alternatively, use `ForegroundServiceStartType` with appropriate type.
- **Bluetooth permissions:** Android 12+ requires `BLUETOOTH_CONNECT` and `BLUETOOTH_SCAN` runtime permissions (no longer covered by `BLUETOOTH` / `BLUETOOTH_ADMIN`).
- **Foreground service type:** Use `foregroundServiceType="connectedDevice"` for Bluetooth mode, `foregroundServiceType="dataSync"` for LAN SSE mode. May need both declared.
- **File provider:** For sharing received files via intent, register a `FileProvider` in the manifest for the Downloads directory.
- **ProGuard/R8:** OkHttp and kotlinx.serialization need keep rules.
- **Large file streaming:** Use `ContentResolver.openInputStream(uri)` and stream chunks — never load full file into memory.
- **Thread model:** Kotlin coroutines (`Dispatchers.IO` for network/disk, `Dispatchers.Main` for UI). Bluetooth I/O on dedicated coroutine dispatcher.

## Success Metrics

- Android app can send/receive text and files to/from macOS and Windows clients via LAN server
- Android app can send/receive text and files to/from macOS and Windows clients via Bluetooth RFCOMM
- One-tap clipboard send from notification completes in under 2 seconds (LAN, small text)
- Chunked upload pause/resume works correctly across app backgrounding
- Service survives device reboot and battery optimization

## Open Questions

- Should we support `ACTION_SEND_MULTIPLE` (batch file send) in the first iteration, or defer?
- Should the persistent notification show the last received clip preview?
- Is there demand for a home-screen widget with quick-send functionality?
