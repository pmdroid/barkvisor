# Product terminology

User-facing words for the machine that runs BarkVisor. **PAS-82** (Home) should reuse this table rather than invent a second glossary.

In the UI and getting-started docs, call that machine a **Device**. Do not call it a node or a cluster member.

## Shared table

| Term | User-facing meaning | Code / API (keep as-is) |
|------|---------------------|-------------------------|
| **Device** | The Mac, PC, or board running this BarkVisor daemon | Inventory JSON keeps `hostId`, `hostname`, and host metrics |
| **Agent** | The daemon role on a Device | `/api/agent/*`, `BarkVisorApp` process |
| **Workload** | A VM (later: app) running on a Device | `VM`, `WorkloadSpec` |
| **Home** | A person’s set of Devices (PAS-82) | Later `/api/home/*` — not shipped yet |
| **Node** | **Do not use** in product copy | — |

`host` is still correct in code, inventory JSON, and OS-level phrasing (host port, host path, host CPU model, Linux host bridge). Map those facts to **Device** whenever the reader is a person using the SPA.

USB **device** still means a peripheral. A BarkVisor **Device** is the computer.

## SPA rules

- No “node” in user-visible strings (`frontend/src/**/*.vue` templates).
- Say **Device** (or “this device”) when you mean the machine running the daemon.
- Networks live at **Networks** (`/networks`), not Settings → Network.

## Related

- [Host process boundary](host-process-boundary.md) — one process ↔ one Device ↔ one data directory
- PAS-82 — Home copy on top of this table
