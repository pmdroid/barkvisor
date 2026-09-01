---
title: "Networks"
description: "Host interfaces, VM networks, and multi-address Device addressing."
---
**Networks** owns connectivity for the Home: host NIC addressing on this Device, plus VM network records (NAT, bridged, isolated). Networks live here, not in Settings.

![Networks — Host interfaces tab](/docs-img/networks.png)

Words: **Home**, **Device**, **Workload**. Host addressing is this Device — configure it on **Networks → Host interfaces**. Workload networks are logical records on the **VM networks** tab.

## Tabs

**Networks** opens with two tabs:

| Tab | Purpose |
|-----|---------|
| **Host interfaces** (default) | Live NICs on this Device — addresses, bridge role, Apply/Revert |
| **VM networks** | NAT / bridged / isolated records Workloads attach to |

There is no standalone bridge-setup toolbar or modal. Bridge configuration and Device address live on the owning interface row.

## Host interfaces tab

The table lists each NIC on the Device:

| Column | Meaning |
|--------|---------|
| Interface | OS name (`en0`, `eth0`, `br0`, …) |
| Role | uplink, bridge, external, … |
| Addresses (live) | DHCP + static aliases read from the host |
| Bridge | bridge membership / readiness |
| Route | default route when relevant |

Select a row to open the **edit drawer** below the table.

### Address list

The drawer shows DHCP primary and static aliases together:

- **DHCP (primary)** — toggle for the main address from your router
- **static** — primary static CIDR when DHCP is off
- **alias** — extra CIDR on the same NIC (multi-homed or service IPs)
- **on host** chip — BarkVisor wrote this config and can revert it

**Gateway** and **DNS** apply to the interface as a whole (not per alias). **Bridge role** is read-only here — uplink vs `br0` vs external.

Actions:

- **Apply** — persist the address plan on the host
- **Revert** — remove BarkVisor-tagged config for this interface
- **Re-check** — refresh live addresses from the OS

Copyable CLI steps stay under **Advanced CLI** on the same drawer.

### Multi-address examples

**DHCP primary + static alias** (common for a service IP alongside router DHCP):

```json
{
  "interface": "eth0",
  "addresses": [
    { "kind": "dhcp" },
    { "kind": "alias", "cidr": "10.0.0.2/24" }
  ]
}
```

**Static-only** (no DHCP):

```json
{
  "interface": "br0",
  "addresses": [
    { "kind": "static", "cidr": "192.168.1.10/24" }
  ],
  "gateway": "192.168.1.1",
  "dns": ["1.1.1.1"]
}
```

Use **Apply** in the drawer, or `POST /api/system/bridges` with `"action": "check"` to preview planned diffs without changing the host.

### Mac vs Linux — gateway and DNS

Both platforms use the same drawer. Apply paths differ:

| | Linux | macOS |
|---|--------|--------|
| DHCP + aliases | netplan / NetworkManager / systemd-networkd on the NIC or `br0` | `networksetup -setdhcp` on the hardware port; aliases via `ifconfig <dev> alias …` |
| Static + gateway | Written into netplan/NM with `via:` / routes | `networksetup -setmanual` with gateway on the service |
| DNS | netplan `nameservers` / NM | `networksetup -setdnsservers` on the hardware port |
| Bridge | Enslave wired uplink into `br0`, qemu-bridge-helper ACL | `socket_vmnet` LaunchDaemon; LAN NIC is not enslaved |

On **Linux**, gateway and DNS in the drawer apply to the whole interface plan (including DHCP primary). Static-only uplinks require a gateway before Apply.

On **macOS**, gateway and DNS follow the hardware port (`networksetup`). Aliases use `ifconfig` and do not get separate gateway/DNS fields. Install socket_vmnet as your user: `brew install socket_vmnet`. Do not `sudo brew install`.

### Linux bridge (`br0`)

Select the **uplink** row (or `br0` when present) in **Host interfaces**. **Apply** persists `br0` with NetworkManager, netplan, or systemd-networkd, writes a marker-tagged `allow br0` in `/etc/qemu/bridge.conf`, and setuids `qemu-bridge-helper` on known paths. **Revert** removes those tagged files. Shared `br0` is never default-deleted.

After Apply, the host keeps changes **pending** for 30 seconds. Click **Keep changes** in the SPA or POST `action: commit`; otherwise the host auto-reverts (netplan try / systemd timer). If the NIC carries SSH or the SPA, Apply warns and asks you to confirm **before** the uplink moves.

Wi-Fi is refused. ifupdown is refused.

Use **Apply** in the drawer, or the API:

```sh
curl -sS -X POST http://127.0.0.1:7777/api/system/bridges \
  -H 'Content-Type: application/json' \
  -d '{"interface":"<wired-uplink>","action":"apply","confirm":true,"addressing":"dhcp"}'
curl -sS -X POST http://127.0.0.1:7777/api/system/bridges \
  -H 'Content-Type: application/json' \
  -d '{"interface":"<wired-uplink>","action":"commit","confirm":true}'
curl -sS -X DELETE http://127.0.0.1:7777/api/system/bridges/br0 \
  -H 'Content-Type: application/json' \
  -d '{"confirm":true,"action":"revert","interface":"<wired-uplink>"}'
```

`action: check` and `dryRun: true` preview the plan without changing the host.

### macOS bridge (`socket_vmnet`)

Select the LAN interface row in **Host interfaces**. **Apply** starts a BarkVisor-owned LaunchDaemon (or an already-installed Homebrew service) and sets this Device’s LAN address via native Swift (`networksetup` + `ifconfig` aliases). **Revert** restores the saved profile and stops the service. NAT Workloads work with bridged host networking down.

After Apply, the same **30 second keep window** applies: click **Keep changes** in the SPA or POST `action: commit`. If the timer expires, the Device auto-reverts.

```sh
curl -sS -X POST http://127.0.0.1:7777/api/system/bridges \
  -H 'Content-Type: application/json' \
  -d '{"interface":"en0","action":"apply","confirm":true,"addressing":"dhcp"}'
curl -sS -X POST http://127.0.0.1:7777/api/system/bridges \
  -H 'Content-Type: application/json' \
  -d '{"interface":"en0","action":"commit","confirm":true}'
curl -sS -X DELETE http://127.0.0.1:7777/api/system/bridges/en0 \
  -H 'Content-Type: application/json' \
  -d '{"confirm":true,"action":"revert","interface":"en0"}'
```

## VM networks tab

Switch to **VM networks** for logical network records Workloads attach to.

- **Create Network** — opens the create modal (NAT, bridged, or isolated)
- List + inspect pane — mode, subnet, attached Workloads, interfaces

A Device that can do bridged networking but is not host-ready yet may still show as amber **Bridge · Pending** in the list. Selecting it deep-links to the owning interface on **Host interfaces**. NAT still works when bridged host networking is not ready.

### Create Workload network

The modal takes:

| Field | Meaning |
|-------|---------|
| Mode | **NAT**, **bridged**, or **isolated** |
| Host bridge interface | NIC from **Host interfaces** (bridged mode) — configure the bridge there first |
| DNS Server | DNS handed to guests (NAT / isolated) |

Device addresses (NICs, DHCP, gateways) are on **Host interfaces**. Workload networks are logical — NAT, bridged, or isolated.

Attach networks to a Workload in its [Create VM](/docs/guides/create-workload/) wizard step or from [Workload details](/docs/using/vm-details/).

## Related

- [Workload details](/docs/using/vm-details/)
- [Devices](/docs/using/devices/)
- [Installation (Linux)](/docs/linux#bridged-networking)
- [Installation (macOS)](/docs/getting-started/installation/)
