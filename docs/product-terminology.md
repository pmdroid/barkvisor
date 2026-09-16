# Product terminology

Shared words for BarkVisor in the UI and getting-started docs. The domain glossary is [CONTEXT.md](../CONTEXT.md). This file is the UI and API mapping. Do not invent a third glossary.

A single-device install is a **Home of one**. More Devices join that Home later; they are not a cluster.

## Shared table

| Term | User-facing meaning | Code / API (keep as-is) |
|------|---------------------|-------------------------|
| **Home** | A person’s set of Devices (one or more) | `/api/home/devices` registry + `/api/home/devices/health` + member proxy |
| **Device** | The Mac, PC, or board running this BarkVisor daemon | Inventory JSON keeps `hostId`, `hostname`, and host metrics |
| **Agent** | The daemon role on a Device | `/api/agent/*`, `barkvisor` or `barkvisor-agent` |
| **Workload** | A Virtual Machine or an App on a Device | `VM`, `WorkloadSpec` |
| **Library** | Images and templates you can deploy | Image / template repositories |
| **Node** | **Do not use** in product copy | — |
| **Cluster** | **Do not use** in product copy | — |
| **Datacenter** | **Do not use** in product copy | — |
| **Quorum** | **Do not use** in product copy | — |

`host` is still correct in code, inventory JSON, and OS-level phrasing (host port, host path, host CPU model, Linux host bridge). Map those facts to **Device** whenever the reader is a person using the SPA.

USB **device** still means a peripheral. A BarkVisor **Device** is the computer.

## SPA rules

- No “node”, “cluster”, “datacenter”, or “quorum” in user-visible strings (`frontend/src/**/*.vue` templates).
- Say **Device** (or “this device”) when you mean the machine running the daemon. Do not use **This Device** as a stand-in name; show the Device’s display name.
- Say **Home** when you mean the person’s set of Devices. One Device is already a Home.
- Networks live at **Networks** (`/networks`), not Settings → Network.
- First-run setup is `SetupView` (`/setup`). Do not add a second overlay wizard.
- Join an existing Home with `barkvisor join --code`, or `barkvisor-agent join --code` on an API-only Device. The CLI posts to the console-local `/api/pairing/join` endpoint. The web setup wizard creates a new Home. Pairing offers and phone sign-in QRs live under **Settings → Pairing**. **Settings → Home** sets the Device URL. **Settings → Library** sets the image folder; **Settings → Repositories** manages catalogs.
- The sidebar **Device** picker is **All** (Home union) or one Device. List pages filter to that scope. Create VM still has its own placement picker.

## Related

- [Home and pairing](home-and-pairing.md) — add a Device, join, CLI worker
- [Ollama](ollama.md) — install, pull, Start, library search
- [Create a Workload](create-workload.md) — place a VM from the Home dashboard
- [Changelog](changelog.md)
- [Roadmap](roadmap.md)
- [First launch](getting-started-first-launch.md) — setup on this Device (a Home of one)
- [Host process boundary](host-process-boundary.md) — one process ↔ one Device ↔ one data directory
