# Virtual Machines

## Sub-features

- List with health filter chips (All / Running / Failed / Stopped, each with counts) and table Name · Device · OS · CPU·Mem · Ports · Status
- **Create VM** magazine dialog: Gallery → Configure → Disk (templates, Windows ISO, custom image, optional Coding Agent)
- Workload detail toolbar: Start, Stop group (**Shutdown** | **Force Stop**), Restart, VNC pop-out window, Delete
- Detail tabs: Overview (Session/Hardware/Network/Guest/Disks/Shared folders/USB/GPU/PCI/Recent events), Chat (conditional), Console vs Terminal label (agent-class workloads say Terminal), VNC, Metrics (running only), Logs

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

- Creating a real Workload requires a Library image; without one the create submit is rejected — that rejection toast is itself verifiable behavior.
- Metrics tab is absent for stopped workloads; do not assert its presence.
- The VNC button opens a separate chrome-less route (`/vms/:id/vnc`) — screenshotting it without a running guest shows a connection error screen.
