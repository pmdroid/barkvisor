# Product terminology

Shared words for BarkVisor in the UI and getting-started docs. **Home** is the tenancy. **Device** is the machine. Do not invent a second glossary.

A single-device install is a **Home of one**. More Devices join that Home later; they are not a cluster.

## Shared table

| Term | User-facing meaning | Code / API (keep as-is) |
|------|---------------------|-------------------------|
| **Home** | A person’s set of Devices (one or more) | Later `/api/home/*` — not shipped yet |
| **Device** | The Mac, PC, or board running this BarkVisor daemon | Inventory JSON keeps `hostId`, `hostname`, and host metrics |
| **Agent** | The daemon role on a Device | `/api/agent/*`, `BarkVisorApp` process |
| **Workload** | A VM (later: app) running on a Device | `VM`, `WorkloadSpec` |
| **Library** | Images and templates you can deploy | Image / template repositories |
| **Node** | **Do not use** in product copy | — |
| **Cluster** | **Do not use** in product copy | — |
| **Datacenter** | **Do not use** in product copy | — |
| **Quorum** | **Do not use** in product copy | — |

`host` is still correct in code, inventory JSON, and OS-level phrasing (host port, host path, host CPU model, Linux host bridge). Map those facts to **Device** whenever the reader is a person using the SPA.

USB **device** still means a peripheral. A BarkVisor **Device** is the computer.

## SPA rules

- No “node”, “cluster”, “datacenter”, or “quorum” in user-visible strings (`frontend/src/**/*.vue` templates).
- Say **Device** (or “this device”) when you mean the machine running the daemon.
- Say **Home** when you mean the person’s set of Devices. One Device is already a Home.
- Networks live at **Networks** (`/networks`), not Settings → Network.
- First-run setup is `SetupView` (`/setup`). Do not add a second overlay wizard.
- Joining an existing Home is a branch of that same `SetupView`, using `/api/pairing/join`. Add a Device from Settings → Home (`/api/pairing/codes`).

## Related

- [First launch](getting-started-first-launch.md) — setup on this Device (a Home of one)
- [Host process boundary](host-process-boundary.md) — one process ↔ one Device ↔ one data directory
