# Create a Workload

A **Workload** is a VM or App running on one **Device**. This guide covers VM options. For a first VM, follow the [Quickstart](getting-started-quickstart.md). For Docker Compose apps, see [Apps](using-apps.md).

## From the dashboard

1. Open the Home console (`http://<dashboard-device>:7777`).
2. Click **Create VM**.
3. Pick a template, Windows, or a custom image from the gallery.
4. Name the VM, pick the Device, size, and disk options in the 3-step Create VM dialog (**Gallery → Configure → Disk**).
5. Click **Create** and follow progress in Workloads.

Windows and Linux guest profiles support **arm64** and **x86_64**. Use an image matching the selected Device. Available acceleration and TPM support depend on the Device's platform; Windows Devices do not provide TPM emulation. If Windows 11 setup says the PC must support Secure Boot, see [Troubleshooting](getting-started-troubleshooting.md#windows-setup-this-pc-must-support-secure-boot).

## Images

- Catalog downloads follow this Device’s architecture. You can still download the other arch when you will deploy it on a matching Device.
- A missing Library copy on the target Device is a placement warning, not a silent skip.
- Optional: set a custom Library directory in **Settings**.
- **Settings → Library** and Images show used and free space on the volume containing the image folder. This can be separate from the volume holding VM disks.

## Disks

- New disks use the Device’s default VM disk directory (Device page).
- On **Linux**, Create Disk can attach a host block device as raw. Mounts, swaps, and devices the host already uses stay blocked. The Device’s `barkvisor` user needs the **disk** group (`barkvisor.service.d/disk.conf`). **macOS** has no block-device option.

## GPU and PCI (Linux)

- GPU list labels **NVIDIA**, **Intel**, and **AMD**. Several cards of the same vendor stay listed separately.
- GPU attachment requires IOMMU, vfio-pci, and KVM. The UI explains what is missing if the Device is not ready. See [GPU passthrough](getting-started-gpu-passthrough.md).
- Workload detail also has a **PCI** picker for other VFIO devices. The boot disk and the last remaining uplink stay excluded. The picker is hidden on **macOS**.

## Create App

Docker apps are a separate path: **Workloads → Create App**. See [Apps](using-apps.md).

## After create

Open the VM in Workloads to start, stop, or connect to it. Its data stays on the selected Device. If that Device becomes unreachable, workloads on other Devices keep running.

## Related

- [Apps](using-apps.md)
- [Quickstart](getting-started-quickstart.md)
- [Home and pairing](home-and-pairing.md)
- [Settings: Repositories](settings-repositories.md)
- [Ollama](ollama.md)
- [GPU passthrough](getting-started-gpu-passthrough.md)
- [Changelog](changelog.md)
