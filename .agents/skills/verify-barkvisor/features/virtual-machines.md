# Virtual Machines

## Sub-features

- List with health filter chips (All / Running / Failed / Stopped, each with counts) and table Name · Device · OS · CPU·Mem · Ports · Status
- **Create VM** split-rail wizard: Basics → Image → Place → Hardware → Storage → Network → Summary
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
- **Create VM** opens the wizard drawer (left rail shows step names); closing without creating leaves `GET /api/vms` unchanged

For a detail page you need an existing workload id from `GET /api/vms` — on a seeded instance there are none unless a guest was booted; prefer asserting list/wizard behavior.

## Gotchas

- Creating a real Workload requires a Library image; without one the create submit is rejected — that rejection toast is itself verifiable behavior.
- Metrics tab is absent for stopped workloads; do not assert its presence.
- The VNC button opens a separate chrome-less route (`/vms/:id/vnc`) — screenshotting it without a running guest shows a connection error screen.
