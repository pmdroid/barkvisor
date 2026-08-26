---
title: "Virtual Machines"
description: "All Workloads in the Home with health filters and quick actions."
---
**Virtual Machines** lists every **Workload** (VM) in the Home across all Devices in the current [scope](/docs/using/).

## Health filters

Filter chips above the table show counts at a glance:

- **All**
- **Running**
- **Failed**
- **Stopped**

The counts update live; a failed count above zero is your cue to visit the [Dashboard](/docs/using/dashboard/).

## The table

| Column | Meaning |
|--------|---------|
| Name | Workload name — click to open [details](/docs/using/vm-details/) |
| Device | Machine running it |
| OS | Guest OS / image it was created from |
| CPU · Mem | Allocated vCPUs and memory |
| Ports | Forwarded host ports |
| Status | Running, failed, or stopped |

## Create VM

**Create VM** opens the split-rail wizard (Basics → Image → Place → Hardware → Storage → Network → Summary). The full walkthrough is in [Create a Workload](/docs/guides/create-workload/).

Empty Homes see "No virtual machines yet" with a shortcut to create the first one.

## Related

- [Workload details](/docs/using/vm-details/)
- [Images](/docs/using/images/) — pick what to boot
- [Disks](/docs/using/disks/) — attach extra disks
