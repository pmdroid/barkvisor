---
name: verify-barkvisor
description: Drive the real BarkVisor web UI (Vue SPA served by the Swift daemon) on an isolated local instance with headless Chromium, and capture screenshots + ARIA snapshots as proof. Use when a change needs to be shown working in the actual UI — first-run setup, login, dashboard, workloads, settings/pairing — rather than only in unit or Cypress tests.
---

# Verify BarkVisor

BarkVisor is a headless QEMU daemon. The primary user surface is the web UI at `http://127.0.0.1:<port>` (SPA bundled as `frontend/dist`, served by `BarkVisorApp`). This skill launches an isolated daemon, drives that SPA the way a user would, and leaves proof artifacts behind.

Out of scope here: the native `Apps/BarkVisorConsole` SwiftUI app, the Astro `website/`, guest-boot / QEMU lifecycle, and Cypress (`frontend/cypress`, Vite `:5173` against a shared `:7777`). Those are different surfaces or a shared-instance harness — never point this skill at the operator's own `:7777`.

Read [`features/README.md`](./features/README.md) before driving. A proof that only drives one convenient entry point is incomplete when the map lists others.

## Launch

Always isolate. Default HTTP port is **17777** (agent plane 17778) so a developer instance on 7777 is left alone.

```bash
cd "$(git rev-parse --show-toplevel)"
export VERIFY_RUN=my-check
bun .agents/skills/verify-barkvisor/drive.ts launch
```

`launch` builds `BarkVisorApp` if the binary is missing, builds `frontend/dist` if `index.html` is missing, then starts:

```
BARKVISOR_DATA_DIR=~/.cache/barkvisor/verify-barkvisor/runs/$VERIFY_RUN/data
BARKVISOR_PORT=17777          # or 18000+(hash) when VERIFY_RUN is not "default"; override with --port
BARKVISOR_AGENT_PORT=<port+1>
BARKVISOR_FRONTEND_DIR=<repo>/frontend/dist
```

Ready when `GET http://127.0.0.1:<port>/api/health` returns 200. First-run data dirs have no admin: `/` redirects to `/setup`.

It records the pid in `~/.cache/barkvisor/verify-barkvisor/runs/$VERIFY_RUN/instance.json`. Re-running `launch` for the same `VERIFY_RUN` reuses that pid if it still owns the port. It never attaches to a process it did not start.

`--port N` / `VERIFY_RUN` pick a different listen port when two proofs run at once. If the chosen port is already owned by someone else, launch exits non-zero rather than driving it.

Seeded admin after `setup`: username `admin`, password `verify-admin-10` (10+ chars, required).

## Doctor

Read-only. Starts nothing, logs nobody in. Run this first whenever anything looks off.

```bash
bun .agents/skills/verify-barkvisor/drive.ts doctor
```

Requires `instance.json` from this run's `launch`. Checks: pid alive, listen port owned by that pid, `/api/health` `status=ok`, SPA `GET /` serves the UI, data dir is under this run's cache, `/api/setup/status` answers. Exits non-zero when any check fails.

- `alive: false` — process died; read `runs/$VERIFY_RUN/daemon.log`, then `cleanup` and `launch`.
- `portOwnedByUs: false` — another process took the port. Do not kill it. Change `--port` / `VERIFY_RUN`.
- `spa: false` — `frontend/dist` missing or `BARKVISOR_FRONTEND_DIR` wrong.
- `setupComplete: false` — expected on a fresh data dir. Run `setup` before login or authenticated pages.

Never doctor (or drive) `http://localhost:7777` unless `instance.json` says that port and pid are ours.

## Drive

Chromium via Playwright. Prefer `getByRole` and visible names. Login labels are not `for=`-wired: on `/login` use `input[type="text"]` / `input[type="password"]`. Setup admin uses placeholders `admin`, `Minimum 10 characters`, `Confirm password`.

**First-run setup** (fresh data dir; this is the proof the generator itself ran):

```bash
bun .agents/skills/verify-barkvisor/drive.ts setup
```

Clicks Welcome → **Set up this Device** → admin → catalog **Skip** → **Launch Dashboard**. Pass `--sync-catalog` to click **Sync Catalog** instead (hits the network). If a **Network Bridge** step appears (`managedBridgeDaemon` is currently always false, but handle it), click **Skip (use NAT)**.

**Sign in** (setup already complete; no storage state):

```bash
bun .agents/skills/verify-barkvisor/drive.ts login
```

Fills the real `/login` form. Lands on `/vms` (`h1` Virtual Machines) with a JWT in `localStorage`.

**One page, one capture:**

```bash
bun .agents/skills/verify-barkvisor/drive.ts open /dashboard --label dashboard
```

Uses saved Playwright `storageState` when present; otherwise `POST /api/auth/login` only to inject the token so you can screenshot a later page. That injection is not proof of login — `login` / `setup` are.

**A real interaction** — import the driver:

