# Home and pairing

A **Home** is your set of BarkVisor machines. Each machine is a **Device**. One Device is already a Home of one. More Devices join later. This is not a cluster, node, or quorum.

One BarkVisor process owns one Device and one data directory. Workloads (VMs) run on that Device’s QEMU. If another Device is unreachable, local Workloads keep running.

See [Product terminology](product-terminology.md).

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
2. Go to **Settings → Pairing → Add a Device**.
3. Pick the address the new Device can reach: a listed LAN IPv4 or IPv6 unique-local, or **Other / DNS name…** for a name the joiner can resolve.
4. Scan the QR, or copy the **full** pairing offer (`barkvisor://pair/v1?…`). The short printed code alone is not enough. Changing the address re-issues both the URI and the QR.

The chosen address is the `host=` in that offer. Changing the address issues a new code and resets the expiry. The offer expires; Revoke it if unused.

The same **Settings → Pairing** tab holds the **phone sign-in QR**. That is how the mobile app logs into this Home. It is not on Settings → Home.

Join redeem is HTTP on `:7777`. The redeem response carries the shared login (Home JWT secret and admin row) only inside an envelope sealed to the joiner Device key, so an on-path observer of the plaintext HTTP cannot read it. Allowed addresses are RFC1918, IPv6 unique-local, and CGNAT `100.64.0.0/10`. Loopback, link-local, public IPs, and metadata (`169.254.169.254`, `100.100.100.200`) stay blocked. A name is resolved on the joining Device, not when the offer is issued.

Older joiners that only accept RFC1918 still reject a `100.64/10` offer. Upgrade the joining Device, or pick a LAN IP both sides can reach.

## Join from the setup wizard

On the new Device, open `http://localhost:7777` (or that host’s LAN IP) before an admin account exists.

1. On the other Device, pick the address this Device can reach and copy the full `barkvisor://pair/v1?…` offer.
2. Choose **Join an existing Home** and paste that offer.
3. Join. Finish setup if the wizard still asks for a local admin (the Home login is what you use afterward). On an API-only Device, use `barkvisor-agent join --code` instead.

This Device still starts if the other Device later goes down. Unauthenticated join during setup is console-local (`127.0.0.1` only).

## Join from the CLI (API-only / worker)

A Device can run without the SPA. Packages ship `barkvisor` (SPA Home Device) and `barkvisor-agent` (API-only). Same process, two names. Invoking `barkvisor-agent` skips the SPA. Do not run both.

On that host, after `barkvisor-agent.service` (Linux) or the `barkvisor-agent` daemon (macOS) is up:

```sh
barkvisor-agent join --code 'barkvisor://pair/v1?…'
```

`barkvisor join --code` posts the same offer.

Or set `BARKVISOR_JOIN_CODE` in the daemon environment (`/etc/barkvisor/barkvisor.env` on Linux) **before first boot**. After setup or an existing pair, that env is ignored.

Join always posts to the **local** console (`http://127.0.0.1:7777/api/pairing/join`). It is never proxied through Home.

Linux API-only install (even if `frontend/dist` exists):

```sh
sudo SKIP_FRONTEND=1 ./scripts/install-linux.sh
```

See [Installation (Linux)](getting-started-linux.md#api-only-device-no-spa).

## After Devices are paired

- **Sidebar Device** — **All** shows the Home union. Pick one Device to filter Workloads, Library, Networks, and Logs to that machine. Logs can still refine inside the scope. Create VM has its own Device picker and is not locked to the sidebar.
- **Dashboard** — Device cards show reachability and Workload counts. Optional widgets show/hide per browser; **Reset** restores the default set. This Device CPU/memory charts live on Device detail, not as Home-wide lists.
- **Create VM** — pick any reachable Device. Recommended is a suggestion; you can place anyway. See [Create a Workload](create-workload.md).
- **Library** — images live on each Device. You can point a Device at a custom Library directory. Missing images download from the internet. Used/free is that Library path’s volume (it can differ from the data dir). If capacity is unknown, the UI says so instead of showing zeros.
- **Native console / phone** — allow Local Network so the app can reach the dashboard Device on `:7777`. It does not talk to members directly. Sign in from **Settings → Pairing**.

## Device URL

On **Settings → Home**, pick **Device URL**: hostname, LAN IP, Tailscale IP, or MagicDNS (or **Other / DNS name…**). With Tailscale up, the default is MagicDNS as `https://<magicdns>` with no port. That host is stamped on a new pairing or sign-in QR as `host=` when you do not pick another address, and Models inference how-to uses it for `OPENAI_BASE_URL`. You can paste `https://<device>.ts.net`; only the host is stored. LAN inference stays `http://<host>:7777`.

BarkVisor does not ship Tailscale. Install [tailscaled](https://tailscale.com/download) on the Device (and on the phone or laptop you use away from home) if you want MagicDNS or a tailnet IP in the picker. When `tailscale ip -4` works, the Device still advertises that address and MagicDNS name in inventory and in the pairing/sign-in host picker.

Access is open. Device URL is which host we stamp and show, not a remote-access policy.

There is no in-app WireGuard control plane. If you already run `wg0` (or `wg`), pick that address as the Device URL so the other Device or phone can reach through that tunnel. Do not port-forward `:7777` to the public internet.

## Recovery

If a Device is wiped, it is a new Device. Re-pair it with a fresh offer. Local Workloads on other Devices are unaffected.

## Related

- [First launch](getting-started-first-launch.md)
- [Ollama](ollama.md)
- [Create a Workload](create-workload.md)
- [Changelog](changelog.md)
