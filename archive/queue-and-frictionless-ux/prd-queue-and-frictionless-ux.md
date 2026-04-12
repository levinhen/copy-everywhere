# PRD: Queue Semantics & Frictionless Send/Receive UX

## 1. Introduction / Overview

The MVP works end-to-end but every transfer still costs too many clicks: open the panel, navigate to a tab, pick a file, then on the receiving end open the panel again and click "receive". The point of the tool is to feel as fast as a local copy/paste — it currently doesn't.

This PRD reshapes the product around two ideas:

1. **The relay server is a message queue.** A clip is a message; "send" produces, "receive" consumes, and a consumed message is *deleted* from the server. The App panel shows the queue (no more local history).
2. **Devices can be addressed.** Each client registers itself as a named device. A sender can either broadcast to the queue (the default) or target a specific device, in which case the server pushes the clip straight into that device's clipboard / Downloads folder with no user action on the receiving side.

On top of that, the most common flows get one-gesture entry points:

- **Drag a file *or a text selection* onto the menu bar / tray icon → upload starts.** Text is dragged the same way as a file — most macOS / Windows apps already support text drag-out.
- **With the panel open, press the OS paste shortcut (⌘V / Ctrl+V) → whatever is on the clipboard gets sent.** No new shortcut to learn — we reuse paste.

## 2. Goals

- Reduce the gesture cost of a typical text send from ~4 clicks to 1 (drag onto icon, or paste while panel open).
- Reduce the gesture cost of a typical file send from ~5 clicks to 1 (drag onto icon).
- Make the App panel a live view of the server-side queue — no more divergent local histories.
- Support targeted device-to-device push: receiver does nothing, the clip lands directly in their clipboard / Downloads folder.
- Keep the server stateless beyond `STORAGE_PATH` and a tiny new `devices` table; no per-user accounts.

## 3. User Stories

User stories continue the existing numbering from `prd.json` (last MVP story was US-017).

### Server (Go) — queue + device model

#### US-018: Server: device registration table and endpoint
**Description:** As a client, I need to register myself with the server so other clients can target me.

**Acceptance Criteria:**
- [ ] New `devices` table: `id` (TEXT PK, 8-char alphanumeric, server-generated), `name` (TEXT, e.g. "Liyun's MacBook"), `platform` (TEXT: macos|windows|linux), `last_seen_at` (DATETIME), `created_at` (DATETIME)
- [ ] `POST /api/v1/devices/register` body `{name, platform}` → `{device_id}`. Idempotent on `(name, platform)` — re-registering returns the existing id and bumps `last_seen_at`
- [ ] `GET /api/v1/devices` → list of `{device_id, name, platform, last_seen_at}` for all devices seen in the last 30 days
- [ ] `db.Open` still uses `SetMaxOpenConns(1)` (single-writer rule from progress.txt)
- [ ] Handler tests use `t.TempDir()` and `gin.New()` per existing convention
- [ ] `go test ./...` passes

#### US-019: Server: add `target_device_id` and `consumed_at` to clips
**Description:** As a developer, I need clips to optionally carry a target device and to track consumption so the queue model works.

**Acceptance Criteria:**
- [ ] Add columns to `clips`: `target_device_id` (TEXT nullable, FK soft-ref to `devices.id`), `sender_device_id` (TEXT nullable), `consumed_at` (DATETIME nullable)
- [ ] `POST /api/v1/clips` accepts optional multipart fields `target_device_id` and `sender_device_id`
- [ ] `POST /api/v1/uploads/init` accepts the same two optional fields and they're persisted on the resulting clip
- [ ] Migration is in-place: existing rows get NULL in the new columns and continue to work
- [ ] `go test ./...` passes

#### US-020: Server: queue listing and atomic consume-and-delete
**Description:** As a client, I need to see what's in the queue and to consume an item exactly once so two devices can't both grab the same clip.

