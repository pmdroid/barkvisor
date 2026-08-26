---
title: "Disks"
description: "Create, resize, attach, and delete virtual disks across the Home."
---
**Disks** manages virtual disks across the Home — separate from boot images.

![Disks page with per-Device usage and disk table](/docs-img/disks.png)

## Per-device usage

Storage cards show each Device's disk usage; unreachable Devices render as unreachable cards instead of fake numbers.

## Create Disk

**Create Disk** opens a modal with:

- Name
- Block device (Linux only — attach a host block device as raw)
- Size in GB
- Format
- Location (defaults to the Device's default VM disk directory)

Linux block-device notes:

- Mounts, swaps, and devices the host already uses stay blocked.
- The Device's `barkvisor` user needs the **disk** group (`barkvisor.service.d/disk.conf`).
- macOS has no block-device option.

## The table

| Column | Meaning |
|--------|---------|
| Name | Disk name |
| Device | Where it lives |
| Path | On-host path |
| Format | qcow2/raw |
| Size | Current size |
| VM | Attached Workload, if any |
| Resize | Grow in place |
| Delete | Remove after confirmation |

New Workloads get their disks here by default; change the default under [Settings → Disks](/docs/using/settings/disks/).

## Related

- [Settings: Disks](/docs/using/settings/disks/)
- [Workload details](/docs/using/vm-details/)
