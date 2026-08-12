# Host process boundary

**One BarkVisor process ↔ one host identity ↔ one data directory.**

## Why

BarkVisor is moving toward multi-device homes (Mac + Linux + boards), but multi-host is **N daemon installs**, not one process with many hosts.

- `Config.dataDir`, SQLite, VM sockets, and QEMU children are process-global and **host-local**.
- Pairing / a control plane later **attaches** hosts over the network; it does not co-locate multiple hosts in one database.

## Conventions

| Concept | Rule |
|--------|------|
| Process | Single OS process (LaunchDaemon / systemd / `BarkVisorApp`) |
| Host | Physical or virtual machine running that process |
| Data dir | One tree per install (`BARKVISOR_DATA_DIR` / default path) |
| Host identity | Durable UUID at `dataDir/host-id` (0600, created on first start; same pattern as `jwt-secret`) |
| Inventory | `HostInventoryService.snapshot()` describes *this* host only, including `hostId` |
| Inventory API | `GET /api/agent/inventory` (JWT / API key) returns the snapshot JSON |
| Workloads | VMs and disks live under this host’s data dir; they keep running without a remote controller |

## Optional HostContext

New Core code may take a small context value (data dir, durable `hostId`, inventory access) instead of adding more global statics. A full rewrite of `Config` is **not** required; `Config.hostId` and `HostIdentity.loadOrCreate(dataDir:)` are the accessors.

## Related

- Product: agent identity + inventory API (PAS-42)
- Prep: HostInventory builder (PAS-106), capabilities projection (PAS-107)