```ts
import { withBarkVisor } from "<repo>/.agents/skills/verify-barkvisor/drive.ts"

await withBarkVisor(async (s) => {
  await s.page.goto("/vms")
  await s.page.getByRole("button", { name: "Create VM" }).click()
  await s.page.getByRole("heading", { name: "Create Virtual Machine" }).waitFor()
  await s.capture("wizard-open")
  await s.page.getByRole("button", { name: "Cancel" }).click()
})
```

```bash
VERIFY_RUN=my-check bun /tmp/verify-wizard.ts
```

`withBarkVisor` gives `page`, `context`, `browser`, `instance`, `evidenceDir`, `capture(label)`. `--headed` on any drive command shows the window.

**Stable handles (from this repo):**

| What | Handle |
| --- | --- |
| Setup welcome | heading `Welcome to BarkVisor`; buttons `Set up this Device`, `Join an existing Home` |
| Setup admin | heading `Create Admin Account`; button `Continue` |
| Setup catalog | heading `Image Catalog`; buttons `Sync Catalog`, `Skip` |
| Setup done | heading `All Set!`; button `Launch Dashboard` |
| Login | heading `BarkVisor`; button `Sign In`; subtitle `Sign in to manage your virtual machines` |
| Logout | `button[title="Logout"]` |
| Sidebar | `a[href="/dashboard"]` … `/devices` `/vms` `/images` `/disks` `/networks` `/registry` `/logs` `/settings` with names Dashboard, Devices, Virtual Machines, Images, Disks, Networks, Repositories, Logs, Settings |
| Dashboard | heading `Dashboard`; button `Create VM`; widgets Devices, Health, CPU, Memory, Storage, Temperature, Recent Machines |
| Workloads | heading `Virtual Machines`; buttons `Create VM` / `Create your first VM`; empty `No virtual machines yet`; wizard heading `Create Virtual Machine`, steps Basics → Image → Place → Hardware → …, buttons `Next` / `Cancel` |
| Images | heading `Images`; buttons `Upload Image`, `Download Image`; empty `No images yet` |
| Settings tabs | Home, Pairing, Library, API Keys, SSH Keys, Audit Log |
| Pairing | button `Add a Device`; copy `Copy pairing code`; `Revoke`; payload starts with `barkvisor://pair/v1` |

Setup `POST /api/setup/*` is console-local only (`127.0.0.1` / `::1`). The harness uses `http://127.0.0.1`, never a LAN IP.

## Evidence

`~/.cache/barkvisor/verify-barkvisor/evidence/$VERIFY_RUN/` — outside the repo and outside the run's data dir. Cleanup deletes `runs/$VERIFY_RUN/` only.

Each `capture(label)` writes:

- `<label>.png` — 1280×800, animations frozen
- `<label>.aria.txt` — ARIA snapshot
- `<label>.json` — URL, title, `hasToken`, timestamp

Proof standards:

- Drive the SPA a user sees. Do not call `/api/setup/admin` or `/api/setup/complete` to claim setup works. Do not `localStorage.setItem('token')` to claim login works.
- Capture the action and the result (`setup-welcome` … `setup-dashboard`, not only the last screen).
- Side effects: after setup, `GET /api/setup/status` has `complete: true`, `localStorage.token` is set, `dataDir/db.sqlite` exists. After pairing, the offer string is on screen and `GET /api/pairing/codes` (authenticated) matches. After skip-catalog, `/images` still shows `No images yet` unless something else synced.
- Do not mock QEMU, catalogs, or auth. Skip catalog is a real user control; prove what it skipped by observing the images empty state, not by trusting the button name.
- Guest boot is not in this map. Opening the create-VM wizard is; finishing a guest needs a ready Library image and is `verified-unreachable` without one.

## Cleanup

```bash
bun .agents/skills/verify-barkvisor/drive.ts cleanup
```

Sends SIGTERM (then SIGKILL) to **the pid in `instance.json`**, then deletes `runs/$VERIFY_RUN/` (data dir, logs, pid, storage state). It does not kill by process name. It does not touch `evidence/$VERIFY_RUN/`. Confirm those files still exist before reporting.

If a drive mutated the instance (pairing offer, API key), undo through the UI when you will keep the instance; a full cleanup of an isolated data dir is enough when the run is done.

## Helpers

One script:

```bash
bun .agents/skills/verify-barkvisor/drive.ts launch   [--run ID] [--port N]
bun .agents/skills/verify-barkvisor/drive.ts doctor   [--run ID]
bun .agents/skills/verify-barkvisor/drive.ts setup    [--run ID] [--sync-catalog] [--headed]
bun .agents/skills/verify-barkvisor/drive.ts login    [--run ID] [--headed]
bun .agents/skills/verify-barkvisor/drive.ts open /path [--label L] [--run ID] [--headed]
bun .agents/skills/verify-barkvisor/drive.ts cleanup  [--run ID]
```

`$VERIFY_RUN` and `--run` set the cache slice; the flag wins. `withBarkVisor` is exported from `drive.ts`. First Chromium use runs `bun install` in this skill dir and `playwright install chromium` if needed.
