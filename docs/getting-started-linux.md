# Linux

BarkVisor on Linux is a **first-class** headless install: the same daemon + web UI as macOS, with **KVM** acceleration when available (otherwise TCG), **NAT and bridged** networking, USB passthrough, image library, cloud-init, serial console, and VNC.

**Normal path:** install a **prebuilt package** from [GitHub Releases](https://github.com/pmdroid/barkvisor/releases) (`.deb` / `.rpm` / `.tar.gz`). You do **not** need Swift or a source tree to run BarkVisor.

Live host details: `GET /api/system/capabilities` after the service is up.

---

## Install checklist (read this first)

Do these in order on the **host** that will run VMs.

### 1. Machine

- [ ] **x86_64 (amd64)** or **aarch64 (arm64)** Linux host (bare metal or VM)
- [ ] **glibc** distro: Ubuntu, Debian, Fedora, Rocky/Alma/RHEL, Arch, and similar  
  (Docker image is fine if you prefer not to install packages on the host)
- [ ] **sudo** / root for package install and systemd
- [ ] Port **7777/tcp** free (or plan to change `BARKVISOR_PORT`)
- [ ] Enough disk for QEMU images under `/var/lib/barkvisor` (and guest disks)

### 2. Distro packages BarkVisor expects

The BarkVisor package ships the **daemon, SPA, and Swift runtime**.  
**QEMU and firmware** come from the distro (package **Recommends** / manual install below).

Install **one** of these blocks for your family **before or right after** installing BarkVisor:

**Debian / Ubuntu (amd64):**

```bash
sudo apt-get update
sudo apt-get install -y \
  qemu-system-x86 qemu-utils ovmf \
  genisoimage ca-certificates curl \
  usbutils
```

**Debian / Ubuntu (arm64):**

```bash
sudo apt-get update
sudo apt-get install -y \
  qemu-system-arm qemu-utils qemu-efi-aarch64 ovmf \
  genisoimage ca-certificates curl \
  usbutils
```

**Fedora:**

```bash
sudo dnf install -y \
  qemu-system-x86 qemu-img edk2-ovmf \
  genisoimage xorriso usbutils
```

**Rocky / Alma / RHEL:**

```bash
sudo dnf install -y \
  qemu-kvm qemu-img edk2-ovmf \
  genisoimage xorriso usbutils
```

**Arch:**

```bash
sudo pacman -S --needed \
  qemu-base edk2-ovmf cdrtools usbutils
```

Optional for Windows guests with TPM: install your distro’s **`swtpm`** package.

### 3. KVM (recommended)

```bash
# Device should exist on bare metal / VMs with nested virt
ls -l /dev/kvm

# Allow the barkvisor service user to use KVM (package postinst often does this)
sudo usermod -aG kvm barkvisor   # after package install creates the user
# then: sudo systemctl restart barkvisor
```

Without `/dev/kvm`, BarkVisor still runs with **TCG** (slower boots).

### 4. Download the right package

From the release assets, pick the file that matches the **host** CPU:

| Host | Prefer |
|------|--------|
| x86_64 | `*_amd64.deb`, `*.x86_64.rpm`, or `*-linux-x86_64.tar.gz` |
| aarch64 | `*_arm64.deb`, `*.aarch64.rpm`, or `*-linux-aarch64.tar.gz` |

---

## Install the BarkVisor package

### Debian / Ubuntu (`.deb`)

```bash
sudo dpkg -i barkvisor_*_amd64.deb    # or *_arm64.deb
# if dpkg reports missing deps:
sudo apt-get install -f -y
sudo systemctl enable --now barkvisor.service
```

### Fedora / Rocky / Alma / RHEL (`.rpm`)

```bash
sudo dnf install -y ./barkvisor-*.rpm
# or: sudo rpm -Uvh barkvisor-*.rpm
sudo systemctl enable --now barkvisor.service
```

### Tarball (any glibc host)

```bash
tar -xzf barkvisor-*-linux-*.tar.gz
cd barkvisor-*-linux-*
sudo ./install.sh
sudo systemctl enable --now barkvisor.service
```

### Arch

Use the `PKGBUILD` from the release package build output (`makepkg -si`), or the tarball + `install.sh` above.

### Verify

```bash
systemctl status barkvisor.service
curl -sS http://127.0.0.1:7777/api/health
# → {"status":"ok"} (or similar)

journalctl -u barkvisor.service -f
```

Open **`http://<host-ip>:7777`** and complete the setup wizard (admin account).

---

## What gets installed

| Path | Purpose |
|------|---------|
| `/usr/local/bin/barkvisor` | Daemon |
| `/usr/local/share/barkvisor/frontend/dist` | Web UI (SPA) |
| `/usr/local/lib/barkvisor/swift` | Bundled Swift runtime |
| `/usr/local/lib/barkvisor/compat` | Optional library shims |
| `/etc/barkvisor/barkvisor.env` | Port, data dir, `LD_LIBRARY_PATH` |
| `/var/lib/barkvisor` | Database, disks, images, logs |
| `/var/run/barkvisor` | Runtime sockets |
| `barkvisor.service` | systemd unit |

### Config overrides (`/etc/barkvisor/barkvisor.env`)

| Variable | Default | Effect |
|----------|---------|--------|
| `BARKVISOR_PORT` | `7777` | HTTP listen port |
| `BARKVISOR_DATA_DIR` | `/var/lib/barkvisor` | Data directory |
| `BARKVISOR_FRONTEND_DIR` | (share path) | Override SPA location if needed |
| `LD_LIBRARY_PATH` | set by package | Swift runtime + compat shims |

Restart after edits: `sudo systemctl restart barkvisor.service`.

---

## First guest

1. Finish the web setup wizard.
2. A **Default NAT** network is created automatically.
3. Download or upload an image (match host arch: arm64 vs x86_64).
4. Create a VM, start it, use serial console or VNC in the browser.

Guest arch should match the host (`GET /api/system/capabilities` → `hostArch` / `guestTypes`).

### Bridged networking (optional)

NAT works with no extra host setup. Bridged mode uses a **host bridge** + QEMU’s `qemu-bridge-helper`:

```bash
# Example: bridge br0
sudo ip link add name br0 type bridge
sudo ip link set br0 up
sudo ip link set eth0 master br0   # use your physical NIC name
# IP/DHCP on br0 as appropriate for your network

echo 'allow br0' | sudo tee /etc/qemu/bridge.conf
# Ensure helper is setuid (path varies by distro):
#   /usr/lib/qemu/qemu-bridge-helper
#   /usr/libexec/qemu-bridge-helper
sudo chmod u+s /usr/lib/qemu/qemu-bridge-helper 2>/dev/null || true
```

In the UI: **Networks** → create a **bridged** network with interface `br0`.

The packaged systemd unit allows QEMU to run the setuid bridge helper (`NoNewPrivileges` is not enabled). Do not re-harden the unit with `NoNewPrivileges=true` if you need bridging.

### USB passthrough (optional)

```bash
sudo apt-get install -y usbutils   # or distro equivalent
lsusb
```

Grant the `barkvisor` user access (e.g. `plugdev` / udev rules), then attach devices from the VM detail page.

---

## Docker (alternative to a host package)

```bash
docker build -t barkvisor:dev -f Dockerfile .
docker run --rm -it --device /dev/kvm -p 7777:7777 barkvisor:dev
# Without KVM (TCG):
docker run --rm -it -p 7777:7777 barkvisor:dev
```

Open `http://localhost:7777`. Install QEMU **inside** the image is already handled by the Dockerfile runtime stage where applicable; for host networking/USB you will typically use a native package install instead.

---

## Operational notes

- **Acceleration:** KVM when `/dev/kvm` is usable; otherwise TCG (slower). Nested VMs (some clouds, OrbStack) often lack KVM.
- **QEMU/firmware:** distro packages, not bundled inside the BarkVisor `.deb`/`.rpm` (see Recommends / checklist above).
- **Windows + TPM:** install `swtpm` from the distro if you need it.
- **Architecture:** install the package matching the **host** CPU; run guests that match that arch.

There is no separate “Linux feature matrix”: NAT, bridge, USB, images, cloud-init, console, and VNC are all part of the Linux product. Platform differences vs macOS (HVF vs KVM, socket_vmnet vs host bridge, in-app updates) are intentional host design, not incomplete ports — see `GET /api/system/capabilities`.

---

## Development from source (optional)

Only needed if you are **building** BarkVisor yourself. End users should use packages above.

```bash
git clone https://github.com/pmdroid/barkvisor.git
cd barkvisor
./scripts/linux-dev.sh          # distro QEMU/firmware + Swift toolchain
source scripts/lib/linux-swift-compat.sh && barkvisor_export_swift_env
./scripts/linux-smoke.sh        # build + health
swift run BarkVisorApp          # → http://localhost:7777
```

SPA in dev:

```bash
./scripts/linux-frontend-serve.sh --run
```

Release packages from a build machine:

```bash
swift build -c release --product BarkVisorApp
./scripts/linux-frontend-serve.sh
./scripts/build-linux-packages.sh
# or from macOS: ./scripts/build-linux-packages.sh --docker
```

| Script | Purpose |
|--------|---------|
| `scripts/linux-dev.sh` | Dev host packages + Swift |
| `scripts/install-swift-linux.sh` | Official Swift tarball |
| `scripts/linux-smoke.sh` | Build + health smoke |
| `scripts/linux-guest-smoke.sh` | API guest create/start |
| `scripts/linux-frontend-serve.sh` | Build SPA for local runs |
| `scripts/install-linux.sh` | systemd install from a local binary |
| `scripts/build-linux-packages.sh` | `.deb` / `.rpm` / tarball / Arch |
| `packaging/linux/` | Package metadata |

Dev data dir defaults to `~/.local/share/barkvisor` (override with `BARKVISOR_DATA_DIR`).
