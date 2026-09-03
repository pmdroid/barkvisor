---
name: verify-barkvisor
description: Drive the real BarkVisor web UI (Swift daemon + Vue SPA) end to end on a throwaway instance — launch via scripts/dev-instance.sh, prove features with Playwright screenshots plus API side-effect checks. Use for verifying any user-facing feature, doc screenshot runs, or pre-PR UI checks in this repo.
---

# Verify BarkVisor

Drive the real BarkVisor web console — a headless Swift daemon serving a Vue 3 SPA on one port. Every run happens on a **throwaway instance** (`scripts/dev-instance.sh`): fresh `BARKVISOR_DATA_DIR`, random free ports, headless admin provisioning, optional demo seed. Instances are fully isolated (port + data dir), so parallel runs are safe with distinct `--name`s. Never drive a daemon on port 7777 — that is the user's real instance; the doctor refuses it.

## Launch

```sh
cd /Users/pascal/work/barkvisor
.agents/skills/verify-barkvisor/helpers/up.sh --seed
```

`up.sh` calls `scripts/dev-instance.sh start --name verify-<hex> --seed` (or `--name TAG`), waits for `/api/health` + headless setup, and prints the instance meta as **one JSON line on stdout** (logs go to stderr). The same JSON is saved to `.agents/skills/verify-barkvisor/current/meta.json` (last `up.sh` wins — pass `--name` and keep the JSON line when running two instances). Ready means: that line exists and `doctor.sh` passes.

```json
{"name":"verify","url":"http://127.0.0.1:50190","port":50190,"agentPort":50191,"pid":1234,"dataDir":"/var/folders/…/barkvisor-dev-verify.XXXX","logFile":"…/server.log","adminUser":"admin","adminPass":"dev-instance-pass","seeded":true}
```

Teardown is `helpers/down.sh` (see Cleanup).

Two setup-related variants:

- `up.sh --no-provision` (or `scripts/dev-instance.sh start --no-provision`) leaves setup incomplete so the **setup wizard** can be driven — see [features/setup.md](features/setup.md) and `helpers/setup-flow.mjs`.
- `scripts/dev-instance.sh pair <home-name> <joiner-name>` pairs two running instances (joiner must be `--no-provision`): issues the offer, joins, completes the joiner's setup, restarts it, and asserts the Home sees it reachable. This is the pairing proof.

## Doctor

Run first whenever anything looks off:

```sh
.agents/skills/verify-barkvisor/helpers/doctor.sh "$(jq -r .url .agents/skills/verify-barkvisor/current/meta.json)" admin dev-instance-pass
```

Checks, in order: not port 7777 (refuses without `BARKVISOR_ALLOW_7777=1`) → `/api/health` answers → `/api/setup/status` says `complete:true` → login returns a JWT → prints `/api/system/about` (version/platform) so you know what build you are driving.

## Drive

Harness is Playwright over Chromium from this skill's own `node_modules/playwright-core` (browsers resolve from `~/Library/Caches/ms-playwright`). Run helpers with `bun` or `node`.

Plain page screenshot. `POST /api/auth/login` is rate-limited (default 10 / 5 min) — log in once, then pass `--token`:

```sh
TOKEN=$(curl -sf -X POST "$URL/api/auth/login" -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"dev-instance-pass"}' | jq -r .token)
bun .agents/skills/verify-barkvisor/helpers/shot.mjs \
  --base "$URL" --token "$TOKEN" \
  --route "/settings?tab=audit" \
  --out ".agents/skills/verify-barkvisor/evidence/run-$(date +%s)/settings-audit.png"
```

Feature flow with built-in assertions — create an API key through the modal, capture the show-once secret, verify it server-side:

```sh
bun .agents/skills/verify-barkvisor/helpers/api-key-flow.mjs \
  --base "$URL" --user admin --pass dev-instance-pass \
  --key-name "verify-proof" --dir ".agents/skills/verify-barkvisor/evidence/run-apikeys"
# stdout JSON: {"ok":true,"secretPrefix":"bv_…","secretShown":true,"screenshot":"…"}
```

Stable handles (prefer these, never coordinates):

