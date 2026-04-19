# PRD: Targeted Auto-Delivery Reliability

## 1. Introduction / Overview

CopyEverywhere already has the intended product shape for targeted delivery: after the sender selects a target device, the server stores the clip, emits a targeted SSE event, and the receiving client is supposed to auto-download the clip and write it into the local clipboard or Downloads folder without requiring the user to click "Receive".

The current problem is not that SSE is absent. The server emits targeted `clip` events, and all three clients already contain SSE receive handlers. The problem is that "targeted send means direct delivery" is not yet treated as a strict product contract with clear state, reliability guarantees, fallback behavior, and diagnostics. As a result, the system feels inconsistent: sometimes it behaves like queue delivery, sometimes like push delivery, and when auto-delivery fails the user cannot tell why.

This PRD defines a focused iteration that makes targeted delivery a first-class mode:

1. Selecting a target device means "deliver automatically if that device is online and its receiver channel is healthy".
2. The relay server remains the source of truth and transfer path for LAN mode.
3. Clients do not open inbound HTTP interfaces for this iteration.
4. SSE is retained as the notification channel, while clip bytes continue to be fetched from the relay server with authenticated `GET /clips/:id/raw`.
5. If auto-delivery cannot complete, the clip must remain safely recoverable through the queue with explicit user-visible status.

This keeps the architecture simple, avoids NAT / firewall / local security issues from exposing client-side APIs, and matches the existing codebase much better than a new peer-to-peer LAN callback design.

## 2. Goals

- Make "targeted send" reliably auto-deliver to the destination device when that device is online in LAN mode.
- Remove the need for the receiving user to click "Receive" in the success path for targeted text, image, and file clips.
- Preserve zero-loss semantics: failed auto-delivery must fall back to a recoverable queue item instead of silently dropping content.
- Expose enough status and logs that users can tell whether the destination device is connected and whether the last targeted delivery succeeded or fell back.
- Keep the existing server-centric LAN architecture; do not require clients to expose new local HTTP endpoints.

## 3. User Stories

User stories continue the existing numbering from the archived Android iteration (last story was US-068).

### US-069: Server: explicit targeted delivery state model
**Description:** As a developer, I need the server to distinguish between queued, auto-delivering, delivered, and fallback cases so clients can implement predictable targeted behavior.

**Acceptance Criteria:**
- [ ] Add clip delivery fields or equivalent persisted state that distinguish at minimum: `ready`, `targeted_pending`, `targeted_delivered`, `targeted_fallback`, `failed`
- [ ] A targeted clip is never marked delivered only because the SSE event was emitted
- [ ] A targeted clip remains recoverable until a client successfully claims the raw content
- [ ] Untargeted queue behavior remains unchanged
- [ ] `go test ./...` passes

### US-070: Server: device presence and receiver health contract
**Description:** As a sender, I want the system to know whether my target device is actually reachable for auto-delivery so the app can set correct expectations.

**Acceptance Criteria:**
- [ ] Server tracks per-device receiver connectivity for LAN mode based on active SSE subscription and heartbeat freshness
- [ ] `GET /api/v1/devices` includes a machine-readable receiver status for each device, such as `online`, `degraded`, or `offline`
- [ ] A device is only considered `online` for targeted auto-delivery when its SSE stream is active and fresh
- [ ] Server-side tests cover status transitions on connect, disconnect, and heartbeat timeout
- [ ] `go test ./...` passes

### US-071: Server: delivery acknowledgement and fallback timeout
**Description:** As a receiving client, I need targeted auto-delivery to become confirmed only after I really consume the clip so the server can distinguish success from missed notifications.

**Acceptance Criteria:**
- [ ] Define one delivery confirmation mechanism for targeted clips:
  Option A: successful `GET /clips/:id/raw` by the targeted device is the delivery acknowledgement
  Option B: add a dedicated acknowledgement endpoint only if raw consumption alone is insufficient
- [ ] The chosen mechanism is documented in handler comments and API docs
- [ ] If the targeted device does not consume the clip within a configurable timeout after notification, the clip moves to `targeted_fallback`
- [ ] Fallback clips remain visible in the queue for the target device and can be received manually
- [ ] `go test ./...` passes

