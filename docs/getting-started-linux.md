# Linux

> **Status (first-class multi-distro):** headless daemon + SPA on supported glibc distros. Create and manage VMs (NAT and bridge), image library (arm64 and x86_64), serial console / VNC, cloud-init, USB passthrough (`lsusb`), **`.deb` / `.rpm` / tarball / Arch** packages, and systemd install. Live flags: `GET /api/system/capabilities`.

This guide covers requirements, the distro matrix, day-one source setup, SPA serve, Docker, packages, systemd install, first guest, networking, and known limits.

## What works on Linux

| Area | Support |
|------|---------|
| Daemon + JWT auth + API | Yes |
| Vue SPA (setup wizard, console, VNC) | Yes (`BARKVISOR_FRONTEND_DIR` or install layout) |
| NAT + port forwards | Yes (default “Default NAT”) |
| Bridged networking | Yes (host bridge + `qemu-bridge-helper`) |
| USB passthrough | Yes (`usbutils` / `lsusb`) |
| Image download (arm64 **and** x86_64) | Yes |
| HAOS / cloud images / ISOs | Yes (UEFI OVMF or AAVMF; KVM when available) |
| Cloud-init seed ISO | Yes (`mkisofs` / `genisoimage` / `xorrisofs`) |
| Acceleration | KVM when `/dev/kvm` is available; otherwise TCG |
| systemd unit install | Yes (`scripts/install-linux.sh`) |
| Docker multi-stage image | Yes |
| Packages | `.deb` / `.rpm` / tarball / Arch; QEMU from distro packages |

## Requirements

| Component | Notes |
|-----------|--------|
| Host OS (native build) | **glibc** Linux: Ubuntu 22.04+, Debian 12+, Arch, Fedora, Rocky/Alma/RHEL **10+** (see matrix) |
| Host OS (runtime only) | Same, **plus Alpine** with a **prebuilt** glibc binary (Alpine is musl — no official Swift toolchain) |
| Arch | `aarch64` or `x86_64` (guest `vmType` should match host capability) |
| Swift | 6.2+ via `./scripts/install-swift-linux.sh` (channel picked per distro) |
| QEMU + firmware | Distro packages via `./scripts/linux-dev.sh` (apt / pacman / apk / dnf) |
| Firmware paths | **x86_64:** OVMF / edk2-ovmf (including Fedora-style `edk2-i386-vars.fd`). **arm64:** AAVMF / edk2-armvirt |
| KVM | `/dev/kvm` readable by the barkvisor user (group `kvm`) for acceleration; otherwise TCG |

### Distro matrix

| Distro | Packages | Native `swift build` | Notes |
|--------|----------|----------------------|--------|
| Ubuntu 22.04–26.04+ | apt | yes | 22.04 → ubuntu2204 channel (glibc ≥ 2.35); 24.04+ → ubuntu2404; 26.04+ adds libxml2 SONAME shims |
| Debian 12+ | apt | yes | **debian12** channel (glibc ≥ **2.36**; bookworm is fine) |
| Arch / Arch ARM | pacman | yes | Ubuntu 24.04 tarball + ncurses/libxml2 compat; Orb images often `ID=archarm` |
| Fedora | dnf | yes | **fedora39** channel (or distro `swift-lang`) |
| Rocky / Alma / RHEL **10** | dnf | yes* | *glibc ≥ 2.38; **fedora39** toolchain; package names use **qemu-kvm** / xorriso |
| Rocky / Alma / RHEL **9** | dnf | **no** (glibc 2.34) | Run a binary built on Fedora 40+ / Ubuntu 24.04+, or Docker |
| Alpine | apk | **no** (musl) | `linux-dev.sh` can install QEMU/OVMF; run a glibc-built binary or Docker |

Swift 6.2 toolchains need a **channel-appropriate** glibc minimum (not a single global 2.38 cut). The installer refuses unsupported hosts with a clear message.

### Environment overrides

