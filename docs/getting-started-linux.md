# Install on Linux

On Ubuntu or Debian, install the prebuilt `.deb` package. This includes the web console and supports updates from Settings.

Other Linux distributions can use the [portable tarball](#other-distros-portable-tarball-no-root). You do not need Swift, Bun, or a source checkout to run a release package.

## System requirements

- Ubuntu or Debian on amd64 or arm64 for the `.deb`.
- Enough memory for the Device and every VM you plan to run.
- Disk space for downloaded OS images and VM disks.
- KVM access for hardware acceleration. Without KVM, Linux uses slower software emulation.

The package depends on distribution packages for QEMU, UEFI firmware, ISO tools, and USB listing. Installing with APT resolves those dependencies.

Optional software:

- `swtpm` for VM TPM emulation.
- Docker with Compose v2 for [Apps](using-apps.md).
- Tailscale for [remote access](home-and-pairing.md#remote-access-with-tailscale).

## 1. Install the package

Download the `.deb` for your architecture from [Releases](https://github.com/pmdroid/barkvisor/releases). From the download folder:

```sh
sudo apt install ./barkvisor_<version>_amd64.deb
sudo systemctl enable --now barkvisor.service
```

Replace the filename with the one you downloaded. Use the `arm64` package on an ARM64 Device. APT supports [installing a local package](https://wiki.debian.org/AptCLI) and its dependencies.

## 2. Complete setup

Open `http://localhost:7777` on the Device and follow [First launch](getting-started-first-launch.md).

If you are using a browser on another computer, follow [remote setup](getting-started-first-launch.md#set-up-a-remote-device). A raw IP address over HTTP cannot register a passkey.

Then [create your first VM](getting-started-quickstart.md) or [install an App](using-apps.md).

## Updates

Open **Settings → Updates**, click **Check**, then **Apply**. BarkVisor verifies the new package, installs it, and restarts the service. Your data stays in place and running VMs stay up.

## Data and service

The installed data directory is `/var/lib/barkvisor`. It contains the database, images, VM disks, logs, and database backups. Choose an image folder under **Settings → Library**, or a default VM disk folder on the Device page.

BarkVisor runs as a root systemd service. VM processes drop to the configured QEMU user. Service configuration is in `/etc/barkvisor/barkvisor.env`.

To check the service or read its logs:

```sh
systemctl status barkvisor.service
journalctl -u barkvisor.service -f
```

Restart the service after changing its configuration:

```sh
sudo systemctl restart barkvisor.service
```

Use the console's **Stop** action to shut down VMs. Stopping the BarkVisor service alone leaves them running.

## Bridged networking

NAT works without host-network changes. To put a VM on your LAN, open **Networks → Host interfaces → Create → Bridge**.

Choose an unused wired interface, review the changes, and click **Apply**. Click **Keep changes** within 60 seconds or BarkVisor rolls them back. Linux Wi-Fi interfaces cannot be used for this bridge.

See [Networks](using-networks.md) for the full flow.

## GPU, PCI, and physical disks

Linux Devices can pass GPUs and other PCI devices through to VMs. The Device must have IOMMU, vfio-pci, and KVM ready. Follow [GPU passthrough](getting-started-gpu-passthrough.md) before attaching hardware.

The amber **In use by host** label does not block Attach. Review the passthrough guide before selecting a GPU that drives the Device's display.

The disk picker can also attach a raw host block device. BarkVisor excludes mounted disks, swap, and storage the host already uses. The guest can write to an attached physical disk, so choose it carefully.

The package grants the VM user access through the `kvm` and, where available, `disk` groups. If access is denied, check the Device's diagnostic report and [Troubleshooting](getting-started-troubleshooting.md).

## API-only Device (no SPA)

An API-only Device runs workloads but does not serve the web console. Manage it through another paired Device.

The package includes both service definitions. Enable only one:

```sh
sudo systemctl disable --now barkvisor.service
sudo systemctl enable --now barkvisor-agent.service
barkvisor-agent join --code 'barkvisor://pair/v1?…'
```

Replace the URI with a full offer from **Settings → Pairing** on your existing Home. See [Home and pairing](home-and-pairing.md).

## Other distros: portable tarball, no root

Use the release tarball for other compatible glibc distributions or a user installation. QEMU, firmware, and ISO tools still need to be installed on the Device.

| Need | Arch / SteamOS | Fedora | Ubuntu / Debian |
|------|----------------|--------|-----------------|
| QEMU | `qemu-base` on x86_64; `qemu-emulators-full` on arm64 | `qemu-kvm` | `qemu-system-x86` or `qemu-system-arm` |
| Display modules | `qemu-hw-display-virtio-gpu`, `qemu-hw-display-virtio-gpu-pci` | Included | Included |
| Disk tools | `qemu-img` | `qemu-img` | `qemu-utils` |
| UEFI firmware | `edk2-ovmf` or `edk2-aarch64` | `edk2-ovmf` | `ovmf` or `qemu-efi-aarch64` |
| Cloud-init ISO tools | `cdrtools` | `genisoimage` or `xorriso` | `genisoimage` |

Arch splits the display modules from the base QEMU package. If VM startup reports that `virtio-gpu-pci` is not a valid device model, install those modules.

For a system installation, extract the archive and use its `install.sh` as root. For a user installation, use the steps below instead.

### Install in your user folder

Replace the version and architecture placeholders with the downloaded filename:

```sh
tar -xzf barkvisor-<version>-linux-<arch>.tar.gz
mkdir -p ~/.local/opt
mv barkvisor-<version>-linux-<arch> ~/.local/opt/barkvisor-<version>
ln -sfn ~/.local/opt/barkvisor-<version> ~/.local/opt/barkvisor
mkdir -p ~/.local/bin
ln -sf ~/.local/opt/barkvisor/root/usr/local/bin/barkvisor-agent ~/.local/bin/barkvisor-agent
export BARKVISOR_DATA_DIR="$HOME/.local/share/barkvisor"
export BARKVISOR_SOCKET_DIR="$BARKVISOR_DATA_DIR/run"
export LD_LIBRARY_PATH="$HOME/.local/opt/barkvisor/root/usr/local/lib/barkvisor/swift:$HOME/.local/opt/barkvisor/root/usr/local/lib/barkvisor/compat"
```

Keep these environment settings for manual commands such as `doctor` and `join`. Explicit data and socket paths keep the user install from trying to write into system directories. Current release builds find the bundled Swift runtime themselves; the library path also supports older tarballs.

### Start automatically

Create `~/.config/systemd/user/barkvisor-agent.service` with:

```ini
[Unit]
Description=BarkVisor agent
After=network-online.target

[Service]
Environment=BARKVISOR_DATA_DIR=%h/.local/share/barkvisor
Environment=BARKVISOR_SOCKET_DIR=%h/.local/share/barkvisor/run
Environment=LD_LIBRARY_PATH=%h/.local/opt/barkvisor/root/usr/local/lib/barkvisor/swift:%h/.local/opt/barkvisor/root/usr/local/lib/barkvisor/compat
ExecStart=%h/.local/opt/barkvisor/root/usr/local/bin/barkvisor-agent serve
Restart=on-failure
RestartSec=3
KillMode=process

[Install]
WantedBy=default.target
```

Enable it:

```sh
systemctl --user daemon-reload
systemctl --user enable --now barkvisor-agent.service
loginctl enable-linger "$USER"
```

With the service running, use `~/.local/bin/barkvisor-agent doctor` to check the runtime, then [join your Home](home-and-pairing.md). Your user needs access to `/dev/kvm` for acceleration. Use NAT; bridge management and VFIO passthrough require root.

To update, extract a new release into a new versioned folder, repoint the `~/.local/opt/barkvisor` symlink, and restart the user service. Keep the data directory.

## Uninstalling

Remove the package:

```sh
sudo apt remove barkvisor
```

Application data under `/var/lib/barkvisor` remains. Do not delete it unless you also want to remove the VMs and images stored there. Package cleanup removes only networking configuration marked as managed by BarkVisor; shared bridges remain.

The repository's `scripts/uninstall.sh` provides additional cleanup options. Its `--purge` option deletes application data.

## Automated installation

The bootstrap script downloads and verifies the matching Ubuntu or Debian package:

```sh
curl -fsSL https://raw.githubusercontent.com/pmdroid/barkvisor/main/scripts/get-barkvisor.sh -o get-barkvisor.sh
less get-barkvisor.sh
sudo bash get-barkvisor.sh
```

Use `--yes` for an unattended install.

## Building from source (optional)

Contributor instructions are in [Development](getting-started-development.md) and [Building releases](getting-started-building-releases.md). Package installation is the recommended way to run BarkVisor.