**Acceptance Criteria:**
- [ ] `GET /api/v1/clips?device_id=XXX` returns clips where `consumed_at IS NULL` AND (`target_device_id IS NULL` OR `target_device_id = XXX`), newest first. Returns the same trimmed `clipResponse` shape as today (no `storage_path`, no `status`).
- [ ] `GET /api/v1/clips/:id/raw` is now an atomic claim: in a single SQLite transaction, set `consumed_at = now()` *if it is currently NULL*, then stream the body. If `consumed_at` was already set, return `410 Gone` with `{error: "already_consumed"}`.
- [ ] After a successful raw fetch, the server schedules deletion of the on-disk file and the row (can reuse the existing `cleanup/` goroutine — just run it more often, or delete inline after the body is fully written).
- [ ] `GET /api/v1/clips/latest` is **deprecated** but kept returning 200 for one release; clients must migrate to `GET /api/v1/clips`.
- [ ] Race test: two parallel `GET /:id/raw` calls — exactly one gets the body, the other gets 410.
- [ ] `go test ./...` passes

#### US-021: Server: SSE push channel for targeted clips
**Description:** As a targeted-receive client, I need a long-lived connection that tells me the moment a clip addressed to me lands, so reception is instant and I don't have to poll.

**Acceptance Criteria:**
- [ ] `GET /api/v1/devices/:id/stream` opens a Server-Sent Events stream (`Content-Type: text/event-stream`), authenticated by the existing Bearer middleware
- [ ] When a clip with `target_device_id == :id` becomes ready (single-shot upload finished, or chunked upload `complete` succeeds), the server emits an SSE event `clip` with payload `{clip_id, type, filename, size_bytes}`
- [ ] Untargeted clips (`target_device_id IS NULL`) do **not** push — they wait in the queue for any client to pull
- [ ] Connection survives idle (heartbeat comment line every 25s) and supports clean reconnect (Last-Event-ID accepted but optional)
- [ ] If multiple SSE connections exist for the same device id, all of them receive the event (server fans out)
- [ ] `go test ./...` passes (use `httptest.NewRecorder` + flusher)

#### US-022: Server: bump cleanup loop for consumed clips
**Description:** As an operator, I want consumed clips to free disk quickly so the relay doesn't accumulate junk.

**Acceptance Criteria:**
- [ ] `cleanup/` goroutine deletes any clip where `consumed_at < now() - 60s` (covers the gap between SSE delivery and the receiver actually downloading the body for `target_device_id != NULL` cases — see US-021/US-020 interaction)
- [ ] Existing TTL behavior for *unconsumed* clips is unchanged
- [ ] Cleanup interval configurable via env `CLEANUP_INTERVAL_SECONDS` (default 30)
- [ ] `go test ./...` passes

### macOS client — drag, one-click send, queue view

#### US-023: macOS: device registration on first launch
**Description:** As a macOS user, I want the App to register itself with the relay the first time I configure a token, so I can be targeted by other devices.

**Acceptance Criteria:**
- [ ] On successful save in `ConfigView`, call `POST /devices/register` with `{name: Host.current().localizedName ?? "Mac", platform: "macos"}`
- [ ] Resulting `device_id` is persisted in `ConfigStore` (UserDefaults; not a secret)
- [ ] `ConfigView` shows the registered device name and id (read-only) under the token field
- [ ] Re-registering on subsequent launches is a no-op (server-side idempotence handles it) but still bumps `last_seen_at`
- [ ] `swift build` succeeds

#### US-024: macOS: drag-and-drop file or text onto menu bar icon
**Description:** As a macOS user, I want to drag a file from Finder *or a text selection from any app* onto the menu bar icon and have it upload immediately, with no panel open.

**Acceptance Criteria:**
- [ ] The menu bar item accepts both `NSPasteboard.PasteboardType.fileURL` and `.string` drops (use a custom `NSView` with `registerForDraggedTypes([.fileURL, .string])` hosted via `NSStatusItem.button`)
- [ ] Dropping one or more files starts upload(s) — small files via `POST /clips`, ≥50 MB files via the chunked flow, exactly as the existing send paths do (reuse `ApiClient`)
- [ ] Dropping a text selection sends it as a `text` clip via `POST /clips`
- [ ] During the drop hover, the menu bar icon shows a visual highlight (different highlight is fine for text vs. file, but not required)
- [ ] On upload success, a `UserNotifications` toast says "Sent <filename>" or "Sent text (<N> chars)"
- [ ] On failure, a toast says "Failed to send: <reason>"
- [ ] `swift build` succeeds

