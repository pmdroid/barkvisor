# Setup wizard (first run)

## Sub-features

- **Welcome** — choose **Set up this {Device}** (create a Home) or **Join an existing {Home}**
- Create path: **Create Admin Account** (username + password ≥10 chars + confirm) → Network Bridge step (macOS capability-gated; slated for removal — skip with NAT) → **Image Catalog** sync (or Skip) → **All Set!** → **Launch Dashboard**
- Join path: paste the `barkvisor://pair/v1?…` offer → **Joined your {Home}** → Launch Dashboard
- Step dots track progress; setup is forced until `/api/setup/status` says `complete`

## How to get to it (user POV)

Open `http://<device>:7777` on an unprovisioned Device — the router redirects everything to `/setup`. It only exists before first-run; a provisioned instance redirects `/setup` to login.

## Driving it with Playwright

Start an unprovisioned instance, then run the committed flow driver:

```sh
scripts/dev-instance.sh start --name setup-verify --no-provision
bun helpers/setup-flow.mjs --base "$URL" --dir evidence/run-setup
```

`setup-flow.mjs` walks the real user path (welcome → admin form → bridge skip when present → catalog skip → launch), screenshots every step into `--dir`, and exits nonzero unless `/api/setup/status` reports `complete:true`. For the join path, pass `--join-payload "<barkvisor://pair/v1?…>"` (get one via `dev-instance.sh pair` or `POST /api/pairing/codes` on a Home instance).

## Gotchas

- The daemon serves a **bundled** SPA — after changing `frontend/src`, rebuild (`bunx vite build` in `frontend/`) and restart the instance with `BARKVISOR_FRONTEND_DIR=$PWD/frontend/dist` or you will verify stale UI.
- The bridge step appears only when the `managedBridgeDaemon` capability is present (macOS); the driver skips it conditionally so it keeps working when the step is removed.
- Catalog sync performs a real network fetch; the driver clicks **Skip** to stay hermetic.
- Login rate limiting applies to the admin form; prefer one driver run per instance.
