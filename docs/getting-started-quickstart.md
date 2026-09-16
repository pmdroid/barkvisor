# Create your first VM

A VM runs on one Device in your Home. See the [glossary](product-terminology.md) for these terms.

Start here after [installing BarkVisor](getting-started-installation.md) and completing [first-run setup](getting-started-first-launch.md). Linux and Windows packages have their own [Linux](getting-started-linux.md) and [Windows](getting-started-windows.md) install guides.

## 1. Choose what to run

Open **Workloads → Create VM**, or click **Create VM** on the Dashboard.

The wizard has three steps: **Gallery → Configure → Disk**. In Gallery, choose:

- A catalog template, such as Ubuntu or Debian, for a preconfigured VM.
- **Windows** for a Windows installer ISO.
- A custom image for your own ISO or cloud image.

If the gallery is empty, open **Settings → Repositories**, sync the image and template catalogs, then reopen Create VM.

## 2. Configure the VM

Enter a name, choose a Device, and pick a size preset. The Device is the computer that will run the VM and store its disk. You can choose a reachable paired Device even if the sidebar is showing a different one.

Fill in any fields the template requires. If it asks for an SSH key, select a saved public key or add one in the form. BarkVisor uses that key to give you access to the guest.

For Windows or a custom image, upload a file or provide its download URL. Use an image that matches the selected Device's architecture: `arm64` or `x86_64`. Wait for the image to finish preparing before continuing.

Under **Advanced**, you can change CPU, memory, network, UEFI, and TPM settings. **Shared (NAT)** is the simplest network for a first VM. Bridged networking needs [bridge setup](using-networks.md) on the Device first.

Click **Next**.

## 3. Choose a disk and create

Choose **New disk** and set its size, or select an unused **Existing disk** on the Device. New qcow2 disks grow as the guest writes data, up to the size you choose.

Linux Devices can also offer **Raw host device**, which gives the guest access to a physical disk. Use a new virtual disk for this walkthrough.

Click **Create**. The Workloads list shows download and provisioning progress. A template can download its image during this step. You do not need to submit the same VM again while it prepares.

## 4. Open the VM

Open the VM from **Workloads**. If it is stopped, click **Start**.

- **VNC** shows the guest's graphical display. Use it to complete an ISO installation.
- **Console** opens the serial terminal, useful for Linux server images configured for serial access.
- **Overview** shows hardware, disks, network details, and guest information when available.
- **Logs** shows events for this VM. **Metrics** appears while it is running.

A cloud image boots an already-installed OS. An ISO starts an installer, so you still need to install the OS onto the VM disk.

## 5. Connect over the network

With NAT, publish a guest port from the VM's network settings. For example, forward host TCP port `2222` to guest port `22` for SSH, then connect to the Device running the VM:

```sh
ssh -p 2222 <guest-user>@<device-address>
```

Replace the placeholders with the guest account and Device address. Use `localhost` only when your terminal is on that Device. Restart a running VM after changing port forwards.

For bridged networking, use the guest's LAN address instead. Installing `qemu-guest-agent` inside the guest lets BarkVisor report its IP addresses and other guest details.

## Stop and manage the VM

**Stop** asks the guest to shut down cleanly. The dropdown also offers **ACPI Shutdown** and **Force Stop**. Force Stop immediately ends the VM process and can lose unsaved work. **Restart** reboots it.

Turn on **Start when this Device boots** if you want automatic startup. Stopping or restarting BarkVisor itself leaves running VMs alive.

For extra disks, shared folders, USB, GPU passthrough, and other options, see [Workload details](using-vm-details.md) and [Create a Workload](create-workload.md). To grow a virtual disk, use [Disks](using-disks.md), then expand the partition and filesystem inside the guest.
