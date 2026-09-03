# Networks

## Sub-features

- **Host interfaces** tab (default) — NIC table + edit drawer. DHCP lease is always on (read-only). Extra static CIDRs via **+ Add address**. Gateway/DNS. **Apply** (preview/dry-run, then confirm). No drawer **Revert** / **Re-check**. Owned Bridges can **Delete**. Toolbar **Create → Bridge** (no standalone Bridge setup button)
- **VM networks** tab — NAT / bridged / isolated Workload networks + **Create Network**
- Apply mutates the host — on a throwaway, do not confirm Apply. Use `POST /api/system/bridges` `{action:"check"}` for a non-mutating plan, or `networks-interfaces-flow.mjs` without clicking through the confirm dialog

## How to get to it (user POV)

Sidebar **Networks** → `/networks`. Default tab is **Host interfaces**. Switch to **VM networks** for Workload network CRUD.

## Driving it with Playwright

```sh
bun helpers/networks-interfaces-flow.mjs --base "$URL" --user admin --pass "$PASS" \
  --dir "evidence/run-networks-interfaces"
```

Optional `--check` mocks the Apply POST (`/api/system/interfaces` or `/api/system/bridges`), asserts `addresses[]`, then `POST /api/system/bridges` with `action: "check"` (does not persist).

Do not confirm Apply on a real uplink. The only user-facing Revert is the 60s **Keep network changes** window after a real Apply.
