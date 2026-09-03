# Networks

**Networks** owns connectivity for the Home: host NIC addressing on this Device, plus VM network records (NAT, bridged, isolated). Networks live here, not in Settings.

![Networks — Host interfaces tab](img/networks.png)

Words: **Home**, **Device**, **Workload**, **Bridge**. Host addressing is this Device. Configure it on **Networks → Host interfaces**. Workload networks are logical records on the **VM networks** tab.

## Tabs

**Networks** opens with two tabs:

| Tab | Purpose |
|-----|---------|
| **Host interfaces** (default) | Live NICs on this Device — addresses, Apply. Bridges are their own rows. |
| **VM networks** | NAT / bridged / isolated records Workloads attach to |

**Create → Bridge** is the path for a **new** switch. Fresh install: NICs are unbridged. Uplink Apply no longer implies `br0`.

## Host interfaces tab

The table lists each NIC on the Device:

| Column | Meaning |
|--------|---------|
| Device | Which Device owns the NIC |
| Interface | OS name (`en0`, `eth0`, `br0`, …) |
| Role | uplink, bridge, tailscale, … |
| Link | link state when known |
| Addresses (live) | DHCP + static aliases read from the host |
| Bridge | bridge membership / readiness |
| Route | default route when relevant |

The toolbar **Create** button opens a menu with **Bridge**. The create modal suggests the next-free `brN` (editable) and enslaves one unused NIC — Linux refuses Wi-Fi, macOS allows `en0` (Wi-Fi).

Apply creates the host bridge and wires a bridged Workload network (`network.bridge = brN`) to it. Same confirm and 60 second Keep as other host-network changes. Two NICs are two Bridges. Workloads pick a Bridge by `brN`.

Select a row to open the **edit drawer** below the table.

### Address list

The drawer keeps DHCP on. The router lease is shown and is not editable or removable.

- **DHCP** — live lease from the router (read-only)
- **additional** — extra static CIDR on the same NIC
- **on host** chip — BarkVisor wrote this config

**Gateway** and **DNS** apply to the NIC as a whole (not per alias). A Bridge row has no address fields — it shows which NIC it is attached to. Add extra static IPs on the NIC, then **Apply** and **Keep changes** within the keep window. DHCP stays on.

**Apply** persists the address plan on the host. **Revert** undoes BarkVisor files without deleting a shared Bridge. Linux Bridge rows can **Delete**.

### Multi-address examples

**DHCP primary + static alias** — the common case for a service IP alongside router DHCP: keep DHCP on, add one extra static address on the same NIC, Apply, then Keep.

**Static-only** (no DHCP) — used on bridges: fill in the static address plus gateway and DNS, Apply, then Keep.

Use **Apply** in the drawer — it previews the plan before anything on the host changes.

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

### Linux Bridge (`brN`)

**Create → Bridge** allocates the next-free `brN` and enslaves one unused wired NIC. Apply persists that `brN` with NetworkManager, netplan, or systemd-networkd, writes a marker-tagged `allow brN` in `/etc/qemu/bridge.conf`, and setuids `qemu-bridge-helper` on known paths. Shared kernel bridges are never default-deleted.

Apply first shows a confirmation with collapsible change details. After Apply, changes stay **pending** for 60 seconds. A modal asks you to click **Keep changes** or they auto-revert — including tearing down a Bridge you just created. If the NIC carries SSH or the SPA, Apply warns before the uplink moves.

Wi-Fi is refused. ifupdown is refused.

Use **Create → Bridge** in the toolbar — it walks you through NIC selection and confirmation.

### macOS (`socket_vmnet`)

**Create → Bridge** maps the next-free `brN` onto a NIC (`en0` Wi-Fi is allowed), starts `socket_vmnet`, and adds a bridged Workload network. Extra static aliases still apply on the NIC from the same drawer. NAT Workloads work with bridged host networking down.

After Apply, the same **60 second keep window** applies: click **Keep changes** in the modal. If the timer expires, the Device auto-reverts.

Automating host networking (scripts, onboarding)? The same operations live in `docs/api/openapi.yaml` under `/api/system/interfaces`.

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
