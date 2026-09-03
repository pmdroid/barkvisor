# GPU passthrough (Linux)

GPU attach on a Linux **Device** in the **Home** needs IOMMU groups, the `vfio-pci` module, KVM, and a GPU in an IOMMU group. BarkVisor does not turn IOMMU on, load modules, or edit boot config. **macOS** has no VFIO path.

After the host is ready, attach from **Workload** detail like USB. Device detail reports **Host ready** or the missing piece.

## Firmware

Enable Intel VT-d or AMD-Vi in the firmware. Menus call it VT-d, AMD-Vi, IOMMU, or SVM. Then boot Ubuntu or Debian.

## Intel or AMD kernel flags

Edit `/etc/default/grub`. Keep flags you already have. Add one IOMMU pair.

Intel:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"
```

AMD:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt"
```

Then:

```sh
sudo update-grub
sudo reboot
```

Device detail says why if IOMMU is still off: enable `intel_iommu=on` or `amd_iommu=on`, then reboot.

## vfio-pci

```sh
sudo modprobe vfio-pci
ls /sys/bus/pci/drivers/vfio-pci
ls /sys/module/vfio_pci
ls /dev/vfio/vfio
ls /dev/kvm
```

Persist across reboot:

```sh
echo vfio-pci | sudo tee /etc/modules-load.d/vfio-pci.conf
```

Do not bind vendor:device ids yourself. BarkVisor binds `vfio-pci` when the Workload starts, and unbinds on detach, stop, and delete.

If `/dev/kvm` is missing, install `qemu-kvm`, add the service user to group `kvm`, or enable nested virtualization.

The package installs a udev rule so dropped QEMU (group `kvm`) can open `/dev/vfio/*`.

## Verify groups

```sh
ls /sys/kernel/iommu_groups
find /sys/kernel/iommu_groups -type l | sort
lspci -nnk
```

Zero groups means IOMMU is still off. After a reboot, Workload detail lists each GPU with its group. Other PCI addresses in that group are **group mates**. They pass through with the GPU. The boot disk and the last remaining host uplink stay excluded from the PCI picker.

## Host GPU occupancy

If this Device lists one GPU, passing it through can blank the host display. The UI says so. That warning does not block **Attach**.

**In use by host** means the host GPU driver still owns the card. Occupancy is information, not a blocker. Attach still works. The same card cannot stay host and guest after the Workload starts.

## Attach

On a Linux Device, open a Workload → **GPU passthrough** → **Attach GPU**. Fail closed if IOMMU, vfio-pci, or KVM is missing. The UI states why. macOS always says GPU passthrough is unavailable.

## Related

- [Installation (Linux)](getting-started-linux.md)
- [Create a Workload](create-workload.md)
- [Workload details](using-vm-details.md)
- [Devices](using-devices.md)
