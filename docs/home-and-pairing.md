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
2. Go to **Settings → Home → Add a Device**.
3. Copy the **full** pairing offer. It looks like `barkvisor://pair/v1?…`.
4. The short printed code alone is not enough.

The offer expires. If join fails, issue a new one.

## Join from the setup wizard

On the new Device, open `http://localhost:7777` (or that host’s LAN IP) before an admin account exists.

1. Choose **Join an existing Home**.
2. Paste the full `barkvisor://pair/v1?…` offer.
3. Finish setup if the wizard still asks for a local admin (the Home login is what you use afterward).

This Device still starts if the other Device later goes down.

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

See [Installation (Linux)](getting-started-linux.md#api-only-device-no-spa).

## After Devices are paired

- **Dashboard** — Device cards show reachability and Workload counts.
- **Create VM** — pick any reachable Device. Recommended is a suggestion; you can place anyway. See [Create a Workload](create-workload.md).
- **Library** — images live on each Device. You can point a Device at a custom Library directory and optionally designate a depot Device so others fetch images over the agent plane instead of the internet.
- **Native console / phone** — allow Local Network so the app can reach the dashboard Device on `:7777`. It does not talk to members directly.

## Recovery

If a Device is wiped, it is a new Device. Re-pair it with a fresh offer. Local Workloads on other Devices are unaffected.

## Related

- [First launch](getting-started-first-launch.md)
- [Create a Workload](create-workload.md)
- [Changelog](changelog.md)
