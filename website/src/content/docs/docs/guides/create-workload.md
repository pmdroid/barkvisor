---
title: "Create a Workload"
description: "Create a VM on this Device or another paired Device from the Home dashboard."
---
A **Workload** is a VM running on one **Device**. Create it from the Home dashboard even when it will run on another Device.

## From the dashboard

1. Open the Home console (`http://<dashboard-device>:7777`).
2. Click **Create VM**.
3. Name the Workload and choose Linux or Windows.
4. Pick an ISO or cloud image from the **Library**.
5. Pick the **Device** that will run it. The recommended Device is pre-selected. Any **reachable** Device is still selectable — reasons (architecture, memory, missing image) stay as a warning. Unreachable Devices stay disabled.
6. Set CPU, memory, disk, and network. Architecture details stay collapsed unless you open them.
7. Create. Provisioning on a member Device is proxied through Home. The phone does not connect to the member’s IP.

Windows on **arm64** Devices uses the `windows-arm64` guest (UEFI, TPM, virtio-win). Windows on **x86_64** is a guest profile in progress (`windows-amd64`); Linux guests already run on both arches.

## Images

- Catalog downloads follow this Device’s architecture. You can still download the other arch when you will deploy it on a matching Device.
- A missing Library copy on the target Device is a placement warning, not a silent skip.
- Optional: set a custom Library directory in **Settings**, and designate a depot Device so others fetch verified image bytes over the agent plane.

## After create

The Workload lives in that Device’s SQLite. Start, stop, and console from the Device detail page. If that Device is unreachable, the dashboard says so — it does not invent counts, and Workloads on other Devices keep running.

## Related

- [Quickstart](/docs/getting-started/quickstart/)
- [Home and pairing](/docs/guides/home-and-pairing/)
- [Changelog](/docs/changelog/)