| Variable | Effect |
|----------|--------|
| `BARKVISOR_PORT` | Listen port (default `7777`) |
| `BARKVISOR_DATA_DIR` | Data directory (default `~/.local/share/barkvisor` in dev) |
| `BARKVISOR_FRONTEND_DIR` | Absolute path to SPA **`dist/`** that contains `index.html` |
| `BARKVISOR_LOG_DIR` | Optional log directory override |

### Optional nested Linux VM

Any glibc Linux VM or bare metal host works (OrbStack, cloud, etc.). Nested virt often lacks `/dev/kvm` → TCG is slower but fine for smoke:

```bash
# Example OrbStack Ubuntu 24.04 arm64 guest
orb create -a arm64 ubuntu:24.04 barkvisor-dev
orb -m barkvisor-dev
```

Then run `./scripts/linux-dev.sh` and `./scripts/linux-smoke.sh` inside the guest.

## Quick start (from source)

```bash
git clone https://github.com/pmdroid/barkvisor.git
cd barkvisor

# 1. System packages + Swift + SONAME compat (all supported distros)
./scripts/linux-dev.sh
# or only Swift: ./scripts/install-swift-linux.sh
source scripts/lib/linux-swift-compat.sh && barkvisor_export_swift_env
swift --version

# 2. Build + automated smoke (daemon health + capabilities)
./scripts/linux-smoke.sh

# 3. Run (dev data dir: ~/.local/share/barkvisor)
swift run BarkVisorApp
```

On hosts newer than the latest Swift-supported LTS (e.g. Ubuntu **26.04+**), Arch, or similar, the installer uses the nearest official channel and adds library shims under `/usr/local/lib/barkvisor/compat`. Smoke, install, and systemd set `LD_LIBRARY_PATH` when needed.

Open `http://localhost:7777` and complete the setup wizard (or use a guest smoke script below for an API-driven path).

### Frontend SPA (`BARKVISOR_FRONTEND_DIR`)

The API works without a UI, but the setup wizard and VM console need the built Vue SPA:

```bash
./scripts/linux-frontend-serve.sh
export BARKVISOR_FRONTEND_DIR="$(pwd)/frontend/dist"
swift run BarkVisorApp
```

Or build + start in one step:

```bash
./scripts/linux-frontend-serve.sh --run
```

Manual build (bun preferred):

```bash
cd frontend && bun install && bun run build
export BARKVISOR_FRONTEND_DIR="$PWD/dist"
```

Resolution order (`VaporServer.findFrontendDist`):

1. **`BARKVISOR_FRONTEND_DIR`** if it contains `index.html`
2. Installed share path (`Config.frontendDir`)
3. Dev probes: `frontend/dist`, `Sources/BarkVisor/Resources/frontend/dist`

### Optional: Docker (daemon + SPA)

```bash
docker build -t barkvisor:dev -f Dockerfile .
docker run --rm -it --device /dev/kvm -p 7777:7777 barkvisor:dev
# TCG if no KVM:
docker run --rm -it -p 7777:7777 barkvisor:dev
```

Open `http://localhost:7777` — SPA is served from the image share path.

### Packages (.deb / .rpm / tarball / Arch)

Preferred install on supported distros is a **built package** (bundles the
daemon, SPA, Swift runtime libs, and a systemd unit).

| Format | Distros | How to install |
|--------|---------|----------------|
| **`.deb`** | Ubuntu, Debian | `sudo dpkg -i barkvisor_*_amd64.deb` (or `*_arm64.deb`) |
| **`.rpm`** | Fedora, Rocky, Alma, RHEL | `sudo rpm -Uvh barkvisor-*.rpm` or `dnf install ./barkvisor-*.rpm` |
| **`.tar.gz`** | Any glibc host | extract + `sudo ./install.sh` |
| **Arch `PKGBUILD`** | Arch / Arch ARM | `makepkg -si` from the package build output |

Build on a Linux host (or via Docker from macOS):

```bash
# Native (Linux build machine with Swift + dpkg-dev / rpm-build)
swift build -c release --product BarkVisorApp
./scripts/linux-frontend-serve.sh
./scripts/build-linux-packages.sh
# → build/linux-packages/*.deb *.rpm *.tar.gz

# From macOS / any host with Docker (Ubuntu 24.04 builder):
./scripts/build-linux-packages.sh --docker
# or: ./scripts/build-linux-packages-docker.sh

# Subset of formats:
FORMATS=tar,deb VERSION=1.0.0 ./scripts/build-linux-packages.sh
```

