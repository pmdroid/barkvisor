# Workloads

**Workloads** lists VMs and Apps across the Devices selected in the sidebar. Click a row to open [VM details](using-vm-details.md) or [App details](using-apps.md).

![Virtual Machines list with health filter chips](img/vms.png)

## Health filters

Filter chips above the table show counts at a glance:

- **All**
- **Running**
- **Failed**
- **Stopped**

The counts update live; a failed count above zero is your cue to visit the [Dashboard](using-dashboard.md).

## The table

| Column | Meaning |
|--------|---------|
| Name | Workload name — click to open [details](using-vm-details.md) |
| Device | Machine running it |
| OS | Guest OS / image it was created from |
| CPU · Mem | Allocated vCPUs and memory |
| Ports | Forwarded host ports |
| Status | Running, failed, or stopped |

## Create VM

**Create VM** opens the 3-step wizard (**Gallery → Configure → Disk**). The full walkthrough is in [Create a Workload](create-workload.md).

Use **Create App** for a Docker Compose app. See [Apps](using-apps.md).

## Related

- [Apps](using-apps.md) — Docker Compose workloads
- [Workload details](using-vm-details.md)
- [Images](using-images.md) — pick what to boot
- [Disks](using-disks.md) — attach extra disks
