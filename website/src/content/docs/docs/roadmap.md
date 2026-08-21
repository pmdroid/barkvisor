---
title: "Roadmap"
description: "Product ideas ahead: Home HA, quorum, Ceph, live migration, apps, and backups."
---
Ideas we want to build. Dates are not commitments. Words: **Home**, **Device**, **Workload**, **Library**.

The full board is [BarkVisor product ideas](https://linear.app/kyku/project/barkvisor-product-ideas-66fdcb2cf979). What already works is in the [changelog](/docs/changelog/).

## Shipping now

A Home of one or more Devices: pair with a code, one login, place a Workload on a picked Device, Library plus optional depot, API-only worker. Each Device keeps its own QEMU and SQLite if the others go away.

## Next

Finish the Home you can run today:

- Create VM asks what you want before where it runs
- Windows on x86 Devices (`windows-amd64`)
- Dashboard shows which Device each Workload is on
- Guest-boot checks locally and on a KVM runner
- Recover and re-pair a Device without losing inventory

## Later — availability

A Home that survives a Device dying, not only a Device that survives the Home going quiet.

- **Failover** — restart a portable Workload on another Device after a failure
- **Live migration** — move a running Workload between compatible Devices
- **Stopped move** — same-architecture migrate when the guest is off
- **Optional controller** — one Device can coordinate the others without being required
- **Quorum** — Devices agree who is in the Home and who can place or fail over, so a split brain does not double-start a Workload
- **Linux appliance** — a dedicated-server image for a Device that only runs BarkVisor

## Later — storage

- **Ceph / distributed storage** — Workload disks that more than one Device can see, so failover does not copy a qcow2 first
- **Content-addressed Library** — one copy of each image, verified by hash
- **Managed volumes** — disks that outlive a single Workload
- **Deeper ZFS** — snapshots and send/receive when the Device already uses ZFS

## Later — Workloads and backup

- Portable Application Workloads (not only VMs)
- Curated home app catalog
- Scheduled backups, backup verification, restore as a new Workload
- Portable backup / export bundle you can take to another Device
- Workload update policies and automatic rollback

## Later — network and access

- Cross-Device private network
- Tailscale or WireGuard so a Home works off the LAN (v1: detect Tailscale, advertise tailnet, optional require-tailnet; WireGuard is docs-only)

- Friendly service URLs
- Passkeys and two-factor login
- Energy-aware placement (prefer the Device that is already awake)

These stay product ideas until the Home you have now is boring to operate.