CI: workflow **Linux Packages** (`.github/workflows/linux-packages.yml`) builds
artifacts on tag `v*` or manual `workflow_dispatch` (amd64; arm64 when runners
are available).

Packages install under `/usr/local` (same layout as `install-linux.sh`) and
enable `barkvisor.service`. QEMU/OVMF remain **distro packages** (Recommends).

### systemd install from source (root)

```bash
swift build -c release --product BarkVisorApp
./scripts/linux-frontend-serve.sh

DRY_RUN=1 ./scripts/install-linux.sh .build/release/BarkVisorApp
sudo FRONTEND_DIST=./frontend/dist ./scripts/install-linux.sh .build/release/BarkVisorApp
```

| Path | Purpose |
|------|---------|
| `/usr/local/bin/barkvisor` | Daemon (`Config.prefix` → `/usr/local`) |
| `/usr/local/share/barkvisor/frontend/dist` | SPA |
| `/usr/local/lib/barkvisor/swift` | Bundled Swift runtime (packages) |
| `/usr/local/lib/barkvisor/compat` | SONAME shims (libxml2, ncurses, …) |
| `/etc/barkvisor/barkvisor.env` | Port / data / `LD_LIBRARY_PATH` |
| `/var/lib/barkvisor` | Data + DB |
| `barkvisor.service` | systemd unit |

```bash
journalctl -u barkvisor.service -f
systemctl status barkvisor.service
```

## First guest

A default NAT network (**Default NAT**) is seeded on first launch. Bridged mode is available when a host bridge exists (see capabilities + Network settings).

### Guest smokes

```bash
# Structural check only (no server)
DRY_RUN=1 ./scripts/linux-guest-smoke.sh

# API path: setup → create NAT VM → start
./scripts/linux-guest-smoke.sh

# With a real cloud image (arm64 or x86_64 URL matching the host)
BARKVISOR_CLOUD_IMAGE_URL='https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img' \
  ./scripts/linux-guest-smoke.sh

# Full boot + cloud-init + SSH (TCG is slow without KVM)
SKIP_BUILD=1 ALLOW_SSH_TIMEOUT=1 ./scripts/linux-real-guest-smoke.sh
```

Create requires `isoId`, `cloudImageId`, or `existingDiskId` — bare `diskSizeGB` alone is rejected. Use a cloud image for a real boot.

### Manual first guest (UI / API)

1. Complete setup (wizard or smoke). Bridged networking is optional and uses a host bridge (no separate helper install).
2. Confirm `GET /api/networks` shows Default NAT (or create a bridged network).
3. Import an image (`POST /api/images/download` or Image Library). Use `arch: "arm64"` or `"x86_64"`.
4. Create a VM with host-matched `vmType` (`linux-arm64` / `linux-amd64`), network, and `cloudImageId` + `diskSizeGB`.
5. Start the VM; open console/VNC.

### Packages by family (if not using `linux-dev.sh`)

**Debian/Ubuntu (example arm64):**

```bash
sudo apt-get install -y qemu-system-arm qemu-utils qemu-efi-aarch64 \
  jq curl ca-certificates openssh-client genisoimage ovmf
```

**Debian/Ubuntu (x86_64):**

```bash
sudo apt-get install -y qemu-system-x86 qemu-utils ovmf \
  jq curl ca-certificates openssh-client genisoimage
```

**Fedora:**

```bash
sudo dnf install -y qemu-system-x86 qemu-img edk2-ovmf genisoimage xorriso
```

**Rocky / Alma / RHEL:**

```bash
sudo dnf install -y qemu-kvm qemu-img edk2-ovmf genisoimage xorriso
# Binary is often only /usr/libexec/qemu-kvm — BarkVisor resolves that path
```

**Arch:**

```bash
sudo pacman -S --needed qemu-base edk2-ovmf cdrtools
```

