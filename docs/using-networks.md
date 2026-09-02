# Networks

**Networks** owns connectivity for the Home: host NIC addressing on this Device, plus VM network records (NAT, bridged, isolated). Networks live here, not in Settings.

![Networks — Host interfaces tab](img/networks.png)

Words: **Home**, **Device**, **Workload**, **Bridge**. Host addressing is this Device. Configure it on **Networks → Host interfaces**. Workload networks are logical records on the **VM networks** tab.

## Tabs

**Networks** opens with two tabs:

| Tab | Purpose |
|-----|---------|
| **Host interfaces** (default) | Every OS NIC on this Device. Addresses, DHCP, gateway, DNS. Apply and Revert. |
| **VM networks** | NAT / bridged / isolated records Workloads attach to |

**Create → Bridge** on Host interfaces is the only path for a **new** switch. Fresh install: NICs are unbridged. Applying addresses on an uplink does not create `br0`.

## Host interfaces tab

The table lists every OS interface. A managed Bridge is its own row, attached to the port NIC (Linux `brN`, Mac `socket_vmnet` on `en0`).

| Column | Meaning |
|--------|---------|
| Interface | OS name (`en0`, `eth0`, `br0`, …) |
| Role | uplink, bridge, external, … |
| Addresses (live) | DHCP + static aliases on the NIC. Bridge rows show an em dash. |
| Bridge | attachment: `→ brN` on the port, members on the Bridge row |
| Route | default route when relevant |

Edit addresses, DHCP, gateway, and DNS on the **NIC** row. The kernel may still keep Linux L3 on `brN`. The UI overlays that onto the enslaved NIC when the NIC itself has no IPv4. Mac does not invent `br0` for display or Apply.

Toolbar **Create → Bridge** opens the create modal:

| Field | Meaning |
|-------|---------|
| Name | Server next-free `br0`, `br1`, … (read-only). Skips kernel-existing and marked names. AgentBox `br0` means first Create is `br1`. |
| Port | One unused NIC. Linux refuses Wi-Fi. Mac `en0` (Wi-Fi) is allowed. |
| Create VM network | Default on. Adds a bridged Workload network with `network.bridge = brN` |

Create does not ask for DHCP, IP, gateway, or DNS. Addressing stays on the NIC. Apply copies the selected port's current snapshot into the plan so the API still gets addresses.

**Apply** uses the same confirm and 30 second Keep as other host-network changes. Keep lands on the NIC you applied from, not the Bridge row. Two NICs are two Bridges. Workloads pick a Bridge by `brN`.

Select a row to open the **edit drawer** below the table. Attachment is the Bridge column and the Bridge row subtitle (members). There is no Bridge role field.

### Address list

The drawer on a NIC shows DHCP primary and static aliases together:

- **DHCP (primary)**. Toggle for the main address from your router
- **static**. Primary static CIDR when DHCP is off
- **alias**. Extra CIDR on the same NIC (multi-homed or service IPs)
- **on host** chip. BarkVisor wrote this config and can revert it

**Gateway** and **DNS** apply to the NIC as a whole, not per alias. The enslaved NIC editor stays enabled. The Bridge row hides the address editor. Delete and Revert still work on a created Bridge.

Actions:

- **Apply**. Persist the address plan on the NIC
- **Revert**. Remove BarkVisor-tagged config
- **Delete**. Tear down a BarkVisor-created Bridge
- **Re-check**. Refresh live addresses from the OS

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
  "interface": "eth0",
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
| DHCP + aliases | netplan / NetworkManager / systemd-networkd. Kernel L3 may sit on `brN`; edit it on the enslaved NIC | `networksetup -setdhcp` on the hardware port; aliases via `ifconfig <dev> alias …` |
| Static + gateway | Written into netplan/NM with `via:` / routes | `networksetup -setmanual` with gateway on the service |
| DNS | netplan `nameservers` / NM | `networksetup -setdnsservers` on the hardware port |
| Bridge | Enslave a wired NIC into `brN`, qemu-bridge-helper ACL | `socket_vmnet` LaunchDaemon attached to `en0`. Do not invent `br0` |

On **Linux**, gateway and DNS in the drawer apply to the whole interface plan (including DHCP primary). Static-only uplinks require a gateway before Apply.

On **macOS**, gateway and DNS follow the hardware port (`networksetup`). Aliases use `ifconfig` and do not get separate gateway/DNS fields. Install socket_vmnet as your user: `brew install socket_vmnet`. Do not `sudo brew install`.

### Linux Bridge (`brN`)

**Create → Bridge** allocates the next-free `brN` and enslaves one unused wired NIC. Apply persists that `brN` with NetworkManager, netplan, or systemd-networkd, writes a marker-tagged `allow brN` in `/etc/qemu/bridge.conf`, and setuids `qemu-bridge-helper` on known paths. **Revert** removes those tagged files. Shared kernel bridges are never default-deleted.

After Create, edit L3 on the enslaved NIC. Linux still refuses to create a Bridge by applying addresses on a standalone uplink. After Apply, the host keeps changes **pending** for 30 seconds. Click **Keep changes** on that NIC row, or run `--commit` on the host. Otherwise the host auto-reverts (netplan try / systemd timer). If the NIC carries SSH or the SPA, Apply warns and asks you to confirm **before** the uplink moves.

Wi-Fi is refused. ifupdown is refused.

Use **Create → Bridge**, or the API (include `bridge` and `nic`):

```sh
curl -sS http://127.0.0.1:7777/api/system/bridges/next
curl -sS -X POST http://127.0.0.1:7777/api/system/bridges \
  -H 'Content-Type: application/json' \
  -d '{"interface":"<wired-uplink>","bridge":"br0","action":"apply","confirm":true,"addressing":"dhcp"}'
curl -sS -X POST http://127.0.0.1:7777/api/system/bridges \
  -H 'Content-Type: application/json' \
  -d '{"interface":"<wired-uplink>","bridge":"br0","action":"commit","confirm":true}'
curl -sS -X DELETE http://127.0.0.1:7777/api/system/bridges/br0 \
  -H 'Content-Type: application/json' \
  -d '{"confirm":true,"action":"revert","interface":"<wired-uplink>","bridge":"br0"}'
```

`action: check` and `dryRun: true` preview the plan without changing the host.

### macOS bridge (`socket_vmnet`)

**Create → Bridge** on Host interfaces sends `bridge` plus `nic` (Mac `en0` is allowed). Addressing is not collected in Create. **Apply** on the LAN NIC starts a BarkVisor-owned LaunchDaemon (or an already-installed Homebrew service) and sets this Device’s LAN address via native Swift (`networksetup` + `ifconfig` aliases). **Revert** restores the saved profile and stops the service. NAT Workloads work with bridged host networking down.

After Apply, the same **30 second keep window** applies on the NIC row (`en0`). Click **Keep changes** in the SPA or POST `action: commit`. If the timer expires, the Device auto-reverts. Do not invent `br0` to place the banner or the Apply target.

API (same routes as Linux; `interface` is the hardware port, e.g. `en0`):

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

Attach networks to a Workload in its [Create VM](create-workload.md) wizard step or from [Workload details](using-vm-details.md).

## Related

- [Workload details](using-vm-details.md)
- [Devices](using-devices.md)
- [Installation (Linux)](getting-started-linux.md#bridged-networking)
- [Installation (macOS)](getting-started-installation.md)
