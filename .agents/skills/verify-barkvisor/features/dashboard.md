# Dashboard

## Sub-features

- Attention strip: Failed Workloads (**Open**), Unreachable Devices (**Device**), and **Missing** (doctor deps)
- Stacked feed **Needs you / Running / Stopped** (`.section-label`). **Failed** exists in Customize but is off by default
- Home rail of Device cards (`.triage-home-dev`) plus **Workload usage** side panel
- **Customize** drawer ("Customize Home": reorder/hide modules, including Failed and Usage)
- **Create VM** toolbar shortcut → `/vms?create=1` (opens the magazine, then strips the query)

## How to get to it (user POV)

Sign in as admin → sidebar **Dashboard**. Passkey login lands on `/vms`; `/` and unknown routes redirect to `/dashboard`; first-run **Launch Dashboard** lands here. Route `/dashboard`.

## Driving it with Playwright

```sh
bun helpers/shot.mjs --base "$URL" --user admin --pass "$PASS" \
  --route /dashboard --out "evidence/run-dashboard/dashboard.png"
```

Assertions worth making against the page:

- `.ops-ticker` (app chrome on every admin page) matches /running/ and shows Home-wide counts
- `.ops-sub` on this page is Device/workload counts, not the ticker
- `.triage-home-dev` contains at least one Device card
- `.section-label` texts include "Needs you", "Running", "Stopped" (not Failed, unless Customize turned it on)
- Clicking **Customize** opens `.dash-drawer.open` containing "Customize Home"; Failed is listed but off
- **Workload usage** panel is present (empty copy **No usage data yet** when nothing is running)

Cross-check ticker numbers against `GET /api/home/devices/health` totals (same data source). There is no Device vitals rail on Dashboard — CPU/Memory/Temperature/Storage live on Device detail.

## Gotchas

- With no Workloads seeded, feed sections render but cards are sparse — do not read emptiness as breakage.
- The ticker polls live; two screenshots seconds apart can legitimately differ.
- Unreachable Devices appear in incidents without any red error toast elsewhere.
