# Workloads list & Create App

## Sub-features

- List at `/vms` labeled **Workloads** (not Virtual Machines): health chips, empty state **No workloads yet**
- **Create VM** magazine (existing) plus **Create App** magazine: Gallery → Configure
- Gallery: **Search apps** + category chips, cards from the Home app catalog (Big Bear + LinuxServer). `unsupportedReasons` render on the card; the card stays clickable. **Apply** is what blocks
- Configure: name, **Open through BarkVisor** (prefix ingress, default on), Device, ports, Extra binds, Advanced (UMASK / extra env / published-port override). PUID/PGID/TZ are catalog env fields, not dedicated widgets
- Published compose ports bind `0.0.0.0`; Open UI uses the Device LAN IP, or `/go/<id>/` when prefix ingress is on
- Workload detail `/vms/:id` for `kind: Application`: Overview, Terminal (admin `docker exec`), Logs (`ComposeLogsPanel`), Environment, Volumes. Not the guest console

## How to get to it (user POV)

Sidebar **Workloads** → `/vms`. Login still lands here. **Create App** on the toolbar or empty state.

## Driving it with Playwright

```sh
bun helpers/shot.mjs --base "$URL" --token "$TOKEN" \
  --route /vms --wait-ms 3000 --out "evidence/run-apps/workloads.png"
```

Create App magazine (gallery + first-card Configure, no apply):

```sh
bun helpers/create-app-flow.mjs --base "$URL" --token "$TOKEN" \
  --dir "evidence/run-apps"
```

Asserts: **Create App** opens `.mag-frame` / heading Create App, gallery cards render (search + category chips), clicking a card reaches Configure (**Open through BarkVisor**, Extra binds, Advanced). The helper does not close the magazine and does not diff `GET /api/vms`.

Application detail on a created app (needs a compose-capable Device):

```sh
bun helpers/shot.mjs --base "$URL" --token "$TOKEN" \
  --route "/vms/$ID" --out "evidence/run-apps/app-detail.png"
```

Prefer Overview / Logs (`ComposeLogsPanel`) over guest Console. Terminal is admin `docker exec` on this Device.

## Gotchas

- Seeded instances have **zero** workloads. Proofs should use empty state + wizard, not a running guest.
- Catalog sync can be empty until the Home has fetched Big Bear / LinuxServer; the gallery still opens (custom YAML card).
- Applying an app needs `docker compose` on the Device. Headless macOS CI usually does not — do not treat apply failure as a UI bug.
- Do not screenshot Dashboard as proof of this feature.
