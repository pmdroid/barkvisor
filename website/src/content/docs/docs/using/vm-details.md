---
title: "Workload details"
description: "Actions and tabs for one VM: overview, console, VNC, metrics, logs."
---
Every VM row links to its detail page. This is where you drive a single **Workload**: lifecycle actions, hardware facts, and the console surfaces.

![Workload detail: Overview tab with hardware, network, and disks](/docs-img/vm-detail.png)

## Toolbar actions

- **Start when this Device boots** — labeled toggle next to Start. Off unless you turn it on.
- **Start** — boot the Workload
- **Stop** — split button: **Shutdown** (clean ACPI shutdown) vs **Force Stop** (pull the plug), with confirmation
- **Restart** — clean reboot
- **VNC** — opens the graphical display in a resizable browser window
- **Delete** — removes the Workload after confirmation

Actions that need the Device's agent are disabled while it is unreachable.

## Tabs

Which tabs appear depends on state: **Metrics** only shows while running, and member Devices hide **Console/VNC** until they are reachable again.

### Overview

Read-only facts grouped into sheets: **Session**, **Hardware**, **Network**, **Guest**, **Disks**, **Shared folders**, **USB**, **GPU passthrough**, and **PCI devices** (Linux hosts only).

### Console / Terminal

A serial console in the browser. Coding-agent Workloads label this tab **Terminal**; every other guest calls it **Console**.

### VNC

Graphical access via noVNC. The toolbar **VNC** button pops the same view out into a dedicated window you can resize onto a second monitor.

### Metrics

Live CPU/memory charts — visible only for running Workloads.

### Logs

This Workload's log stream, filtered from the global [Logs](/docs/using/logs/) feed.

## Related

- [Virtual Machines](/docs/using/vms/)
- [Devices](/docs/using/devices/)
- [Networks](/docs/using/networks/) — ports and interfaces shown under Overview
- [GPU passthrough](/docs/guides/gpu-passthrough/) — IOMMU / vfio-pci on a Linux Device
