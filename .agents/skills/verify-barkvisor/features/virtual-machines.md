# Virtual Machines

## Sub-features

- List with health filter chips (All / Running / Failed / Stopped, each with counts) and table Name · Device · OS · CPU·Mem · Ports · Status
- **Create VM** magazine dialog: Gallery → Configure → Disk (templates, Windows ISO, custom image, optional Coding Agent)
- Workload detail toolbar: Start on boot, Start, Stop split (**Stop** + **ACPI Shutdown** / **Force Stop**), Restart, VNC pop-out window, Delete (stopped/error only)
- Detail tabs: Overview (Session/Hardware/Network/Guest/Disks/Shared folders/USB/GPU passthrough/PCI — no Recent events), Chat (conditional), Console vs Terminal (agent-class workloads say Terminal), VNC, Metrics (running only), Logs. Bare VNC window: `/vms/:id/vnc` (self) or `/devices/:hostId/vms/:id/vnc`

## How to get to it (user POV)

Sidebar **Virtual Machines** → `/vms`; login lands here. Row click or name → `/vms/:id`.

## Driving it with Playwright

```sh
bun helpers/shot.mjs --base "$URL" --user admin --pass "$PASS" \
  --route /vms --out "evidence/run-vms/vms.png"
```

Assertions:

- Filter chips render with counts; clicking a chip filters the table
- Empty state reads "No virtual machines yet" when the instance has none
- **Create VM** opens the magazine frame (`.mag-frame`, no split-rail); closing without creating leaves `GET /api/vms` unchanged

Full magazine walk + template deploy (screenshots + API side effects):

```sh
bun helpers/create-vm-flow.mjs --base "$URL" --user admin --pass "$PASS" \
  --dir "evidence/run-create-vm"
```

Asserts: gallery cards (templates / Windows / custom), no guest password on cloud OS templates, SSH key on configure, disk cards (new / existing / raw), light-mode surface, magazine closes after **Create**, and the Workloads list shows that VM as Downloading, Provisioning, or created.

For a detail page you need an existing workload id from `GET /api/vms` — on a seeded instance there are none unless a guest was booted; prefer asserting list/wizard behavior.

## Gotchas

- Custom/Windows create stays on Configure until an image is pinned. Template deploy can start a catalog download without a ready local image. API 400s show as `.mag-error`, not a toast.
- Metrics tab is absent for stopped workloads; do not assert its presence.
- Toolbar VNC is disabled unless the guest is running. The bare window (`/vms/:id/vnc`) says **VM must be running to use VNC** when stopped — not a generic connection error.
