# Workloads list & Create App

## Sub-features

- List at `/vms` labeled **Workloads** (not Virtual Machines): health chips, empty state **No workloads yet**
- **Create VM** magazine (existing) plus **Create App** magazine: Gallery → Configure
- Gallery cards from the Home app catalog (Big Bear + LinuxServer). Cards can show Install disabled with `unsupportedReasons`
- Configure: name, Device, FolderPicker paths, env, secrets, ports, PUID/PGID/TZ, optional GPU share, ingress toggle, Advanced extra env/mounts
- Published compose ports bind `0.0.0.0`; Open UI uses the Device LAN IP
- Workload detail `/vms/:id` for `kind: Application` uses compose logs (not guest console)

## How to get to it (user POV)

Sidebar **Workloads** → `/vms`. Login still lands here. **Create App** on the toolbar or empty state.

## Driving it with Playwright

```sh
bun helpers/shot.mjs --base "$URL" --token "$TOKEN" \
  --route /vms --out "evidence/run-apps/workloads.png"
```

Create App magazine (gallery + first-card Configure, no apply):

```sh
bun helpers/create-app-flow.mjs --base "$URL" --token "$TOKEN" \
  --dir "evidence/run-apps"
```

Asserts: **Create App** opens `.mag-frame` / heading Create App, gallery cards render, clicking a card reaches Configure. Closing without Create leaves `GET /api/vms` unchanged.

Application logs on a created app (needs a compose-capable Device):

```sh
bun helpers/shot.mjs --base "$URL" --token "$TOKEN" \
  --route "/vms/$ID" --out "evidence/run-apps/app-detail.png"
```

Prefer the Logs tab / `ComposeLogsPanel` over guest Console.

## Gotchas

- Seeded instances have **zero** workloads. Proofs should use empty state + wizard, not a running guest.
- Catalog sync can be empty until the Home has fetched Big Bear / LinuxServer; the gallery still opens (custom YAML card).
- Applying an app needs `docker compose` on the Device. Headless macOS CI usually does not — do not treat apply failure as a UI bug.
- Do not screenshot Dashboard as proof of this feature.