### US-072: macOS: make targeted auto-delivery observable and strict
**Description:** As a macOS user, I want the app to clearly show whether targeted auto-delivery is armed and whether the last targeted clip was delivered automatically or fell back to manual receive.

**Acceptance Criteria:**
- [ ] Config UI shows receiver status for self: connected, reconnecting, or disconnected
- [ ] Target device picker shows each candidate device's receiver status
- [ ] When sending to a target marked offline or degraded, the app shows a warning before send or labels the action as queue fallback
- [ ] On SSE-targeted auto-receive success, text and image clips update `NSPasteboard.general`; files save to `~/Downloads`
- [ ] On auto-receive failure, the app shows a non-intrusive warning that the item remains in queue for manual receive
- [ ] `swift build` succeeds

### US-073: Windows: make targeted auto-delivery observable and strict
**Description:** As a Windows user, I want targeted delivery to behave consistently with macOS, with clear receiver status and visible fallback behavior.

**Acceptance Criteria:**
- [ ] Main/config UI shows self receiver status and target device receiver status
- [ ] Text and image clips received through targeted SSE flow are written to `Clipboard`; files are saved to Downloads
- [ ] On auto-receive failure, the clip remains available in the queue and the user sees a toast or inline status explaining fallback
- [ ] SSE reconnect state is surfaced in the UI instead of failing silently
- [ ] `dotnet build` succeeds on a Windows host

### US-074: Android: foreground auto-delivery reliability
**Description:** As an Android user, I want targeted clips to land on my device automatically while the foreground service is running, with clear fallback when background restrictions or connectivity block delivery.

**Acceptance Criteria:**
- [ ] Foreground service exposes receiver status based on active SSE loop health
- [ ] On targeted SSE event, text clips are copied to clipboard and files are saved to Downloads exactly as the current service intends
- [ ] If auto-delivery fails because the service is unavailable, auth expired, or clip consumption fails, the clip remains available in the queue
- [ ] Notification text or settings UI exposes whether auto-delivery is currently active
- [ ] `./gradlew assembleDebug` succeeds

### US-075: Shared UX: explicit delivery mode and fallback messaging
**Description:** As a user, I want the product to clearly distinguish "queue send" from "targeted auto-delivery" so I know what behavior to expect before and after I send.

**Acceptance Criteria:**
- [ ] The UI labels the two delivery modes explicitly:
  Queue mode: any eligible device may receive manually
  Targeted mode: selected device auto-delivers when online, otherwise falls back to queue
- [ ] Send success messaging distinguishes:
  `Delivered automatically`
  `Waiting for target device`
  `Delivered to queue fallback`
- [ ] Queue rows indicate whether an item is a normal queue item or a fallback from failed targeted delivery
- [ ] UI copy is aligned across macOS, Windows, and Android
- [ ] UI stories include visual verification on their native platform

### US-076: Diagnostics, metrics, and regression coverage
**Description:** As a developer, I need enough diagnostics to debug why targeted delivery failed and enough tests to prevent future regressions.

**Acceptance Criteria:**
- [ ] Server logs targeted delivery lifecycle: clip created, SSE notified, raw consumed, fallback triggered, expired
- [ ] Clients log SSE connect, disconnect, reconnect backoff, targeted receive start, targeted receive success, and fallback
- [ ] Automated tests cover:
  targeted clip delivered while receiver is online
  targeted clip replayed after reconnect
  targeted clip falls back when receiver does not consume
  duplicate consumption returns `410 Gone`
- [ ] Manual test checklist exists for macOS, Windows, and Android
- [ ] Relevant platform builds/tests pass where the environment supports them

## 4. Functional Requirements

- FR-1: Selecting a target device changes send semantics from "queue only" to "prefer automatic delivery to this specific device".
- FR-2: LAN mode continues to use the relay server as the only required network endpoint for clip content transfer.
- FR-3: Clients must not need to expose inbound HTTP APIs for this iteration.
- FR-4: The server must expose whether each registered device is currently capable of receiving targeted auto-delivery.
- FR-5: A targeted clip must generate an SSE notification only for the addressed device.
- FR-6: A targeted clip is not considered delivered until the addressed device successfully consumes the clip content.
- FR-7: If targeted auto-delivery does not complete within the defined timeout, the clip must remain available to the addressed device through the queue.
- FR-8: Receiver UI must show whether auto-delivery is active, reconnecting, or unavailable.
- FR-9: Sender UI must show whether the chosen target device is currently online for automatic delivery.
- FR-10: Text clips received through targeted auto-delivery must be written directly into the OS clipboard on macOS, Windows, and Android.
- FR-11: Image clips received through targeted auto-delivery must be written to the clipboard where the platform supports it; otherwise they must follow existing platform behavior.
- FR-12: File clips received through targeted auto-delivery must be saved to the platform Downloads folder with a user-visible notification.
- FR-13: Auto-delivery failure must never silently discard a clip.
- FR-14: Queue UI must show targeted fallback items distinctly from normal untargeted queue items.
- FR-15: Existing untargeted queue semantics must continue to work for all platforms.

