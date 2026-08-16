---
title: "Roadmap"
description: "What is in the Home stack now, what is next, and what is not a cluster."
---
Where BarkVisor is going. Words: **Home**, **Device**, **Workload**, **Library**. Not a cluster.

This is a snapshot, not a promise. Dates move. See the [changelog](/docs/changelog/) for what already works.

## Now

Shipped on the current Home stack (draft PRs, not all on `main` yet):

- Pair Devices into one Home. One login. Dashboard talks to members through the Home proxy.
- Place a Workload on any reachable Device. Recommended is a suggestion.
- Library on each Device, optional depot fetch, configurable image directory.
- API-only Device: skip the SPA, `barkvisor join --code` from that host.
- Each Device keeps running if the others are down.

Guides: [Home and pairing](/docs/guides/home-and-pairing/) · [Create a Workload](/docs/guides/create-workload/).

## Next

Open work, in roughly this order:

| Item | Notes |
|------|--------|
| Intent-first Create VM | Name, OS, and image before Device and capability talk ([PAS-182](https://linear.app/kyku/issue/PAS-182)) |
| Windows on x86 | `windows-amd64` guest — Windows already runs on x86; the profile was missing ([PAS-184](https://linear.app/kyku/issue/PAS-184)) |
| Workload Device chip | Dashboard shows which Device each Workload runs on ([PAS-181](https://linear.app/kyku/issue/PAS-181)) |
| Guest-boot checks | Opt-in local smoke and a self-hosted KVM CI lane — not default `prepush` ([PAS-183](https://linear.app/kyku/issue/PAS-183), [PAS-185](https://linear.app/kyku/issue/PAS-185), [PAS-186](https://linear.app/kyku/issue/PAS-186)) |

## Later

Worth doing, not started as product:

- Stopped Workload move between same-arch Devices
- Stronger Library (content-addressed store, richer templates)
- Live migration, cross-Device failover — only after place-and-run is boring

## Not planned

No quorum, no Ceph, no dedicated controller appliance, no “cluster” product. One process stays one Device.

The idea board is [BarkVisor product ideas](https://linear.app/kyku/project/barkvisor-product-ideas-66fdcb2cf979).
