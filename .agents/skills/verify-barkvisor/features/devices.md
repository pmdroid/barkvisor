# Devices

## Sub-features

- Device card grid with health dots, temperature, storage; polls every 5 s
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

- At least one device card renders (`.triage-home-dev` equivalent grid on this page polls `/api/home/devices/health`)
- Detail page shows a Facts section listing Agent version; stat cards labeled **CPU**, **Memory**

## Gotchas

- A member Device that is unreachable still renders its page; controls needing its agent are disabled — not broken.
- Cards refresh on a 5 s poll; wait ~6 s if you just mutated state through another tab.