## 5. Non-Goals (Out of Scope)

- No new peer-to-peer LAN transport for this iteration.
- No requirement for clients to expose inbound REST APIs, gRPC services, WebSockets, or local listening sockets for LAN auto-delivery.
- No replacement of SSE with MQTT, WebRTC, or Bluetooth for the LAN mode success path.
- No end-to-end encryption redesign beyond the existing access-token based LAN trust model.
- No cross-account, Internet-routable, or cloud relay architecture changes.
- No automatic clipboard sync of every local clipboard change; this feature only covers explicit sends with a selected target device.

## 6. Design Considerations

- The target device selector should communicate receiver readiness directly in the list, not only after the user taps send.
- "Targeted delivery" should read like a mode, not like a hidden implementation detail.
- Fallback state should be calm and explicit. Example copy:
  `Target device is offline. Item will stay in queue until it reconnects or you receive it manually.`
- Receiver status should be visible in configuration and in the main panel so users can debug the product themselves before checking logs.

## 7. Technical Considerations

- Existing code already supports the basic notification path:
  server emits targeted SSE events in `server/handlers/clips.go` and `server/handlers/uploads.go`
  server replays pending targeted clips in `server/handlers/devices.go`
  macOS handles targeted SSE auto-receive in `macos/CopyEverywhere/Sources/CopyEverywhere/ConfigStore.swift`
  Windows handles targeted SSE auto-receive in `windows/CopyEverywhere/MainWindow.xaml.cs`
  Android handles targeted SSE auto-receive in `android/app/src/main/java/com/copyeverywhere/app/service/CopyEverywhereService.kt`
- This means the recommended implementation is evolutionary, not architectural replacement.
- The largest current gap is not transport capability; it is reliable state modeling and product-visible status.
- For targeted delivery acknowledgement, the preferred first approach is to treat successful raw consumption by the addressed device as the acknowledgement, because that reuses the existing atomic consume path and avoids inventing a second confirmation protocol.
- If later evidence shows that LAN server indirection is still too slow or unreliable for large files, direct client-to-client transport can be explored in a separate PRD. It should not be mixed into this iteration.

## 8. Success Metrics

- 95% or more of targeted text sends to an online device complete auto-delivery without manual receive in internal testing.
- Median time from send completion to clipboard update on the target device is under 2 seconds on a healthy LAN for text clips.
- Manual "Receive" usage for targeted clips drops by at least 80% compared with the current behavior.
- Support/debug sessions about "why didn't it arrive automatically" can be answered from product-visible status plus logs without attaching a debugger.
- No increase in duplicate-consume or lost-clip incidents versus current queue semantics.

## 9. Open Questions

- Should target-device send be blocked when the target is currently offline, or should the default always be "send and fallback to queue"?
- Do we need a dedicated `delivery_status` API for recent targeted sends, or is queue state plus local send toast enough for the first iteration?
- Should images on Android remain treated as files for auto-delivery, or do we want a separate clipboard-image path there as well?
- How long should the targeted fallback timeout be by default for text versus large file uploads?
- Do we want the sender to see sender-side confirmation that the target actually consumed the clip, or is receiver-side confirmation enough for now?

## 10. Recommended Product Decision

For this iteration, use the existing relay-server architecture and strengthen it:

- Keep SSE as the event channel.
- Keep `GET /clips/:id/raw` as the content retrieval path.
- Do not expose new inbound interfaces on client devices.
- Add presence, delivery state, fallback semantics, and user-visible status.

This is the lowest-risk path that matches the existing repository, solves the actual user-facing gap, and avoids creating a second transport architecture before the first one has been productized correctly.
