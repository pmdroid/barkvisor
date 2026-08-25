# First-run setup

First-run setup lets a user turn a new Device into a Home: create the admin account, optionally sync the image catalog, and land signed in on the dashboard.

## Sub-features

- `setup-welcome` offers create-Home versus join-Home on a Device with no admin.
- `setup-create` walks Welcome → admin → catalog → All Set.
- `setup-admin` persists username and password (10+ characters, confirmed).
- `setup-catalog-skip` continues without downloading catalog entries.
- `setup-catalog-sync` pulls images and templates, then continues.
- `setup-bridge-skip` skips Network Bridge when that step is shown.
- `setup-launch` signs the user in and opens the dashboard.
- `setup-join` is a second welcome path (paste `barkvisor://pair/v1?…`); not covered by the default recipe.

## How to get to it (user POV)

- Open `http://127.0.0.1:<port>/` or `/setup` on a Device that has never finished setup.
- After setup, `/setup` redirects to `/login`.

## Driving it with drive.ts

Preconditions:

- Isolated daemon launched for this `VERIFY_RUN`; `doctor` is green.
- `/api/setup/status` has `complete: false`.
- Drive `http://127.0.0.1`, not a LAN address.

- **Welcome.** Open setup. Run `bun .agents/skills/verify-barkvisor/drive.ts setup` (or `page.goto("/setup")`). Heading `Welcome to BarkVisor` is visible with buttons `Set up this Device` and `Join an existing Home`. Capture `setup-welcome`.
- **Create Home.** Choose `Set up this Device`. Heading `Create Admin Account` appears. Username placeholder `admin` is prefilled.
- **Admin.** Fill username `admin`, password `verify-admin-10`, confirm the same. Choose `Continue`. Capture `setup-admin` before Continue.
- **Bridge (only if shown).** If heading `Network Bridge` appears, choose `Skip (use NAT)`. Current builds omit this step (`managedBridgeDaemon` is false).
- **Skip catalog.** On heading `Image Catalog`, choose `Skip`. Capture `setup-catalog` before Skip.
- **Finish.** Heading `All Set!` is visible. Choose `Launch Dashboard`. Heading `Dashboard` appears. `localStorage.token` is set. `GET /api/setup/status` returns `complete: true`. Capture `setup-ready` and `setup-dashboard`.
- **Sync catalog (other entry).** Re-run on a fresh data dir with `drive.ts setup --sync-catalog`. Choose `Sync Catalog`, wait for `Continue`, then finish. Images list is no longer the empty state after a successful sync.
- **Join (other entry).** From welcome, choose `Join an existing Home`. Requires a live offer from another Device's Settings → Pairing → `Add a Device`. Unreachable on a single isolated instance.

## Gotchas

- Setup APIs reject non-loopback clients with 403. `localhost` is fine if it is loopback; the harness uses `127.0.0.1`.
- Password must be at least 10 characters. Mismatch shows `Passwords do not match` and stays on admin.
- `complete: true` after Continue on admin is not enough: the user is not finished until `Launch Dashboard`.
- Skipping the catalog leaves Library empty. That is the skip; do not call a later images page with rows a pass of `setup-catalog-skip`.
- A leftover default data dir (`~/Library/Application Support/BarkVisor`) is not this instance. Only `BARKVISOR_DATA_DIR` from `instance.json` counts.
