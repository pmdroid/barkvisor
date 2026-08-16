# Installation (Linux)

This page covers **Linux** package install (`.deb` / `.rpm` / tarball) and the systemd service.

| Platform | Guide |
|----------|--------|
| **macOS** | **[getting-started-installation.md](getting-started-installation.md)** — `.pkg` / standalone archive |
| **Linux** | This page |

After install, open `http://localhost:7777` (or the host IP) and complete the web setup wizard. Creating your first VM is the same on both platforms — see [Quickstart](getting-started-quickstart.md) and [First launch](getting-started-first-launch.md).

---

## System Requirements

- **Linux on x86_64 (amd64) or aarch64 (arm64)** — install the package that matches the **host** CPU.
- **glibc-based distro** — Ubuntu, Debian, Fedora, Rocky/Alma/RHEL, Arch, and similar.  
  (A Docker image is an alternative if you do not want to install on the host OS.)
- **Disk space:** at least 2 GB free for BarkVisor itself. Plan for additional space for VM disk images. Each cloud image download is typically 500 MB–2 GB; guest disks grow up to the size you allocate.
- **RAM:** 8 GB minimum; 16 GB or more recommended. Each running VM reserves its configured memory from the host.
- **QEMU and firmware from the distro** — unlike macOS, the Linux package does **not** bundle QEMU. The `.deb` / `.rpm` / Arch package **depends on** distro QEMU, UEFI firmware, ISO tools, and `usbutils`, so the package manager installs them with BarkVisor.
- **KVM (recommended)** — `/dev/kvm` readable by the `barkvisor` service user for hardware acceleration. Without KVM, BarkVisor still runs using TCG (slower).

### Distro packages (pulled in by the BarkVisor package)

The BarkVisor package ships the **daemon, web UI (SPA), and Swift runtime**, and **requires**:

| Need | Debian / Ubuntu (typical) | Fedora / RHEL-family | Arch |
|------|---------------------------|----------------------|------|
| QEMU | `qemu-system-x86` / `qemu-system-arm` / `qemu-utils` (or `qemu-kvm`) | `qemu-kvm`, `qemu-img` | `qemu-base` |
| UEFI firmware | `ovmf` / `qemu-efi-aarch64` | `edk2-ovmf` | `edk2-ovmf` |
| Cloud-init seed ISO | `genisoimage` (or `xorriso` / `mkisofs`) | `genisoimage`, `xorriso` | `cdrtools` |
| USB listing | `usbutils` | `usbutils` | `usbutils` |

Installing `barkvisor` with `dpkg`/`apt`, `dnf`/`rpm`, or `makepkg`/`pacman` should install these automatically. If you use a **tarball** without a distro package, install the same packages by hand first.

Optional for Windows guests with TPM: install your distro’s **`swtpm`** package (not a hard dependency).

KVM group membership (after the package creates the `barkvisor` user):

```sh
ls -l /dev/kvm
sudo usermod -aG kvm barkvisor
sudo systemctl restart barkvisor.service
```

---

## Installing from Package

