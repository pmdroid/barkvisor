# Setup wizard (first run)

## Sub-features

- **Welcome** — intro + **Continue** into create-Home setup. Joining an existing Home is CLI-only: `barkvisor join --code`
- Create path: **Add a passkey** (localhost or https hostname, not a raw IP) → **Image Library** folder pick → **Image Catalog** sync (or Skip) → **All Set!** → **Launch Dashboard**
- Ops-checklist rail tracks 01–05; setup is forced until `/api/setup/status` says `complete`. `/api/setup/complete` rejects until a Library folder is saved.

## How to get to it (user POV)

Open `http://<device>:7777` on an unprovisioned Device — the router redirects everything to `/setup`. It only exists before first-run; a provisioned instance redirects `/setup` to login.

To join an existing Home on a fresh Device, do not use the web wizard — run:

```sh
barkvisor join --code 'barkvisor://pair/v1?…'
```

## Driving it with Playwright

Start an unprovisioned instance, then run the committed flow driver:

```sh
scripts/dev-instance.sh start --name setup-verify --no-provision
bun helpers/setup-flow.mjs --base "$URL" --dir evidence/run-setup
```

`setup-flow.mjs` walks the real user path (welcome → passkey via Chromium virtual authenticator → library folder → catalog skip → launch), screenshots every step into `--dir`, and exits nonzero unless `/api/setup/status` reports `complete:true`. Use `http://localhost`, not `127.0.0.1`.

## Gotchas

- The daemon serves a **bundled** SPA — after changing `frontend/src`, rebuild (`bunx vite build` in `frontend/`) and restart the instance with `BARKVISOR_FRONTEND_DIR=$PWD/frontend/dist` or you will verify stale UI.
- Catalog sync performs a real network fetch; the driver clicks **Skip** to stay hermetic.
- Pairing two Devices for end-to-end proof uses `scripts/dev-instance.sh pair <home> <joiner>` (joiner must be `--no-provision`), not the setup UI.