#### US-025: macOS: drag-and-drop file or text onto main panel
**Description:** As a macOS user, I want the open panel to also accept dropped files and text, so I don't have to close it and aim for the menu bar.

**Acceptance Criteria:**
- [ ] `MainPanelView` has a `.onDrop(of: [.fileURL, .text], ...)` modifier covering its full bounds
- [ ] Same upload behavior as US-024 — single code path (extract a `SendService` shared by both stories if helpful)
- [ ] Files → file send; text → text send
- [ ] During hover, the panel shows a dashed-border overlay "Drop to send"
- [ ] `swift build` succeeds

#### US-026: macOS: ⌘V while panel open sends current clipboard
**Description:** As a macOS user, when the panel is already open I want to press ⌘V (the OS paste shortcut) and have whatever is on my clipboard sent to the relay, so I don't have to learn a new shortcut.

**Acceptance Criteria:**
- [ ] While `MenuBarExtra` panel is open and focused, ⌘V is intercepted and triggers a send (use a `.keyboardShortcut("v", modifiers: .command)` on a hidden button, or a `NSEvent.addLocalMonitorForEvents` for `.keyDown`)
- [ ] Send picks the first usable representation in priority order: text → image → file URL (file URL becomes a file send)
- [ ] If the clipboard is empty, show a toast "Clipboard is empty" and do nothing
- [ ] After a successful send, show an in-panel toast banner: "Sent: <preview>"
- [ ] No confirmation dialog
- [ ] ⌘V should *not* paste into any text input that happens to be focused inside the panel — the send hijacks the shortcut globally while the panel is the key window
- [ ] `swift build` succeeds

#### US-027: macOS: panel shows live server queue (replaces local history)
**Description:** As a macOS user, I want the panel to show what's currently waiting on the server, so "history" and "queue" are the same thing.

**Acceptance Criteria:**
- [ ] `MainPanelView` fetches `GET /clips?device_id=<self>` on open and on a 5s refresh tick while open
- [ ] Each row shows: type icon, filename or text preview (first 60 chars), size, age, and a "Receive" button
- [ ] "Receive" calls `GET /clips/:id/raw` and writes text/image to the clipboard or saves a file to `~/Downloads/`. After success the row disappears (server has deleted it).
- [ ] Empty state: "Queue is empty — copy something and click the icon."
- [ ] **Delete** the local `HistoryStore.swift` and all references. There is no local history anymore.
- [ ] `swift build` succeeds

#### US-028: macOS: target-device selector and SSE auto-receive
**Description:** As a macOS user, I want to optionally pin a target device, so my sends bypass the queue and land directly on that device — and conversely, when someone targets me, the clip lands in my clipboard with no clicks.

**Acceptance Criteria:**
- [ ] `ConfigView` has a "Target device" picker populated from `GET /devices` (excluding self). First option is "(Queue — any device)".
- [ ] When a target is set, all sends (drag-drop, auto-send-on-open, manual file picker) include `target_device_id` in the request
- [ ] Independently, the App opens a long-lived SSE connection to `/devices/<self>/stream` whenever a token is configured. On a `clip` event, it calls `GET /clips/:id/raw` and:
  - text → write to `NSPasteboard.general`, show toast "Received text from <sender>"
  - image → write to `NSPasteboard.general`, show toast "Received image from <sender>"
  - file → save to `~/Downloads/<filename>`, show toast "Saved <filename> to Downloads"
- [ ] SSE reconnects with exponential backoff (1s, 2s, 4s, capped at 30s) on disconnect
- [ ] `swift build` succeeds

### Windows client — same surface, with a floating-ball fallback

#### US-029: Windows: device registration on first launch
**Description:** Mirror of US-023 for the WPF client.

