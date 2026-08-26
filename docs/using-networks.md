# Networks

**Networks** owns virtual networking for the Home: NAT, bridged, and isolated networks, plus host bridge setup. Networks live here — not in Settings.

![Networks list with inspect pane](img/networks.png)

## Toolbar

- **Bridge setup** — guided setup when a planned bridge is not finished on the host yet
- **Create Network** — opens the create modal

## The list

Networks render on the left; rows still waiting on their host bridge show as amber **Bridge · Pending setup**.

## Inspect pane

Selecting a network shows:

- Mode chip (NAT / bridged / isolated)
- NAT subnet
- Attached Workloads
- Interfaces table
- Guided steps to finish a pending bridge

## Create Network

The modal takes:

| Field | Meaning |
|-------|---------|
| Mode | **NAT**, **bridged**, or **isolated** |
| Bridge Interface | Host interface to bridge onto (bridged mode) |
| DNS Server | DNS handed to guests |

Attach networks to a Workload in its [Create VM](create-workload.md) wizard step or from [Workload details](using-vm-details.md).

## Related

- [Workload details](using-vm-details.md)
- [Devices](using-devices.md)
