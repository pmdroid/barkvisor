---
title: "Changelog"
description: "What shipped for Home pairing, Library, and Create VM."
---
Product notes for operators. Words: **Home**, **Device**, **Workload**, **Library**. Not a cluster.

Unreleased items live on stacked draft PRs and may change before they land on `main`.

## Unreleased

### Home of more than one Device

- Pair another Device from **Settings → Home → Add a Device**. Pick a LAN IP or DNS name for `host=` in the offer, then scan the QR or paste the full `barkvisor://pair/v1?…` in setup, or run `barkvisor join --code` on an API-only host. Changing the address re-issues the URI and the QR.
- Join allow-list now includes CGNAT `100.64.0.0/10` (still blocks `100.100.100.200`, loopback, link-local, public, and metadata). An older joiner still rejects those offers — upgrade it or pick a LAN IP.
- Optional `BARKVISOR_JOIN_CODE` on first boot. Join is always console-local on that Device.
- Devices share one Home login. The dashboard lists every Device and health.
- Create, start, and stop Workloads on a picked Device through the Home proxy (`:7777`). The browser or phone does not open member IPs. Agent traffic uses mTLS on `:7778`.
- Recommended Device is a suggestion. You can place a Workload on any reachable Device.
- A Device still runs if peers are down. Local SQLite owns runtime.

### Library

- Images are no longer filtered to this Device’s arch only. Download ARM64 or x86_64 as needed.
- Configurable Library directory (new downloads; existing files are not migrated).
- Optional depot Device: on a local miss, fetch image bytes over the agent plane, verify checksum, then store locally. Depot down falls back to the internet.
- Catalog pins use dated Ubuntu snapshot URLs so checksums stay stable.

### Worker-only Device

- `SKIP_FRONTEND=1` install skips the SPA. Same daemon, no extra process role.
- `barkvisor` always has a `serve` command so systemd does not exit 64.

### Create VM

- Place on This Device or any reachable member. Incompatibility is a warning, not a lock.
- Guest default follows This Device’s arch so a recommended ARM64 member does not grey out an x86 Home.

### Platform

- Linux packages (`.deb` / `.rpm` / tarball), systemd, NAT and bridged networking, USB passthrough.
- Native console app talks to the dashboard Device only (Local Network permission is for `:7777`).

## 0.x — single Device

The first public line is a **Home of one**: one daemon, Vue SPA on port 7777, QEMU Workloads, Library images and templates, NAT and optional bridge, console and VNC, cloud-init, SSH keys.

See [First launch](/docs/getting-started/first-launch/), [Quickstart](/docs/getting-started/quickstart/), and the [roadmap](/docs/roadmap/).