**Acceptance Criteria:**
- [ ] On token save in `ConfigWindow`, call `POST /devices/register` with `{name: Environment.MachineName, platform: "windows"}`
- [ ] `device_id` persisted in `ConfigStore` (JSON in `%LOCALAPPDATA%\CopyEverywhere\config.json`)
- [ ] Config UI shows device name and id read-only
- [ ] `dotnet build` succeeds (verified on a Windows host — note CLAUDE.md: don't claim build verified if not actually run)

#### US-030: Windows: drag-and-drop file or text onto floating ball
**Description:** As a Windows user, I want to drag a file *or selected text* onto a small drop target. Because `Hardcodet.NotifyIcon.Wpf` does **not** natively support drop targets on the tray icon, we ship a small always-on-top "floating ball" window instead. (Confirmed in user answers: skip the tray-drop investigation, go straight to the ball.)

**Acceptance Criteria:**
- [ ] Ship a `FloatingBallWindow`: 64x64 borderless circular `Window` with `Topmost=true`, `WindowStyle=None`, `AllowsTransparency=true`, `AllowDrop=true`, draggable to reposition (position persisted in config)
- [ ] A "Show floating ball" toggle in config (default ON for Windows) controls visibility
- [ ] `Drop` handler accepts both `DataFormats.FileDrop` and `DataFormats.UnicodeText` / `DataFormats.Text`
- [ ] Files trigger the existing `ApiClient` send path — small files via `POST /clips`, ≥50 MB via chunked upload (reuse `ProgressStreamContent`)
- [ ] Text triggers a `text` clip send via `POST /clips`
- [ ] Success / failure surfaced via `Microsoft.Toolkit.Uwp.Notifications` toast
- [ ] `dotnet build` succeeds

#### US-031: Windows: drag-and-drop file or text onto main window
**Description:** Mirror of US-025 — the main window also accepts drops, both files and text.

**Acceptance Criteria:**
- [ ] `MainWindow` root grid has `AllowDrop=true` and handles `Drop`/`DragEnter` for both `DataFormats.FileDrop` and text formats
- [ ] Same upload path as US-030 (single `SendService`)
- [ ] Visual hover state ("Drop to send" overlay)
- [ ] `dotnet build` succeeds

#### US-032: Windows: Ctrl+V while main window focused sends current clipboard
**Description:** Mirror of US-026. While the main window is focused, Ctrl+V is intercepted and sends the current clipboard contents — no new shortcut to learn.

**Acceptance Criteria:**
- [ ] Bind a `KeyBinding` for `Ctrl+V` on `MainWindow` (or use a `RoutedCommand` on the window's `InputBindings`) so the shortcut fires only while the window is focused
- [ ] Send picks the first usable representation in priority order: text (`Clipboard.GetText`) → image (`Clipboard.GetImage`) → file URL (`Clipboard.GetFileDropList`)
- [ ] If clipboard is empty, show a toast "Clipboard is empty" and do nothing
- [ ] After a successful send, show an in-window toast banner: "Sent: <preview>"
- [ ] No confirmation dialog
- [ ] Ctrl+V should *not* paste into any text input that happens to be focused inside the window — the binding should win
- [ ] `dotnet build` succeeds

#### US-033: Windows: main window shows live server queue (replaces local history)
**Description:** Mirror of US-027.

**Acceptance Criteria:**
- [ ] `MainWindow` polls `GET /clips?device_id=<self>` on open and every 5s while visible
- [ ] Each row: type icon, preview, size, age, "Receive" button
- [ ] "Receive" → `GET /clips/:id/raw` → text/image to `Clipboard`, file saved to user's Downloads via `KnownFolders` or `Environment.GetFolderPath(SpecialFolder.UserProfile) + "\Downloads"`
- [ ] After success, row disappears
- [ ] **Delete** `Services/HistoryStore.cs` and all references
- [ ] `dotnet build` succeeds

#### US-034: Windows: target-device selector and SSE auto-receive
**Description:** Mirror of US-028.

**Acceptance Criteria:**
- [ ] Config UI has "Target device" combobox populated from `GET /devices`
- [ ] All sends include `target_device_id` when a target is set
- [ ] Background SSE connection to `/devices/<self>/stream` while a token is configured. .NET 8 has no built-in SSE client — implement a small reader using `HttpClient` with `HttpCompletionOption.ResponseHeadersRead` and a `StreamReader` line loop
- [ ] On `clip` event: text/image → `Clipboard`, file → Downloads folder, with a toast naming the sender
- [ ] Reconnect with exponential backoff, capped at 30s
- [ ] `dotnet build` succeeds

## 4. Functional Requirements

- **FR-1:** A clip on the server has at most one consumer. Once consumed, the row and its file are deleted.
- **FR-2:** A clip may carry an optional `target_device_id`. If set, only that device sees it via `GET /clips`, and the server pushes an SSE notification to that device.
- **FR-3:** A clip without a `target_device_id` is queued and visible to all devices via `GET /clips`. The first device to call `GET /clips/:id/raw` consumes it; concurrent callers receive `410 Gone`.
- **FR-4:** Each client registers exactly once per `(name, platform)` pair and stores the resulting `device_id` locally.
- **FR-5:** The macOS menu bar icon and the Windows floating ball accept both file drops and text drops, and start an upload immediately, reusing the existing single-shot / chunked upload path based on the 50 MB threshold.
- **FR-6:** While the main panel (macOS) or main window (Windows) is focused, the OS paste shortcut (⌘V / Ctrl+V) is intercepted and sends the current clipboard contents as a clip. Priority order for picking a representation: text → image → file URL. Empty clipboard → no-op toast.
- **FR-7:** The main panel/window displays the live contents of `GET /clips?device_id=<self>`. There is no client-side history store.
- **FR-8:** Each client maintains a single SSE connection to `/devices/<self>/stream` while a token is configured. On a `clip` event, it auto-fetches and applies the clip (text/image → clipboard, file → Downloads folder) and shows a toast.
- **FR-9:** All new endpoints sit under `/api/v1` and require Bearer auth via the existing middleware. `/health` remains the only unauthenticated route.
- **FR-10:** SQLite remains single-writer (`SetMaxOpenConns(1)`); concurrent consume races are serialized through that.

## 5. Non-Goals

- **No accounts, no per-user namespacing.** A single `ACCESS_TOKEN` still gates the whole relay; "device" is purely an addressing label, not an identity.
- **No end-to-end encryption.** TLS at the transport layer is the only crypto, same as MVP.
- **No conflict resolution / re-queue.** A 410 Gone is final — the second device just doesn't get it. Sender retry is the user's responsibility.
- **No offline queue on the client.** If the network is down at send time, it fails; the client does not buffer.
- **No history beyond the queue.** Once consumed, a clip is gone everywhere — server, sender's panel, receiver's panel.
- **No reordering or priority.** The queue is plain newest-first.
- **No mobile clients in this PRD.**
- **No replacement for the chunked-upload protocol.** US-018+ all reuse it as-is.

## 6. Design Considerations

- **Toasts** are the primary feedback channel. Both clients already use them (`UserNotifications` on macOS; `Microsoft.Toolkit.Uwp.Notifications` on Windows).
- **Drag hover state** matters more than it sounds — without it, users will not believe the icon is a drop target. Mandatory in US-024, US-025, US-030, US-031.
- **Floating ball (Windows)** should be visually unobtrusive — semi-transparent, draggable, snaps to screen edges. Position persisted across launches.
- **Queue rows** should make it obvious whether an item is targeted at me ("→ you") vs. broadcast (no badge), so users understand which clips are mine to receive.
- **No local history** means the panel is empty when the queue is empty. Empty state copy must explain this isn't a bug ("Queue is empty — copy something and click the icon").

## 7. Technical Considerations

- **SSE on Go/Gin:** straightforward with `c.Stream(...)` + a per-device subscriber map protected by a `sync.RWMutex`. Fan-out is in-memory; no Redis. If the process restarts, clients reconnect and resume polling — no replay needed because un-consumed clips are still in the DB and visible via `GET /clips`.
- **SSE on .NET 8:** no first-party client. Roll a small reader as described in US-034. Alternatively `LaunchDarkly.EventSource` is a tiny dependency if we'd rather not hand-roll.
- **macOS menu bar drop target:** `NSStatusItem.button` is an `NSStatusBarButton` (an `NSButton` subclass). Call `registerForDraggedTypes([.fileURL])` on it and implement `draggingEntered`/`performDragOperation` via a `NSDraggingDestination` subclass. SPM-only build still has access to AppKit — no Info.plist changes needed.
- **Atomic consume:** since `SetMaxOpenConns(1)`, an `UPDATE clips SET consumed_at = ? WHERE id = ? AND consumed_at IS NULL` followed by checking `RowsAffected()` is sufficient — no explicit transaction needed.
- **Cleanup race:** the cleanup goroutine must wait at least `CLEANUP_INTERVAL_SECONDS` (default 30) before deleting a consumed clip's file, to give the consuming HTTP response time to finish streaming. Alternatively, delete inline after the response writer flushes. Inline is simpler — prefer that.
- **Clipboard hash for auto-send:** SHA-256 of the bytes is fine; store as a hex string in `UserDefaults` / config JSON. Reset on token change.
- **Backwards compat:** keep `GET /clips/latest` returning 200 for one release with a `Deprecation` header. Remove in a follow-up PRD once both clients are migrated.
- **`progress.txt` Codebase Patterns block:** add new entries after this PRD lands — at minimum: SSE pattern, atomic consume pattern, drag-target pattern on `NSStatusBarButton`, Windows floating-ball pattern.

## 8. Success Metrics

- **Send-text gesture count:** drops from 4 (open panel → pick text tab → click area → click send) to 1 (drag selection onto icon, or ⌘V/Ctrl+V while panel open).
- **Send-file gesture count:** drops from 5 (open panel → file tab → click pick → choose file → click send) to 1 (drag onto icon).
- **Receive-targeted gesture count:** drops from 3 (open panel → click receive → confirm) to 0 (clipboard already has it).
- **Queue freshness:** a consumed clip disappears from all clients' panels within one 5s poll cycle.
- **Zero duplicate consumption:** under a 100-parallel-consumer race test, exactly one consumer succeeds; the other 99 get 410 Gone.

## 9. Open Questions

1. **Targeted clip + offline target.** If A targets B but B is offline, should the clip (a) sit in the queue and be visible to B when it next polls, or (b) fail immediately at send time? Current draft assumes (a) — the SSE push is best-effort, and the clip remains in the DB until B pulls or TTL expires. Confirm.
2. **Multiple clipboard items on macOS.** `NSPasteboard` can hold multiple representations. We send "the first item" — does that mean the first `pasteboardItem`, or do we always prefer text > image > file? Current draft: prefer text, then image, then file URLs (which become a file send).
3. **Windows tray-icon drop feasibility.** US-030 budgets up to one day to attempt the real tray-icon drop before falling back to the floating ball. If the investigation says ">1 day", we ship the ball and skip the tray attempt entirely. OK?
4. **Sender's view of their own sends.** Once A sends a clip targeted at B and B receives it, the clip is gone. A has no record. Is that acceptable, or does A want a small "recently sent" log (which would re-introduce a local store, contradicting the "no local history" goal)?
5. **SSE through reverse proxies.** If users put nginx in front of the relay, they need `proxy_buffering off;` for the SSE route. Should we document this in the README, or add a fallback long-poll endpoint? Current draft: doc-only.


## 10. Answer for open questions

1. 对的,消息内容会先尝试发送给B,B如果离线了,那么直接发送到队列里,和普通的消息一样
2. 剪贴板这个逻辑我想改变一下,我看了一下似乎文本也原生支持拖拽,所以我觉得原本的点击APP图标自动复制剪贴板第一个元素的逻辑可以去掉.现在点击APP图标并不会读取剪贴板第一个内容并直接发送,至于文本,也要和文件一样,拖拽复制.
3. 至于windows的这个托盘交互,按你的想法来吧.然后,以防万一,我要补充一个交互,打开APP之后除了要有消息队列,还需要支持粘贴快捷键(系统原生的,也就是说在打开APP之后粘贴行为就是发送到服务端)
4. 对的,不需要留有发送记录
5. 对的,仅说明就好