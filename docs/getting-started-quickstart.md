# Quickstart -- Creating Your First VM

This guide walks through downloading an OS image, creating a virtual machine,
connecting to it, and managing its lifecycle in BarkVisor.

## Prerequisites

- BarkVisor is installed and the daemon is running (`sudo launchctl list | grep barkvisor`).
- The server is listening on port 7777 (default).
- At least one OS image is available, or you are ready to download/upload one.
- QEMU is available. Release builds bundle QEMU under `/usr/local/libexec/barkvisor/`. For
  development builds (via `swift run`), install it with `brew install qemu` --
  BarkVisor resolves binaries from the installed prefix first, then Homebrew, then
  `$PATH`.

## Getting an OS Image

BarkVisor supports two image types:

| Type          | Use case                                             |
|---------------|------------------------------------------------------|
| `iso`         | Installer ISO (manual OS install via VNC)            |
| `cloud-image` | Pre-built cloud image (automated via cloud-init)    |

Architecture is always `arm64` (Apple Silicon / QEMU aarch64).

### Downloading from a Repository

1. Open the BarkVisor web UI at `http://localhost:7777`.
2. Navigate to **Images** (or **Registry** if browsing repository catalogs).
3. Browse the available repository images and click **Download**.
4. BarkVisor streams the file from the source URL with a progress indicator
   (SSE-based). If the download fails, it retries automatically up to 4
   attempts with exponential backoff (2 s, 4 s, 8 s).
5. Files ending in `.xz` or `.gz` are decompressed automatically after
   download using `xz` or `gunzip`.

### Uploading an Image (TUS Resumable Upload)

