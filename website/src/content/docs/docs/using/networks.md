---
title: "Networks"
description: "NAT, bridged, and isolated networks plus host bridge setup."
---
**Networks** owns virtual networking for the Home: NAT, bridged, and isolated networks, plus host bridge setup. Networks live here, not in Settings.

![Networks list with inspect pane](/docs-img/networks.png)

Words: **Home**, **Device**, **Workload**. Host addressing on the LAN is this Device (configure in **Networks → Bridge setup**).

## Toolbar

- **Bridge setup** — Apply/Revert host networking on Linux (`br0`) and macOS (`socket_vmnet` + Device LAN address). DHCP or static for this Device. Copyable commands stay on the sheet.
- **Create Network** — opens the create modal

## The list

Networks render on the left. A Device that can do bridged networking but is not host-ready yet shows as amber **Bridge · Pending**. A Device that already has `br0` / `socket_vmnet` ready does not. Create a Bridged network from **Create Network**.

## Inspect pane

Selecting a network shows:

- Mode chip (NAT / bridged / isolated)
- NAT subnet
- Attached Workloads
- Interfaces table

Selecting a pending bridge shows the host commands for that Device plus the same **Device address** (DHCP or static) and **Apply / Revert** controls as **Bridge setup**. NAT still works when bridged host networking is not ready.

## Bridge setup

The root Device daemon can change the host. Copyable commands stay on the page so you can audit what Apply will do.

### Linux (`br0`)

**Apply** persists `br0` with NetworkManager, netplan, or systemd-networkd, writes a marker-tagged `allow br0` in `/etc/qemu/bridge.conf`, and setuids `qemu-bridge-helper` on known paths. **Revert** removes those tagged files. Shared `br0` is never default-deleted.

Host address on `br0` is DHCP or static for this Device. Configure it in **Networks → Bridge setup**.

Rollback is a **host timer** (`netplan try` / `systemd-run`). If the NIC carries SSH or the SPA, Apply warns and asks you to confirm **before** the uplink moves. Do not Confirm in the browser after the uplink dies.

Wi-Fi is refused. ifupdown is refused.

Equivalent:

```sh
sudo linux-bridge-apply.sh --apply --nic <wired-uplink> --dhcp
sudo linux-bridge-apply.sh --revert
```

`--dry-run` and `--check` print the plan without changing the host.

### macOS (`socket_vmnet`)

Install the formula as your user:

```sh
brew install socket_vmnet
```

Do not `sudo brew install`. **Apply** starts a BarkVisor-owned LaunchDaemon (or an already-installed Homebrew service) and sets this Device’s LAN address with `networksetup` (DHCP or static — same fields as Linux). **Revert** restores the saved profile and stops the service. NAT Workloads work with bridged host networking down. The Mac LAN NIC is not enslaved.

## Create Network

The modal takes:

| Field | Meaning |
|-------|---------|
| Mode | **NAT**, **bridged**, or **isolated** |
| Bridge Interface | Host interface to bridge onto (bridged mode) |
| DNS Server | DNS handed to guests |

Attach networks to a Workload in its [Create VM](/docs/guides/create-workload/) wizard step or from [Workload details](/docs/using/vm-details/).

## Related

- [Workload details](/docs/using/vm-details/)
- [Devices](/docs/using/devices/)
- [Installation (Linux)](/docs/linux#bridged-networking)
- [Installation (macOS)](/docs/getting-started/installation/)