| Handle | Where |
|---|---|
| Login | **Sign in with passkey** on `.login-card` (no username/password). Helpers inject a JWT from `POST /api/auth/login` on headless instances. |
| Sidebar nav | `.sidebar-nav` links by label text: Dashboard, Devices, Virtual Machines, Ollama, Images, Disks, Networks, Logs, Settings |
| Settings tabs | deep links `/settings?tab=home\|pairing\|library\|repositories\|apikeys\|sshkeys\|passkeys\|audit\|updates` (`?tab=disks` redirects to Devices) |
| Ticker | `.ops-ticker` (running/failed/stopped/unreachable counts) |
| Toolbar buttons | exact text: **Create VM**, **Customize**, **Create Disk**, **Create Network**, **Live Tail**, **Diagnostics** |
| Create Key modal | button **Create Key** → input placeholder `e.g. terraform, ci-pipeline` → **Create** → heading **API Key Created** |
| Create VM | button **Create VM** → `.mag-frame` gallery (`.mag-card` / `.mag-custom`) → Configure → Disk → **Create** |

Networks Host interfaces (multi-address Device address):

```sh
bun .agents/skills/verify-barkvisor/helpers/networks-interfaces-flow.mjs \
  --base "$URL" --user admin --pass dev-instance-pass \
  --dir ".agents/skills/verify-barkvisor/evidence/run-networks-interfaces"
# optional: --check  (mock Apply POST + action=check, no host mutation)
```

Magazine Create VM (gallery kinds, disk cards, light mode, template deploy):

```sh
bun .agents/skills/verify-barkvisor/helpers/create-vm-flow.mjs \
  --base "$URL" --user admin --pass dev-instance-pass \
  --dir ".agents/skills/verify-barkvisor/evidence/run-create-vm"
```

## Evidence

Capture into `.agents/skills/verify-barkvisor/evidence/<run-name>/` (gitignored, survives teardown):

1. **Action proof** — screenshot mid-flow (e.g. the show-once secret screen), not just the final page.
2. **State proof** — resulting state via the same authenticated API the UI uses:
   ```sh
   curl -sf -H "Authorization: Bearer $TOKEN" "$URL/api/auth/keys" | jq '.[].name'
   ```
3. **Side effects** — rows/state in the instance SQLite when relevant:
   ```sh
   sqlite3 "$(jq -r .dataDir current/meta.json)/db.sqlite" "SELECT name FROM api_keys;"
   ```
4. For anything named like a dry-run or preview, observe what it actually skipped (files written, processes spawned) instead of trusting the label.

Proof standard: exercise the real user path (UI form/modal clicks against the running daemon); never internal setters, test-only endpoints, or direct DB writes as the *action* — DB reads are for verification only. Show-once secrets captured from a throwaway instance are fine to keep in evidence.

## Cleanup

```sh
.agents/skills/verify-barkvisor/helpers/down.sh            # stops 'verify' (or --name X)
```

Reads `current/meta.json`, kills exactly that pid (SIGTERM → SIGKILL after ~5 s), removes the registry entry and the auto temp data dir, deletes `current/`. Never kill by process name (`pkill BarkVisorApp` would take out the user's real daemon). Run cleanup after every attempt, failed included. Evidence under `evidence/` always survives.

## Helpers

| Script | Invocation | Purpose |
|---|---|---|
| `up.sh` | `helpers/up.sh [--seed] [--name TAG] [--data-dir DIR] [--keep]` | launch instance, save meta to `current/meta.json` |
| `doctor.sh` | `helpers/doctor.sh URL [USER] [PASS]` | read-only "worth driving?" check |
| `shot.mjs` | `helpers/shot.mjs --base URL [--token T \| --user U --pass P] --route R --out F.png [--raw] [--wait-ms N] [--scrub /from/to]…` | login (or token inject) + navigate + full-page screenshot, with DOM redaction |
| `api-key-flow.mjs` | `helpers/api-key-flow.mjs --base URL [--token T \| --user U --pass P] --key-name NAME --dir EVIDENCE_DIR` | create-key flow with assertions + evidence |
| `create-vm-flow.mjs` | `helpers/create-vm-flow.mjs --base URL [--token T \| --user U --pass P] --dir EVIDENCE_DIR` | magazine Create VM flows + template deploy |
| `networks-interfaces-flow.mjs` | `helpers/networks-interfaces-flow.mjs --base URL [--token T \| --user U --pass P] --dir EVIDENCE_DIR [--check]` | Host interfaces tab: drawer, multi-address editor, optional mocked Apply + real check |
| `setup-flow.mjs` | `helpers/setup-flow.mjs --base URL --dir EVIDENCE_DIR` | drive the first-run wizard (`--no-provision` instance; use `http://localhost`) |
| `down.sh` | `helpers/down.sh [--name TAG]` | stop instance, clean temp state |
