# Dashboard

## Sub-features

- Attention strip: Failed Workloads (**Open**) and Unreachable Devices (**Device**)
- Feed columns **Needs you / Running / Stopped** (`.section-label`). **Failed** exists in Customize but is off by default
- Home rail of Device cards (`.triage-home-dev`)
- **Customize** drawer ("Customize Home": reorder/hide modules)
- **Create VM** toolbar shortcut → `/vms?create=1` (opens the magazine, then strips the query)

## How to get to it (user POV)

Sign in as admin → sidebar **Dashboard** (admins land here only via explicit nav; login itself lands on `/vms`). Route `/dashboard`.

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
- Clicking **Customize** opens `.dash-drawer.open` containing "Customize Home"

Cross-check ticker numbers against `GET /api/home/devices/health` totals (same data source). There is no vitals rail on Dashboard — CPU/Memory/Temperature/Storage live on Device detail.

## Gotchas

- With no Workloads seeded, feed columns render but cards are sparse — do not read emptiness as breakage.
- The ticker polls live; two screenshots seconds apart can legitimately differ.
- Unreachable Devices appear in incidents without any red error toast elsewhere.