1. Download the matching asset from the [releases page](https://github.com/pmdroid/barkvisor/releases):

   | Host arch | Prefer |
   |-----------|--------|
   | x86_64 | `barkvisor_*_amd64.deb`, `barkvisor-*.x86_64.rpm`, or `barkvisor-*-linux-x86_64.tar.gz` |
   | aarch64 | `barkvisor_*_arm64.deb`, `barkvisor-*.aarch64.rpm`, or `barkvisor-*-linux-aarch64.tar.gz` |

2. Install with the steps for your format below.
3. Enable and start the service (if the package did not already):
   ```sh
   sudo systemctl enable --now barkvisor.service
   ```
4. Open `http://localhost:7777` (or `http://<host-ip>:7777`) and complete setup.

### Debian / Ubuntu (`.deb`)

```sh
sudo dpkg -i barkvisor_*_amd64.deb    # or *_arm64.deb
# if dpkg reports missing deps:
sudo apt-get install -f -y
sudo systemctl enable --now barkvisor.service
```

### Fedora / Rocky / Alma / RHEL (`.rpm`)

```sh
sudo dnf install -y ./barkvisor-*.rpm
# or: sudo rpm -Uvh barkvisor-*.rpm
sudo systemctl enable --now barkvisor.service
```

### Tarball (any glibc host)

```sh
tar -xzf barkvisor-*-linux-*.tar.gz
cd barkvisor-*-linux-*
sudo ./install.sh
sudo systemctl enable --now barkvisor.service
```

### Arch

Use the `PKGBUILD` from a package build (`makepkg -si`), or the tarball + `install.sh` above.

### Installing over SSH

BarkVisor is a headless daemon with no GUI dependencies, so it can be installed entirely over SSH on a remote Linux host:

```sh
scp barkvisor_*_amd64.deb user@remote-linux:~/
ssh user@remote-linux 'sudo dpkg -i ~/barkvisor_*_amd64.deb && sudo systemctl enable --now barkvisor.service'
```

After installation, open `http://<remote-linux-ip>:7777` in a browser to complete the web-based setup.

### systemd

The package installs `barkvisor.service` and an environment file at `/etc/barkvisor/barkvisor.env`.

```sh
systemctl status barkvisor.service
journalctl -u barkvisor.service -f
curl -sS http://127.0.0.1:7777/api/health
```

Common overrides in `/etc/barkvisor/barkvisor.env`:

| Variable | Default | Effect |
|----------|---------|--------|
| `BARKVISOR_PORT` | `7777` | HTTP listen port |
| `BARKVISOR_DATA_DIR` | `/var/lib/barkvisor` | Data directory |
| `BARKVISOR_FRONTEND_DIR` | (share path) | Override SPA location if needed |
| `BARKVISOR_JOIN_CODE` | (unset) | Pairing offer on **first boot** only (ignored after setup or an existing pair) |
| `LD_LIBRARY_PATH` | set by package | Swift runtime + optional compat shims |

After edits: `sudo systemctl restart barkvisor.service`.

The unit does **not** enable `NoNewPrivileges` so QEMU can run setuid `qemu-bridge-helper` for bridged networking. Do not re-harden the unit with `NoNewPrivileges=true` if you need bridging.

---

## API-only Device (no SPA)

Release packages still bundle the SPA by default. The daemon is the same binary either way — there is no separate controller or worker process.

To install **API-only** from a source checkout, even if `frontend/dist` exists:

```sh
sudo SKIP_FRONTEND=1 ./scripts/install-linux.sh
```

Join a Home **from that Device** (console-local `POST http://127.0.0.1:7777/api/pairing/join` — not through Home):

```sh
# After the daemon is up:
barkvisor join --code 'barkvisor://pair/v1?…'
```

Or set `BARKVISOR_JOIN_CODE` in `/etc/barkvisor/barkvisor.env` before first boot. If the other Device is unreachable, this Device still starts and keeps local SQLite.

Paste the full pairing offer (`barkvisor://pair/v1?…`) issued on the other Device (Settings → Home → Add a Device). The short code alone is not enough.

Then manage Workloads from the other Device’s SPA. See [Product terminology](product-terminology.md) and [First launch](getting-started-first-launch.md).

---

## What Gets Installed

BarkVisor is installed as a system daemon under `/usr/local/`. The install layout:

```
/usr/local/
  bin/
    barkvisor                         # Main server daemon
  lib/
    barkvisor/
      swift/                          # Bundled Swift runtime
      compat/                         # Optional SONAME shims
  share/
    barkvisor/
      frontend/
        dist/
          index.html                  # Vue.js single-page application
          assets/                     # JS, CSS, and other frontend assets
/etc/
  barkvisor/
    barkvisor.env                     # Port, data dir, library path
/usr/lib/systemd/system/              # or /usr/local/lib/systemd/system/
  barkvisor.service                   # systemd unit
/var/lib/
  barkvisor/                          # Data directory (created on install / first run)
/var/run/
  barkvisor/                          # Short unix socket directory
```

**QEMU, OVMF/AAVMF, ISO tools, and usbutils** are **not** bundled inside the BarkVisor payload; they are **required distro packages** declared in the package metadata (see System Requirements). On Rocky/Alma/RHEL the QEMU binary is often only `/usr/libexec/qemu-kvm`; BarkVisor resolves that path.

---

## Data Directory

On first launch, BarkVisor creates its data directory. For installed daemon builds:

```
/var/lib/barkvisor/
```

For development builds (`swift run`), the data directory is `~/.local/share/barkvisor/`.

This path is determined by `Config.dataDir` (overridable with `BARKVISOR_DATA_DIR`). The directory contains:

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

Additionally, short-lived unix sockets for QMP communication are stored in a shorter directory to stay within the unix socket path limit. For installed builds, this is `/var/run/barkvisor/`; for dev builds, a temp directory under `$TMPDIR`.

---

## Uninstalling

1. Stop and disable the service:
   ```sh
   sudo systemctl disable --now barkvisor.service
   ```
2. Remove the package (or installed files):

   **Debian / Ubuntu:**
   ```sh
   sudo dpkg -r barkvisor
   # purge config as well:
   # sudo dpkg -P barkvisor
   ```

   **Fedora / Rocky / Alma / RHEL:**
   ```sh
   sudo dnf remove barkvisor
   # or: sudo rpm -e barkvisor
   ```

   **Manual / tarball layout:**
   ```sh
   sudo rm -f /usr/local/bin/barkvisor
   sudo rm -rf /usr/local/lib/barkvisor /usr/local/share/barkvisor
   sudo rm -f /usr/lib/systemd/system/barkvisor.service \
              /usr/local/lib/systemd/system/barkvisor.service
   sudo rm -rf /etc/barkvisor
   sudo systemctl daemon-reload
   ```

3. **(Optional)** Remove the data directory to delete all VMs, disk images, and configuration:
   ```sh
   sudo rm -rf /var/lib/barkvisor /var/run/barkvisor
   ```

---

## Upgrading

1. Install the new package the same way as a fresh install (`dpkg -i`, `dnf install`, or tarball `install.sh`).  
   Package scripts typically leave the service enabled; restart if needed:
   ```sh
   sudo systemctl restart barkvisor.service
   ```
2. Confirm the service is healthy:
   ```sh
   systemctl status barkvisor.service
   curl -sS http://127.0.0.1:7777/api/health
   ```

Your data directory is preserved across upgrades. Database migrations run automatically on startup — BarkVisor uses GRDB's `DatabaseMigrator`, which tracks which migrations have already been applied and only runs new ones. No manual intervention is required.

---

## Bridged networking (optional)

NAT works out of the box. Bridged mode uses a **host bridge** plus QEMU’s `qemu-bridge-helper` (no BarkVisor XPC helper on Linux).

```sh
# Example: bridge br0 with physical NIC eth0
sudo ip link add name br0 type bridge
sudo ip link set br0 up
sudo ip link set eth0 master br0
# Configure IP/DHCP on br0 as appropriate for your network

echo 'allow br0' | sudo tee /etc/qemu/bridge.conf
# Ensure the helper is setuid (path varies by distro):
#   /usr/lib/qemu/qemu-bridge-helper
#   /usr/libexec/qemu-bridge-helper
sudo chmod u+s /usr/lib/qemu/qemu-bridge-helper 2>/dev/null || true
```

In the UI: **Networks** → create a **bridged** network with interface `br0`.

---

## Docker (optional)

```sh
docker build -t barkvisor:dev -f Dockerfile .
docker run --rm -it --device /dev/kvm -p 7777:7777 barkvisor:dev
# Without KVM (TCG):
docker run --rm -it -p 7777:7777 barkvisor:dev
```

Open `http://localhost:7777`. For production hosts, prefer the package + systemd install above.

---

## Building from source (optional)

End users should use release packages. To build and run from a git checkout (contributors), see [Development](getting-started-development.md) and:

```sh
./scripts/linux-dev.sh
source scripts/lib/linux-swift-compat.sh && barkvisor_export_swift_env
swift run BarkVisorApp
```

To produce `.deb` / `.rpm` / tarball artifacts:

```sh
./scripts/build-linux-packages.sh
# or from macOS: ./scripts/build-linux-packages.sh --docker
```