BarkVisor implements the [TUS 1.0.0](https://tus.io/) resumable upload
protocol. The frontend uses `tus-js-client` to upload images in 50 MB chunks.

1. Go to **Images** and click **Upload**.
2. Select a local ISO or cloud image file.
3. Provide a name, image type (`iso` or `cloud-image`), and arch (`arm64`).
4. The upload streams to the server in chunks. If the connection drops, resume
   from where it left off -- the server tracks the byte offset.
5. When the upload completes, the image status transitions to `ready`.

The maximum upload size is 128 GB (`Tus-Max-Size: 137438953472`).

## Creating a VM from the Wizard

Click **Create VM** to open the creation wizard. It walks through the
following steps:

### Step 1: OS Type and Name

- Choose **Linux** or **Windows**. This sets `vmType` to `linux-arm64` or
  `windows-arm64`.
- Enter a VM name (1--128 characters).
- Windows selection automatically adjusts defaults: 4 CPUs, 4096 MB RAM,
  64 GB disk, UEFI on, TPM enabled. It also ensures the VirtIO Windows
  drivers ISO is available (downloading it if needed).

### Step 2: Hardware Configuration

| Setting              | Range / Options                              | Default (Linux) | Default (Windows) |
|----------------------|----------------------------------------------|-----------------|-------------------|
| CPU count            | 1--256                                       | 2               | 4                 |
| Memory (MB)          | 128--1,048,576                               | 1024            | 4096              |
| Display resolution   | e.g. `1280x800`, `1920x1080`                | `1280x800`      | `1280x800`        |
| UEFI boot            | on / off                                     | on              | on                |
| TPM                  | on / off (auto-enabled for Windows)          | off             | on                |

### Step 3: Image Selection

Choose the boot source:

- **ISO mode** -- Select an installer ISO. A blank boot disk is created for
  you. The VM boots from the ISO for a manual install.
- **Cloud image mode** -- Select a cloud image. BarkVisor clones the image
  into a new qcow2 boot disk (resized to your chosen disk size). You can
  optionally configure cloud-init (see below).

### Step 3a: Windows Drivers (Conditional)

If Windows is selected and the VirtIO Windows drivers ISO (`virtio-win.iso`)
is not already downloaded, the wizard prompts you to download it. This ISO is
automatically attached as a secondary drive during VM creation.

### Step 4: Storage

- **New disk** -- Specify the disk size in GB (minimum 1 GB, up to 8,192 GB).
  In ISO mode a blank qcow2 disk is created instantly. In cloud-image mode
  the disk is cloned and resized in a background task.
- **Existing disk** -- Attach an unassigned disk that was previously created.
- **Shared folders** -- Optionally share host directories with the guest via
  virtio-9p.

### Step 5: Networking

- Select an existing network (NAT, bridged, or socket_vmnet). The default
  network is pre-selected.
- **Port forwarding** (NAT only) -- Add TCP/UDP rules mapping a host port to
  a guest port. This is how you reach SSH or other services from the host.

  Example: `TCP 2222 -> 22` forwards host port 2222 to guest port 22.

### Step 6: Cloud-Init (Cloud Image Mode Only)

When using a cloud image, you can provide:

- **SSH public key** -- Select from your stored SSH keys (the default key is
  pre-selected). The key is injected via cloud-init `ssh_authorized_keys`.
- **User data** -- A free-form cloud-init user data script (YAML). Validated
  before submission.

### Step 7: Review and Create

The summary shows all chosen settings and a preview of the equivalent QEMU
command line. Click **Create** to provision the VM.

- **ISO mode**: The VM is created synchronously (status: `stopped`).
- **Cloud image mode**: The VM enters `provisioning` state while a background
  task clones the disk and generates the cloud-init ISO. The API returns
  HTTP 202 with a `taskID` you can poll. Once provisioning completes the VM
  transitions to `stopped`.

## Creating a VM from a Template

Templates are pre-configured VM recipes that include an OS image slug,
hardware defaults, port forwards, and a cloud-init user data template with
fill-in-the-blank inputs.

1. Navigate to **Templates** in the web UI.
2. Browse templates by category and select one.
3. Fill in the required inputs (e.g. hostname, password, SSH key). The
   template defines which inputs are required, their min/max length, and
   default values.
4. Optionally override CPU, memory, disk size, or network.
5. Click **Deploy**.

If the template's image is not yet downloaded locally, BarkVisor
automatically starts the download and returns a `"downloading"` status.
Monitor the image download progress on the Images page; once the image is
ready, deploy again.

If the image is already available, the VM is created immediately through the
same pipeline as the wizard (cloud-image mode with rendered user data).

## Starting a VM and Connecting

### Start

Select the VM and click **Start**. BarkVisor launches a `qemu-system-aarch64`
process with HVF acceleration, UEFI firmware, and all configured devices. The
VM state transitions to `running`.

### VNC (Graphical Console)

Click the **VNC** tab on the VM detail page. BarkVisor embeds a NoVNC client
that connects over a WebSocket to the QEMU VNC socket (proxied through the
server at `/api/vms/:id/vnc`). This gives you a full graphical console in the
browser -- useful for OS installation and desktop environments.

### Serial Console

Click the **Console** tab. BarkVisor embeds an xterm.js terminal that
connects over a WebSocket to the QEMU serial socket at
`/api/vms/:id/console`. This is the primary interface for headless Linux
servers.

### SSH via Port Forwarding

If you configured a port forward (e.g. `TCP 2222 -> 22`), connect from
your host terminal:

```
ssh -p 2222 user@localhost
```

The guest's default IP on a NAT network is `10.0.2.15`. Port forwarding is
configured through QEMU's user-mode networking (`-netdev user,hostfwd=...`).

## Stopping and Managing VMs

### Stop Methods

BarkVisor supports three stop methods, selectable from the stop button
dropdown:

| Method         | Behavior                                                    |
|----------------|-------------------------------------------------------------|
| `guest-agent`  | Sends a shutdown command via `qemu-guest-agent` (graceful). |
| `acpi`         | Sends an ACPI power button event (like pressing the button).|
| `force`        | Immediately terminates the QEMU process (like pulling power).|

The default is `guest-agent`. If the guest agent is not installed, fall back
to `acpi` or `force`.

### Restart

Restart sends a stop followed by a start. The VM must be running.

### Disk Hotplug

You can attach and detach additional disks to a running VM without rebooting:

- **Hot-add**: On the VM detail page, click **Attach Disk**, select an
  unassigned disk, and confirm. The disk is added via QMP `blockdev-add` +
  `device_add`.
- **Hot-remove**: Click the eject icon on an additional disk. The disk is
  removed via QMP `device_del` + `blockdev-del`.

The boot disk cannot be hot-removed.

### Online Disk Resize

Disks can be resized (grow only) from the Disks page via the resize action.
The new size must be at least 1 GB and at most 8,192 GB. After resizing on
the host, the guest OS must expand its filesystem to use the new space (e.g.
`growpart` + `resize2fs` on Linux).

### ISO Attach/Detach

You can attach or detach ISO images on a running VM:

- **Attach ISO**: Adds a virtual CD-ROM drive.
- **Detach ISO**: Removes a specific ISO or all ISOs.

## Monitoring

### Live Metrics

The **Metrics** tab on the VM detail page shows real-time charts powered by
Chart.js:

- **CPU utilization** (percent)
- **Memory usage** (MB)
- **Disk I/O** (read/write bytes per interval)

Metrics are collected every 5 seconds via QMP queries to the running QEMU
process and stored in a 30-minute ring buffer (360 samples). The metrics
stream is delivered to the browser via Server-Sent Events (SSE) at
`/api/vms/:id/state`.

### Guest Information (qemu-guest-agent)

If `qemu-guest-agent` is installed in the guest, the **Overview** tab
displays rich guest info polled by the `MetricsCollector`:

- IP addresses (source: `guest-agent`; falls back to `10.0.2.15` for NAT)
- Hostname
- OS name, version, and ID
- Kernel version and release
- Architecture
- Timezone
- Logged-in users
- Filesystem mount points and usage

Guest info is available at `GET /api/vms/:id/guest-info` and is persisted to
the database for offline reference.
