# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Source of truth

- [prd.json](prd.json) — the canonical feature list. Read this first to understand what the project does and what is in/out of scope. The MVP (US-001 … US-017) is complete; the current iteration covers US-018 … US-034 (queue semantics + frictionless send/receive UX). The full PRD doc for the current iteration lives at [tasks/prd-queue-and-frictionless-ux.md](tasks/prd-queue-and-frictionless-ux.md).
- The MVP's prd.json, progress log, and original PRD doc are archived under [archive/mvp/](archive/mvp/) — historical context only, no longer the source of truth.
- This repo is driven by the Ralph autonomous agent loop ([scripts/ralph/ralph.sh](scripts/ralph/ralph.sh) + [scripts/ralph/CLAUDE.md](scripts/ralph/CLAUDE.md)). One commit ≈ one user story; commit messages follow `feat: [US-XXX] - [Title]`. The hard-won "do this / don't do that" list lives in the **Conventions and gotchas** section below — add to it (don't replace) when you discover a new reusable pattern.

## Architecture

Three independent codebases share a single REST contract:

- **[server/](server/)** — Go 1.22+ / Gin relay. SQLite metadata (`modernc.org/sqlite`, pure-Go, no CGO) plus a content store on disk. The server is stateless beyond `STORAGE_PATH`; clients address content by 6-char alphanumeric Clip IDs. Layout: `config/` env loader, `db/` schema + helpers, `middleware/` Bearer auth, `handlers/` (`clips.go` for single-shot, `uploads.go` for chunked), `cleanup/` background TTL goroutine, `main.go` wiring.
- **[macos/CopyEverywhere/](macos/CopyEverywhere/)** — Swift Package Manager executable target (no .xcodeproj), macOS 13+ MenuBarExtra app. State lives in `ConfigStore` (`@MainActor` ObservableObject) and `HistoryStore`; views in `MenuBarView` / `MainPanelView` / `ConfigView`.
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
ACCESS_TOKEN=dev go run .               # local run (also reads PORT, STORAGE_PATH, MAX_CLIP_SIZE_MB, TTL_HOURS)
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

- **SSE broker is a shared singleton.** `sse.NewBroker()` is created once in `main.go` and injected into `ClipHandler`, `UploadHandler`, and `DeviceHandler`. Targeted clip notifications flow through `Broker.Notify(targetDeviceID, event)` — call it after a clip with `TargetDeviceID != nil` becomes `ready` (single-shot upload or chunked complete). SSE tests need `httptest.NewServer` (not `NewRecorder`) because streaming requires a real HTTP connection.
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
- **MenuBarExtra replaced with manual NSStatusItem + NSPopover** (US-024). `AppDelegate` (`@MainActor`) owns the status item, popover, `ConfigStore`, and `HistoryStore`. `StatusItemDropView` is a transparent overlay on the button for drag-and-drop. `MenuBarView` is hosted via `NSHostingController`. The popover uses `.applicationDefined` behavior + `NSEvent.addGlobalMonitorForEvents` to avoid the double-toggle issue with `.transient`.
- Use `UserNotifications` (not the deprecated `NSUserNotification`).
- Multipart bodies are built by hand with a UUID boundary — there is no Swift helper.
- `ConfigStore.historyStore` is wired via `MenuBarView.onAppear` (not init param). (Note: `HistoryStore` is being removed in US-027 — the new server-queue panel replaces it.)
- **`URLSession` progress → `AsyncStream` bridge.** `UploadProgressDelegate` / `DownloadProgressDelegate` (in `ApiClient`) implement `URLSessionTaskDelegate` / `URLSessionDownloadDelegate` and surface progress as `AsyncStream<Double>` so views can `for await` over it. Reuse this pattern — don't roll a new delegate per call site.
- **Stream chunks with `FileHandle`.** The chunked uploader opens a `FileHandle` and `read(upToCount:)`s one chunk at a time. Don't `Data(contentsOf:)` the whole file — large uploads will OOM.

**Windows:**

- WPF `PasswordBox` doesn't support two-way binding — sync via the `PasswordChanged` event.
- Set `ShutdownMode="OnExplicitShutdown"` so hiding the main window to tray doesn't kill the app.
- `Microsoft.Toolkit.Uwp.Notifications` v7.1.3 *does* work in .NET 8 WPF despite the "Uwp" name.
- There is no built-in progress-tracking `HttpContent` in .NET — use the in-repo `ProgressStreamContent` (lives in `Services/ApiClient.cs`).
- `OpenFileDialog`/`SaveFileDialog` are in `Microsoft.Win32`, not `System.Windows.Forms`.
- **`MultipartFormDataContent`** in `ApiClient` is what the server's `multipart/form-data` parsing expects — use it, don't hand-roll boundaries like the macOS client does.

**Cross-platform:**

- **Secrets storage:** macOS → Keychain via the Security framework (delete-before-add for updates). Windows → Credential Manager via the `CredentialManagement` NuGet.
- **History storage (MVP, being removed):** local-only on both clients (macOS `UserDefaults` + JSON Codable; Windows JSON file in `%LOCALAPPDATA%\CopyEverywhere\history.json`). US-027/US-033 delete both stores in favor of a live view of the server queue.
