# Snapshot contract

Shared reference Snapshot JSON used by tests on both sides:

- `agent/` (Go) serializes its Snapshot types into exactly `normal.json`, `no-docker.json`, `empty.json`.
- `MasshCore/` (Swift) must decode every fixture, including `v1.json` (previous format) and recognise `future.json` (unknown newer format) without failing.

Format version history:

- **1** — no `overview.swap`, no `overview.cpu.perCorePercent`, no container `memoryLimitBytes`.
- **2** — current.

A WebSocket message is one Snapshot per second. Any change to the shape bumps `formatVersion`.
