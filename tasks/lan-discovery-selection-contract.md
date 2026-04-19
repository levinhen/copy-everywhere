# LAN Discovery Selection Contract

This contract is the implementation companion for the active Ralph iteration in `scripts/ralph/prd.json` and `scripts/ralph/progress.txt`.

Use this document as the cross-platform source for LAN discovery behavior until the iteration is complete. Platform-specific stories may add implementation detail, but they should not redefine the rules below.

## Canonical identity

- `server_id` is the durable identity for a LAN server.
- `host:port` is display and transport metadata only. It is not a stable selection key.
- Discovery metadata and `/health` must expose the same `server_id`.

## Selection sources

Clients must distinguish these active LAN endpoint sources:

- `auto_discovered`
  Fresh state, exactly one discovered server, no persisted selection.
- `restored_selection`
  A previously selected `server_id` is rediscovered, possibly at a new host or port.
- `manual_fallback`
  The client is using an explicitly entered or previously saved URL because discovery has not restored a selected server.

## Shared rules

1. Fresh state + exactly one discovered server:
   auto-select it, update the effective host URL, mark source `auto_discovered`.
2. Fresh state + multiple discovered servers:
   do not auto-pick, do not show a blocking chooser, keep waiting for explicit user choice in config UI.
3. Persisted selected `server_id` rediscovered:
   update the effective host URL to the discovered endpoint and mark source `restored_selection`.
4. Persisted selected `server_id` not rediscovered:
   keep the previously saved manual URL as a non-fatal fallback and mark source `manual_fallback`.
5. Explicit manual selection:
   never silently replace it with a different discovered server when multiple servers are present.

## Persistence shape

Each client should persist:

- selected `server_id`
- last-known display metadata needed to render the selected server cleanly
- current LAN selection source
- manual host URL fallback

The later platform stories in this iteration should implement behavior using these fields rather than inventing new selection-state models.
