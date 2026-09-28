# Install on macOS

Install BarkVisor using the prebuilt `.pkg`. You need macOS 26 or later on an Apple Silicon Mac. Intel Macs are not supported by this package.

For other computers, use the [Linux](getting-started-linux.md) or [Windows](getting-started-windows.md) guide.

## 1. Install the VM runtime

BarkVisor uses QEMU to run virtual machines. Install the runtime packages with Homebrew as your regular user:

```sh
brew install qemu swtpm socket_vmnet
```

Do not run Homebrew with `sudo`. These packages provide the VM runtime, TPM emulation, and bridged networking. You do not need Xcode, Swift, or Bun to install BarkVisor.

Allow space for both downloaded OS images and VM disks. Each running VM also uses the memory you assign to it.

## 2. Install the package

Download the macOS `.pkg` from [Releases](https://github.com/pmdroid/barkvisor/releases), open it, and follow the installer.

The installer starts BarkVisor in the background. There is no terminal command to run after each reboot.

For a remote Mac or a terminal installation:

```sh
sudo installer -pkg BarkVisor-<version>.pkg -target /
```

Replace `<version>` with the downloaded package's version.

## 3. Complete setup

Open `http://localhost:7777` on the Mac. Follow [First launch](getting-started-first-launch.md) to add a passkey and choose an image Library folder.

If you are using another computer's browser, follow [remote setup](getting-started-first-launch.md#set-up-a-remote-device). An HTTP address such as `http://192.168.1.10:7777` cannot register a passkey.

Then [create your first VM](getting-started-quickstart.md).

## Updates

Open **Settings → Updates**, click **Check**, then **Apply** when a newer release is available. BarkVisor verifies and installs the package, then checks BarkDaemon, BarkServer, and the public health endpoint. Your data stays in place and running VMs stay up. A failed restart stays failed after the console reconnects.

Update BarkVisor through this page, not through Homebrew. Homebrew manages the separate runtime packages.

## Data and service

The installed data directory is `/var/lib/barkvisor`. It holds your database, VM disks, images, logs, and database backups. You can choose a different image folder under **Settings → Library**, and a default VM disk folder on the Device page.

BarkDaemon runs as root and owns local management. BarkServer runs under the `barkvisor` UserName and serves the console on port `7777`. NAT networking works without bridge configuration; for a bridge, see [Networks](using-networks.md).

## Uninstalling

The removal script is in the source repository at `scripts/uninstall.sh`. From a checkout, run:

```sh
sudo ./scripts/uninstall.sh
```

This removes the service and application files but keeps your data. Add `--purge` only if you also want to delete `/var/lib/barkvisor`, including its VM disks and images.

Homebrew runtime packages remain installed unless explicitly removed. The script supports `--uninstall-socket-vmnet` to remove socket_vmnet too.

## Automated installation

For repeated or unattended installs, the bootstrap script downloads the matching package and verifies its checksum. Download and inspect it before running:

```sh
curl -fsSL https://raw.githubusercontent.com/pmdroid/barkvisor/main/scripts/get-barkvisor.sh -o get-barkvisor.sh
less get-barkvisor.sh
sudo bash get-barkvisor.sh
```

Use `--yes` for a non-interactive install, `--version v1.2.3` to select a release, or `--dry-run` to inspect the plan.

Contributor instructions are in [Building releases](getting-started-building-releases.md).
