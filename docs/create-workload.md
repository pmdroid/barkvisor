# Create a Workload

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
- **Settings → Library** and the Images page show used/free for that Library path’s volume. It can differ from the data dir. Depot Device offline is an empty/error state, not zeros.

## Disks

- New disks use the Device’s default VM disk directory (**Settings → Disks**). Create Disk can set a different directory per disk.
- On **Linux**, Create Disk can attach a host block device as raw. Mounts, swaps, and devices the host already uses stay blocked. **macOS** has no block-device option.

## GPU and PCI (Linux)

- GPU list labels **NVIDIA**, **Intel**, and **AMD**. Several cards of the same vendor stay listed separately.
- GPU attach is the existing passthrough path (IOMMU / vfio-pci / KVM). Fail closed if that is not ready.
- Workload detail also has a **PCI** picker for other VFIO devices. The boot disk and the last remaining uplink stay excluded. The picker is hidden on **macOS**.

## After create

The Workload lives in that Device’s SQLite. Start, stop, and console from the Device detail page. If that Device is unreachable, the dashboard says so — it does not invent counts, and Workloads on other Devices keep running.

## Related

- [Quickstart](getting-started-quickstart.md)
- [Home and pairing](home-and-pairing.md)
- [Ollama](ollama.md)
- [Changelog](changelog.md)
