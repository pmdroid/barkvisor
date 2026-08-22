---
title: "Home and pairing"
description: "Add a Device to a Home, join from setup or the CLI, and what pairing does not do."
---
A **Home** is your set of BarkVisor machines. Each machine is a **Device**. One Device is already a Home of one. More Devices join later. This is not a cluster, node, or quorum.

One BarkVisor process owns one Device and one data directory. Workloads (VMs) run on that Device’s QEMU. If another Device is unreachable, local Workloads keep running.

See [Product terminology](/docs/concepts/terminology/).

## What pairing does

Pairing joins a second Device to an existing Home. After a successful join:

- Both Devices share the same login (the Home identity).
- The first Device’s dashboard lists every paired Device and their health.
- You create and start Workloads on a picked Device from that dashboard. The phone or browser talks only to the dashboard Device (`:7777`). Members are reached through the Home proxy, not by opening each member’s IP.
- Devices talk to each other on the agent plane (`:7778`) over mutual TLS.

Pairing does **not** move QEMU, share disks, or elect a controller. Each Device still owns its own SQLite and its own Workloads.

## Add a Device (from the Home)

On a Device that already finished setup:

1. Open the dashboard (`http://<this-device>:7777`).
2. Go to **Settings → Home → Add a Device**.
3. Pick the address the new Device can reach: a listed LAN IPv4 or IPv6 unique-local, or **Other / DNS name…** for a name the joiner can resolve.
4. Scan the QR, or copy the **full** pairing offer (`barkvisor://pair/v1?…`). The short printed code alone is not enough. Changing the address re-issues both the URI and the QR.

The chosen address is the `host=` in that offer. Changing the address issues a new code and resets the expiry. The offer expires; Revoke it if unused.

Join redeem is HTTP on `:7777`. Allowed addresses are RFC1918, IPv6 unique-local, and CGNAT `100.64.0.0/10`. Loopback, link-local, public IPs, and metadata (`169.254.169.254`, `100.100.100.200`) stay blocked. A name is resolved on the joining Device, not when the offer is issued.

Older joiners that only accept RFC1918 still reject a `100.64/10` offer. Upgrade the joining Device, or pick a LAN IP both sides can reach.

## Join from the setup wizard

On the new Device, open `http://localhost:7777` (or that host’s LAN IP) before an admin account exists.

1. On the other Device, pick the address this Device can reach and copy the full `barkvisor://pair/v1?…` offer.
2. Choose **Join an existing Home** and paste that offer.
3. Join. Finish setup if the wizard still asks for a local admin (the Home login is what you use afterward). On an API-only Device, use `barkvisor join --code` instead.

This Device still starts if the other Device later goes down. Unauthenticated join during setup is console-local (`127.0.0.1` only).

## Join from the CLI (API-only / worker)

A Device can run without the SPA. The binary is the same — there is no separate worker process.

On that host, after the daemon is up:

```sh
barkvisor join --code 'barkvisor://pair/v1?…'
```

Or set `BARKVISOR_JOIN_CODE` in the daemon environment (`/etc/barkvisor/barkvisor.env` on Linux) **before first boot**. After setup or an existing pair, that env is ignored.

Join always posts to the **local** console (`http://127.0.0.1:7777/api/pairing/join`). It is never proxied through Home.

Linux API-only install (even if `frontend/dist` exists):

```sh
sudo SKIP_FRONTEND=1 ./scripts/install-linux.sh
```

See [Installation (Linux)](/docs/linux#api-only-device-no-spa).

## After Devices are paired

- **Dashboard** — Device cards show reachability and Workload counts. Open a Device to see its LAN and tailnet IPs.
- **Create VM** — pick any reachable Device. Recommended is a suggestion; you can place anyway. See [Create a Workload](/docs/guides/create-workload/).
- **Library** — images live on each Device. You can point a Device at a custom Library directory and optionally designate a depot Device so others fetch images over the agent plane instead of the internet.
- **Native console / phone** — allow Local Network so the app can reach the dashboard Device on `:7777`. It does not talk to members directly.

## Remote access (Tailscale)

BarkVisor does not ship Tailscale and does not build a WireGuard mesh or VXLAN overlay. Install [tailscaled](https://tailscale.com/download) on each Device you want reachable off the LAN (and on the phone or laptop you use away from home). When `tailscale ip -4` works, that address and MagicDNS name show up in inventory, on the Device page, and in the pairing/sign-in host picker.

Each Device reports **LAN** (RFC1918 / IPv6 unique-local) and **tailnet** (`100.64.0.0/10` and Tailscale IPv6) addresses. The browser still talks only to the dashboard Device on `:7777`. Members are reached through the Home proxy; the stored member target is the `host=` you picked when pairing.

To keep a Home of more than one Device working away from the LAN:

1. Install Tailscale on every Device in the Home.
2. Pair using the tailnet IP or MagicDNS name so `agentHost` is an address the other Device can still reach.
3. If you already paired on a LAN IP, issue a new offer with the tailnet address and join again.

On **Settings → Home**:

- **Advertise URL** — optional host stamped on a new pairing or sign-in QR as `host=` when you do not pick another address. Accepts a LAN IP, CGNAT `100.64/10` address, or DNS name (MagicDNS). You can paste `http://box.ts.net:7777`; only the host is stored.
- **Require Tailscale (or LAN) for the Home API** — off by default. When on, requests to this Device from a public address return 403. Loopback, RFC1918, IPv6 unique-local, and `100.64.0.0/10` (except `100.100.100.200`) stay allowed. The gate uses the TCP peer on `:7777`, not `X-Forwarded-For`. Do not put a local reverse proxy in front of BarkVisor if you rely on this checkbox.

LAN management never needs a VPN. Guest NICs stay NAT, bridged, or isolated — this is Device reachability, not a guest overlay.

### WireGuard (docs only)

There is no in-app WireGuard control plane. If you already run `wg0` (or `wg`), BarkVisor reports that a tunnel is present. Point **Advertise URL** at the address the other Device or phone can reach through that tunnel. Do not port-forward `:7777` to the public internet.

## Recovery

If a Device is wiped, it is a new Device. Re-pair it with a fresh offer. Local Workloads on other Devices are unaffected.

## Related

- [First launch](/docs/getting-started/first-launch/)
- [Create a Workload](/docs/guides/create-workload/)
- [Changelog](/docs/changelog/)
