# Changelog

Product notes for operators. Words: **Home**, **Device**, **Workload**, **Library**. Not a cluster.

Unreleased items live on stacked draft PRs and may change before they land on `main`.

## Unreleased

- SPA inventory: Workloads, disks, networks, and logs share one Home-by-Device fetch helper (last-known when a Device is unreachable).

### Workloads list

- Running Workloads show SSH and HTTP chips from guest-info listeners. Links match Overview: bridged guest IP, This Device NAT through hostfwd, never localhost on a member, never loopback. The IP column is copyable only on bridged.

### Home of more than one Device

- Pair another Device from **Settings → Home → Add a Device**. Pick a LAN IPv4, IPv6 unique-local, or DNS name for `host=` in the offer, then scan the QR or paste the full `barkvisor://pair/v1?…` in setup, or run `barkvisor join --code` on an API-only host. Changing the address re-issues the URI and the QR. A rejected address (localhost, public, metadata) returns 400 and drops the previous pairing code.
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

### VNC

- Copy and paste text between this computer and a desktop guest (Paste / Copy on the VNC toolbar, or ⌘V / Ctrl+V). Linux guests need `spice-vdagent`; Windows guests need Spice guest tools. Restart the Workload after upgrade so QEMU adds the vdagent channel.
- Display to a member Device no longer drops after the first framebuffer. The Home hop buffer is 8 MiB so QEMU RFB updates are not treated as overflow.
- Member Display hops the agent plane straight to the QEMU VNC socket. The extra loopback through this Device's `:7777` WebSocket was dropping the RFB banner.
- Member Display no longer dies after the first picture. Tight framebuffer reads were sent as 16 KiB+ WebSocket frames; the Home hop (NIO client max 16 KiB) closed mid-update. The hop now chunks at 12 KiB.

### Create VM

- Place on This Device or any reachable member. Incompatibility is a warning, not a lock.
- Guest default follows This Device’s arch so a recommended ARM64 member does not grey out an x86 Home.

### Guest ports

- Workload detail shows TCP listening ports from the guest addon (SSH, HTTP, and common dev servers). Loopback stays internal and is never a URL. Members use the same guest-info hop as This Device.
- Listening ports are the common set only (SSH, HTTP/S, typical dev servers, DBs, RDP, VNC) — rpcbind and the rest stay hidden. HTTP that actually answers `HEAD /` (or a well-known HTTP port when the probe cannot run) is an Open link.
- This Device NAT Overview offers **Publish this port** when a common TCP listener has no matching hostfwd. The host port is the guest port if free, otherwise the next free NAT claim (PAS-64). One click opens the existing port-forwards editor. Restart is still required if QEMU is already started. Loopback listeners stay hidden. Member NAT is not a click: localhost would be the wrong machine.
- A failed collect clears the snapshot (`null`, hidden in the web UI) instead of keeping stale ports. Collection shares a ~3s budget and caps guest-exec output. Unchanged snapshots skip rewriting port columns. Labeled common ports sort first.
- A Windows Workload with the VirtIO guest addon reports the same TCP listen set (`netstat -ano` or PowerShell). Missing bash/python skips the HTTP probe and uses the well-known scheme. Denied exec stays `null` and backs off like Linux.

### Platform

- Restarting the Device daemon no longer stops Workloads. systemd signals only BarkVisor; QEMU stays up and is reattached. Use Workload Stop to shut a guest down.

- Linux packages (`.deb` / `.rpm` / tarball), systemd, NAT and bridged networking, USB passthrough.
- Native console app talks to the dashboard Device only (Local Network permission is for `:7777`).
- Phone and Mac Console / Display open a Workload on a reachable member the same way the Home web UI does (Home WebSocket tunnel). Create VM stays web-only.

## 0.x — single Device

The first public line is a **Home of one**: one daemon, Vue SPA on port 7777, QEMU Workloads, Library images and templates, NAT and optional bridge, console and VNC, cloud-init, SSH keys.

See [First launch](getting-started-first-launch.md), [Quickstart](getting-started-quickstart.md), and the [roadmap](roadmap.md).