## Data directories

| Mode | Path |
|------|------|
| Development | `~/.local/share/barkvisor` |
| Installed | `/var/lib/barkvisor` |
| Sockets | `/var/run/barkvisor` (installed) or temp (dev) |

## Capabilities

`GET /api/system/capabilities` (public) typically includes:

| Field | Linux typical |
|-------|----------------|
| `platform` | `Linux` |
| `accelerator` | `kvm` if `/dev/kvm`, else `tcg` |
| `hostArch` | `arm64` / `x86_64` |
| `supportsBridgedNetworking` | `true` (host bridge + qemu-bridge-helper ACL) |
| `supportsManagedBridgeDaemon` | `false` (Linux uses the host bridge path; macOS uses a managed helper) |
| `supportsUSBPassthrough` | `true` (`lsusb` + `usb-host`) |
| `guestTypes` | `linux-arm64`, `linux-amd64`, … |

## Bridged networking (QEMU bridge)

On Linux, bridged networking uses the standard QEMU bridge path (host `br*` + `qemu-bridge-helper`). QEMU is launched with:

```text
-netdev bridge,id=net0,br=<bridge>
-device virtio-net-pci,netdev=net0
```

### Host setup

```bash
# Example: bridge br0 with physical NIC eth0
sudo ip link add name br0 type bridge
sudo ip link set br0 up
sudo ip link set eth0 master br0
sudo ip addr add 192.168.1.10/24 dev br0   # or DHCP on br0

# Allow QEMU's helper to attach taps to br0
echo 'allow br0' | sudo tee /etc/qemu/bridge.conf
sudo chmod u+s /usr/lib/qemu/qemu-bridge-helper   # if not already setuid
# path may be /usr/libexec/qemu-bridge-helper on some distros
```

In the UI: create a **bridged** network with bridge interface `br0`, then attach VMs to it.

## USB passthrough

- Capability `supportsUSBPassthrough` is **true** on Linux.
- Device list from `lsusb` (`usbutils`).
- QEMU: `-device usb-host,vendorid=…,productid=…`.
- Grant access via `plugdev` / udev rules, or sufficient permissions.

```bash
# Debian/Ubuntu
sudo apt-get install -y usbutils
lsusb
```

## Limitations

- Rocky/RHEL **9** and Alpine cannot **build** with official Swift 6.2 toolchains (runtime of a prebuilt binary or Docker is fine).
- Windows guests / TPM may need extra packages (`swtpm`) not covered in the default smoke path.
- Nested virt (OrbStack, many cloud VMs) often has no `/dev/kvm` → slow TCG boots.
- QEMU and firmware come from the distro (package Recommends / `linux-dev.sh`), not a bundled release tree.

## Related scripts

| Script | Purpose |
|--------|---------|
| `scripts/linux-dev.sh` | Distro packages + Swift install (multi-distro) |
| `scripts/install-swift-linux.sh` | Official Swift tarball + channel selection |
| `scripts/lib/linux-distro.sh` | Distro detect, package install, glibc gates |
| `scripts/lib/linux-swift-compat.sh` | SONAME shims + `LD_LIBRARY_PATH` |
| `scripts/linux-smoke.sh` | Build + health / capabilities |
| `scripts/linux-guest-smoke.sh` | Setup + NAT VM create/start |
| `scripts/linux-real-guest-smoke.sh` | Cloud-image boot + cloud-init + SSH |
| `scripts/linux-frontend-serve.sh` | Build SPA; `--verify` / `--run` / `--install-dev` |
| `scripts/install-linux.sh` | systemd install from a local binary |
| `scripts/build-linux-packages.sh` | Build `.deb` / `.rpm` / `.tar.gz` / Arch PKGBUILD |
| `scripts/build-linux-packages-docker.sh` | Same via Docker (macOS-friendly) |
| `packaging/linux/` | Package metadata (debian control, rpm spec, unit, env) |

## Agent / historical notes

Older port milestones and branch lists live in `docs/agent-handoff-linux-port.md`. Prefer **this guide** and `GET /api/system/capabilities` for current product behavior.
