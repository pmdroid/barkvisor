# Installation (macOS)

This page covers **macOS** package install (Apple Silicon `.pkg` / standalone archive).

| Platform | Guide |
|----------|--------|
| **macOS** | This page |
| **Linux** | **[getting-started-linux.md](getting-started-linux.md)** — `.deb` / `.rpm` / tarball + systemd |

## System Requirements

- **macOS 26.0 or later** -- enforced via Swift Package Manager platform minimum.
- **Apple Silicon (aarch64 only)** -- BarkVisor bundles `qemu-system-aarch64` compiled with HVF (Hypervisor.framework) support. Intel Macs are not supported for the macOS product package.
- **Disk space:** at least 2 GB free for the application itself. Plan for additional space depending on the number and size of VM disk images you intend to create. Each cloud image download is typically 500 MB -- 2 GB, and user-created disks can grow up to the size you allocate.
- **RAM:** 8 GB minimum; 16 GB or more recommended. Each running VM reserves its configured memory from the host.

## Installing from Package Installer

1. Download the latest `BarkVisor-<version>.pkg` from the releases page.
2. Run the installer: `sudo installer -pkg BarkVisor-<version>.pkg -target /`
3. The installer places files under `/usr/local/` and registers launchd services.

Alternatively, download the standalone `BarkVisor-<version>-standalone.tar.gz` and extract it manually.

### Installing over SSH

BarkVisor is a headless daemon with no GUI dependencies, so it can be installed entirely over SSH on a remote Mac:

```sh
scp BarkVisor-<version>.pkg user@remote-mac:~/
ssh user@remote-mac 'sudo installer -pkg ~/BarkVisor-<version>.pkg -target /'
```

After installation, open `http://<remote-mac-ip>:7777` in a browser to complete the web-based setup.

Off-LAN: install [Tailscale](https://tailscale.com/download) separately. BarkVisor detects `tailscale` and can advertise the tailnet address; it does not bundle the Tailscale app. See [Home and pairing](home-and-pairing.md#remote-access-tailscale).

### Gatekeeper and Notarization

Release builds are code-signed with a Developer ID certificate and notarized with Apple. On first launch, macOS Gatekeeper will verify the notarization ticket. If you see a "cannot be opened" warning (e.g. from an unsigned development build), right-click the app and choose **Open**, then confirm.

The app requires the following entitlements:

- `com.apple.security.hypervisor` -- required by QEMU to use Apple's Hypervisor.framework for hardware-accelerated virtualization.
- `com.apple.security.network.server` -- the built-in web server listens on port 7777.
- `com.apple.security.network.client` -- used for repository sync, image downloads, and outbound VM networking.

## What Gets Installed

BarkVisor is installed as a system daemon under `/usr/local/`. The install layout:

```
/usr/local/
  bin/
    barkvisor                   # Main server daemon
  libexec/barkvisor/            # unused for QEMU (Homebrew); leftover-safe
  lib/barkvisor/
    *.dylib                     # daemon dylibs if any
  share/barkvisor/
    templates.json              # Built-in VM template catalog
    frontend/
      dist/
        index.html              # Vue.js single-page application
        assets/                 # JS, CSS, and other frontend assets
/Library/
  LaunchDaemons/
    dev.barkvisor.plist              # launchd plist for the main daemon
```

QEMU, swtpm, and socket_vmnet are **not** in the pkg. Install them with Homebrew before starting Workloads:

```sh
brew install qemu swtpm socket_vmnet
sudo brew services start socket_vmnet   # only if you want bridged/vmnet
```

BarkVisor does not ship a privileged helper. Bridged/vmnet attaches to the Homebrew `socket_vmnet` service. NAT Workloads do not need that service.

## Data Directory

On first launch, BarkVisor creates its data directory. For installed daemon builds, the data directory is:

```
/var/lib/barkvisor/
```

For development builds (`swift run`), the data directory is `~/Library/Application Support/BarkVisor/`.

This path is determined by `Config.dataDir` based on whether the binary is running from an installed layout or a development build. The directory contains:

| Path | Purpose |
|------|---------|
| `db.sqlite` | SQLite database (users, VMs, disks, networks, images, templates, audit log, etc.) |
| `jwt-secret` | 256-bit random secret for signing JWT tokens. Auto-generated on first launch. |
| `disks/` | VM disk images (qcow2 and raw). |
| `images/` | Downloaded OS images (ISOs and cloud images). |
| `logs/` | Server log files. Override with the `BARKVISOR_LOG_DIR` environment variable. |
| `logs/vms/` | Per-VM log files. |
| `backups/` | Automatic and manual database backups. Configurable location via Settings. |
| `cloud-init/` | Generated cloud-init seed ISOs. |
| `efivars/` | Per-VM UEFI variable stores (NVRAM). |
| `monitor/` | QEMU monitor (QMP) unix sockets. |
| `tus-uploads/` | Temporary storage for resumable file uploads (tus protocol). |
| `pids/` | PID files for running QEMU processes. |
| `console/` | Serial console unix sockets. |

Additionally, short-lived unix sockets for QMP communication are stored in a shorter directory to stay within the 104-byte unix socket path limit. For installed builds, this is `/var/run/barkvisor/`; for dev builds, `$TMPDIR/barkvisor/`.

## Uninstalling

1. Stop the daemon: `sudo launchctl bootout system/dev.barkvisor`
2. Remove installed files:
   ```
   sudo rm -f /usr/local/bin/barkvisor
   sudo rm -rf /usr/local/libexec/barkvisor /usr/local/lib/barkvisor /usr/local/share/barkvisor
   sudo rm -f /Library/LaunchDaemons/dev.barkvisor.plist
   ```
3. **(Optional)** Remove the data directory to delete all VMs, disk images, and configuration:
   ```
   sudo rm -rf /var/lib/barkvisor
   ```
4. **(Optional)** Remove a leftover privileged helper from older installs:
   ```
   sudo launchctl bootout system/dev.barkvisor.helper
   sudo rm -f /Library/LaunchDaemons/dev.barkvisor.helper.plist
   sudo rm -f /Library/PrivilegedHelperTools/dev.barkvisor.helper
   ```

## Upgrading

Preferred on macOS with Homebrew:

```sh
brew upgrade barkvisor
sudo brew services restart barkvisor
```

From a `.pkg` or standalone archive:

1. Stop the daemon: `sudo launchctl bootout system/dev.barkvisor`
2. Install the new version using the `.pkg` installer or by extracting the standalone archive.
3. Start the daemon: `sudo launchctl bootstrap system /Library/LaunchDaemons/dev.barkvisor.plist`

Your data directory is preserved across upgrades. Database migrations run automatically on startup -- BarkVisor uses GRDB's `DatabaseMigrator`, which tracks which migrations have already been applied and only runs new ones. No manual intervention is required.

Older installs may still have `dev.barkvisor.helper`. New builds do not use it; remove it with the uninstall steps above.
