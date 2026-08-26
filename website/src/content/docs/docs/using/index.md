---
title: "Using the web UI"
description: "Run BarkVisor, sign in, and a map of every menu point in the console."
---
BarkVisor is a headless daemon that manages QEMU virtual machines and serves a web console. Install it on a **Device** ([macOS](/docs/getting-started/installation/), [Linux](/docs/linux/)) and open `http://<device>:7777` in a browser — nothing to launch by hand; the daemon serves the UI itself. To hack on the UI or daemon, see [Development](/docs/getting-started/development/).

![The BarkVisor sign-in screen](/docs-img/login.png)

## First run

Before sign-in, the setup wizard walks you through creating the **Home**:

- **Set up this Device** — create the admin account (username and password) and pick the network interface to advertise. This makes the machine the first Device of a new Home.
- **Join an existing Home** — paste or scan a pairing offer (`barkvisor://pair/v1?…`) issued by another Device in the Home.

Details live in [First launch](/docs/getting-started/first-launch/) and [Home and pairing](/docs/guides/home-and-pairing/).

## Roles

- **Admin** — full access to every menu point described here.
- **Inference** — sees **Ollama** (and **Chat** once a model is reachable) and lands there after sign-in. Everything else stays hidden.

## Reading the shell

Around every page sit four shared pieces of chrome:

- **Sidebar** — the navigation listed below. On small screens it collapses behind a hamburger button.
- **Device scope selector** — above the nav, "…scope" switches between **All** (the union of the Home) and one Device. List pages filter to that scope. Creating a VM keeps its own placement picker regardless.
- **Ops ticker** — the strip above the content shows live counts of running, failed, stopped, and unreachable Workloads/Devices, with a pulsing dot on problems and a **Live** marker on the right.
- **Bottom of the sidebar** — a **Light/Dark mode** toggle and **Logout**.

## Every menu point

| Menu | Page |
|------|------|
| Dashboard | [Dashboard](/docs/using/dashboard/) |
| Devices | [Devices](/docs/using/devices/) |
| Virtual Machines | [Virtual Machines](/docs/using/vms/) and [Workload details](/docs/using/vm-details/) |
| Ollama | [Ollama](/docs/using/ollama/) |
| Chat | [Chat](/docs/using/chat/) |
| Images | [Images](/docs/using/images/) |
| Disks | [Disks](/docs/using/disks/) |
| Networks | [Networks](/docs/using/networks/) |
| Repositories | [Repositories](/docs/using/repositories/) |
| Logs | [Logs](/docs/using/logs/) |
| Settings | [Settings](/docs/using/settings/) — one page per tab |

## Related

- [Quickstart](/docs/getting-started/quickstart/) — download an image, create your first VM
- [Product terminology](/docs/concepts/terminology/) — Home, Device, Workload
- [Troubleshooting](/docs/getting-started/troubleshooting/)
