---
title: "Networks"
description: "NAT, bridged, and isolated networks plus host bridge setup."
---
**Networks** owns virtual networking for the Home: NAT, bridged, and isolated networks, plus host bridge setup. Networks live here — not in Settings.

![Networks list with inspect pane](/docs-img/networks.png)

## Toolbar

- **Bridge setup** — Linux Apply/Revert for `br0`; macOS Setup/Start/Stop for `socket_vmnet`. Copyable install commands stay on the sheet.
- **Create Network** — opens the create modal

## The list

Networks render on the left. A Device that can do bridged networking but is not host-ready yet shows as amber **Bridge · Pending**. A Device that already has `br0` / `socket_vmnet` ready does not — create a Bridged network from **Create Network**.

## Inspect pane

Selecting a network shows:

- Mode chip (NAT / bridged / isolated)
- NAT subnet
- Attached Workloads
- Interfaces table

Selecting a pending bridge shows the host commands for that Device (Linux `br0` / macOS `socket_vmnet`) plus **Setup / Start / Stop** on a Mac Device, then **Re-check**. NAT still works when `socket_vmnet` is down.

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
