# Networks

## Sub-features

- **Host interfaces** tab (default) — interface table + edit drawer with multi-address list (DHCP + static aliases), Gateway/DNS, Bridge role, Apply/Revert/Re-check
- **VM networks** tab — NAT / bridged / isolated list + inspect + **Create Network**
- No standalone bridge-setup toolbar — bridge config lives on the owning interface drawer

## How to get to it (user POV)

Sidebar **Networks** → `/networks`. Default tab is **Host interfaces**. Switch to **VM networks** for Workload network CRUD.

## Driving it with Playwright

```sh
bun helpers/networks-interfaces-flow.mjs --base "$URL" --user admin --pass "$PASS" \
  --dir "evidence/run-networks-interfaces"
```

Optional `--check` mocks Apply POST, asserts `addresses[]`, then `POST /api/system/bridges` with `action: "check"`.

Do not click Apply without `--check` on a real uplink.
