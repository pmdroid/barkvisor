# Dashboard

## Sub-features

- Incident rows for Failed Workloads / Unreachable Devices with **Open** buttons
- Feed columns **Needs you / Running / Failed / Stopped** (`.section-label`)
- Vitals rail: CPU, Memory, Temperature, Storage meters
- **Customize** drawer ("Customize Home": reorder/hide modules)
- **Create VM** toolbar shortcut → navigates to `/vms`

## How to get to it (user POV)

Sign in as admin → sidebar **Dashboard** (admins land here only via explicit nav; login itself lands on `/vms`). Route `/dashboard`.

## Driving it with Playwright

```sh
bun helpers/shot.mjs --base "$URL" --user admin --pass "$PASS" \
  --route /dashboard --out "evidence/run-dashboard/dashboard.png"
```

Assertions worth making against the page:

- `.ops-ticker` text matches /running/ and shows the Home-wide counts
- `.triage-home-dev` contains at least one Device card
- `.section-label` texts include "Needs you", "Running", "Stopped"
- Clicking **Customize** opens `.dash-drawer.open` containing "Customize Home"

Cross-check ticker numbers against `GET /api/home/devices/health` totals (same data source).

## Gotchas

- With no Workloads seeded, feed columns render but cards are sparse — do not read emptiness as breakage.
- The ticker polls live; two screenshots seconds apart can legitimately differ.
- Unreachable Devices appear in incidents without any red error toast elsewhere.
