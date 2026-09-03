# Devices

## Sub-features

- Device card grid (`.dev-rows` / `.ops-dev`) with health dots, CPU/MEM; this Device also shows temperature and volume used; polls every 5 s
- **Add a {Device}** → jumps to `Settings → Pairing`
- Device detail: reachability pill, CPU/Memory/GPU stat cards with sparklines, **Facts** sheet, per-Workload table with Start/Stop/Restart, failed-workload banner with inline **Start**

## How to get to it (user POV)

Sidebar **Devices** → route `/devices`. Click a card → `/devices/:hostId`.

## Driving it with Playwright

```sh
bun helpers/shot.mjs --base "$URL" --user admin --pass "$PASS" \
  --route /devices --out "evidence/run-devices/devices.png"
```

For detail, take the self hostId from `GET /api/home/devices/health` (role `"self"`) and shoot `/devices/<hostId>`.

Assertions:

- At least one `.ops-dev` card (this page polls `/api/home/devices/health`; `.triage-home-dev` is Dashboard-only)
- Detail page shows a Facts section listing Agent (from `/api/system/about`); stat cards labeled **CPU**, **Memory** (and **GPU** when present). Disk directory sheet is on this page, not Settings.

## Gotchas

- A member Device that is unreachable still renders its page; agent-backed sections (stats, Create VM, disk directory, workloads) are omitted, not merely disabled. HTTP-error members show an **HTTP error** pill, not Unreachable.
- Cards refresh on a 5 s poll; wait ~6 s if you just mutated state through another tab.
