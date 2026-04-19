# LAN Discovery DHCP Regression Checklist

Use this checklist when validating DHCP-style LAN discovery recovery for `US-096`.

## Common Setup

1. Start the Go relay and confirm `/health` returns the same `server_id` before and after a server restart.
2. Put the client under test in `LAN` mode and verify it has a remembered LAN server selection plus a saved manual fallback URL.
3. Make the server's reachable address change without changing its `server_id`.
   - Preferred: reconnect the host to the network so DHCP assigns a new IP.
   - Acceptable fallback: move the server to another NIC / localhost forwarding path that changes `host:port`.

## macOS

1. Launch `CopyEverywhere` and keep Console or the in-app local log open.
2. Confirm logs show:
   - discovery start
   - resolved `server_id`
   - restored selection or unique auto-select
   - manual fallback preservation if the selected server is not rediscovered
3. With one rediscovered server, verify the app updates `Host URL` automatically and targeted receive still reconnects.
4. With multiple servers visible, verify the Config UI stays passive and does not auto-pick a different server.
5. With discovery unavailable, verify the saved manual URL remains usable and the UI shows the unavailable/fallback state.

## Windows

1. Launch the tray app on a Windows host and keep Visual Studio Output or another debug console attached.
2. Confirm logs show:
   - discovery start
   - resolved `server_id`
   - restored selection or unique auto-select
   - multi-server deferred-to-selection
   - manual fallback preservation after a miss
3. After the server IP changes, verify the restored selection updates `Host URL` and normal send/receive still work.
4. With two discovered servers, verify settings wait for explicit selection instead of changing the saved endpoint.
5. If discovery fails, verify the saved manual URL continues to work.

## Android

1. Start the foreground service in `LAN` mode and watch `adb logcat` for `CopyEverywhereService` and `MdnsDiscoveryService`.
2. Confirm logs show:
   - discovery start
   - resolved `server_id`
   - restored selection or unique auto-select
   - multi-server deferred-to-config
   - manual fallback preservation after a miss
3. After the server IP changes, verify the service updates the selected endpoint and SSE reconnects automatically.
4. With multiple discovered servers, verify the Config screen shows passive guidance and no forced auto-selection.
5. If discovery is unavailable, verify the saved manual URL remains active and the app can still send/receive over that URL.
