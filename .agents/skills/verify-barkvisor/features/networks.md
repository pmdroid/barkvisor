# Networks

## Sub-features

- List + inspect pane for NAT, bridged, and isolated networks
- **Create Network** modal
- **Bridge setup** — Mac and Linux show the same Device address (DHCP/static) controls and Apply/Revert. No Setup/Start/Stop.

## How to get to it (user POV)

Sidebar **Networks** → `/networks`. Toolbar **Bridge setup** opens the modal.

## Driving it with Playwright

```sh
bun helpers/bridge-setup-flow.mjs --base "$URL" --user admin --pass "$PASS" \
  --dir "evidence/run-bridge-setup"
```

Opens **Networks → Bridge setup**, asserts Device address DHCP/static plus Apply/Revert (and no Setup/Start/Stop), and writes `bridge-setup.png`.

Optional dry API check (does not apply a host uplink). `--check` mocks the Apply POST so the host is not mutated, asserts the body includes `addressing`, then `POST /api/system/bridges` with `action: "check"`:

```sh
bun helpers/bridge-setup-flow.mjs --base "$URL" --user admin --pass "$PASS" \
  --dir "evidence/run-bridge-setup" --check
```

Do not click Apply without `--check` on a real uplink.

## Gotchas

- Guest static IP is a Workload setting. Device address on this sheet is the host.
- `--check` is the only helper path that talks to apply. It must not persist `br0` or change a Mac LAN address.
