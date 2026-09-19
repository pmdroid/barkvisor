# Virtual Machines

## Sub-features

- List with health filter chips (All / Running / Failed / Stopped, each with counts) and table Name · Device · **Type** · CPU · Mem · Ports · Status. Sidebar label is **Workloads**
- **Create VM** magazine dialog: Gallery → Configure → Disk (templates, Windows ISO, custom image). **Create App** is a separate magazine — see [workloads.md](workloads.md)
- Coding Agent class is gone (PR #577); do not assert an Agent gallery card
- Workload detail toolbar: **Start when this Device boots**, Start, Stop split (**Stop** + **ACPI Shutdown** / **Force Stop**), Restart, VNC pop-out window, Delete (stopped/error only)
- VM detail tabs: Overview (Hardware/Network/Guest/Disks/Shared folders/USB/GPU passthrough/PCI devices — no Session, no Recent events), Console, VNC, Metrics (running only), Logs. No Chat tab. Application tabs are Overview / Terminal (`docker exec`) / Logs / Environment / Volumes — see [workloads.md](workloads.md). Bare VNC window: `/vms/:id/vnc` (self) or `/devices/:hostId/vms/:id/vnc`

## How to get to it (user POV)

Sidebar **Workloads** → `/vms`; login lands here. Row click or name → `/vms/:id`.

## Driving it with Playwright

```sh
bun helpers/shot.mjs --base "$URL" --user admin --pass "$PASS" \
  --route /vms --wait-ms 3000 --out "evidence/run-vms/vms.png"
```

Assertions:

- Filter chips render with counts; clicking a chip filters the table
- Empty state reads **No workloads yet** once Home inventory finishes loading. First paint can show Type table chrome with zero rows — wait a few seconds (`shot.mjs --wait-ms 3000`) before asserting the empty copy
- **Create VM** opens the magazine frame (`.mag-frame`, no split-rail); closing without creating leaves `GET /api/vms` unchanged

Full magazine walk + template deploy (screenshots + API side effects):

```sh
bun helpers/create-vm-flow.mjs --base "$URL" --user admin --pass "$PASS" \
  --dir "evidence/run-create-vm"
```

Asserts: gallery cards (templates / Windows / custom), no guest password on cloud OS templates, SSH key on configure, disk cards (new / existing / raw) when **Next** is enabled, light-mode surface. On a seeded instance with no local image, **Next** stays disabled on Configure — that is expected, not a failure. Opening the Windows card can start a **VirtIO Windows Drivers** download into Images; do not treat that as the Debian template deploying.

For a detail page you need an existing workload id from `GET /api/vms` — on a seeded instance there are none unless a guest was booted; prefer asserting list/wizard behavior.

## Gotchas

- Custom/Windows create stays on Configure until an image is pinned. Template deploy can start a catalog download without a ready local image. API 400s show as `.mag-error`, not a toast.
- Metrics tab is absent for stopped workloads; do not assert its presence.
- Toolbar VNC is disabled unless the guest is running. The bare window (`/vms/:id/vnc`) says **VM must be running to use VNC** when stopped — not a generic connection error.
