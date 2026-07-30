# Linux (experimental)

> **Status:** usable for product smoke. Headless daemon + SPA: create VMs,
> start/stop, console/VNC, images, auth, **bridged networking** (host bridge +
> qemu-bridge-helper), and **USB passthrough** (`lsusb`). **In-app updates**
> remain macOS-only. Check `GET /api/system/capabilities` for live flags.

This document covers day-one use: SPA serve, systemd install, Docker, and a
first NAT guest.

## Requirements

| Component | Notes |
|-----------|--------|
| Host OS (build) | **glibc** Linux: Ubuntu 22.04/24.04/26.04+, Debian 12+, Arch, Fedora. Official Swift tarballs are glibc; newer distros use the nearest supported channel + SONAME shims (`scripts/lib/linux-swift-compat.sh`). |
| Host OS (runtime) | Same as build, **plus Alpine** only with a **prebuilt** binary (Alpine is musl — no official Swift toolchain). Prefer Docker or a glibc build host for Alpine deployments. |
| Arch | `aarch64` or `x86_64` (matches guest types you enable) |
| Swift | 6.2+ — `./scripts/install-swift-linux.sh` picks channel (ubuntu2404 / debian12 / fedora39 / …) |
| QEMU | Distro packages via `./scripts/linux-dev.sh` (apt / pacman / apk / dnf) |
| Firmware | **x86_64:** OVMF (`ovmf` / `edk2-ovmf`). **arm64:** AAVMF / edk2-armvirt |
| KVM | `/dev/kvm` readable by the barkvisor user (add to `kvm` group) |

### Distro matrix

| Distro | Package manager | Native `swift build` | Notes |
|--------|-----------------|----------------------|--------|
| Ubuntu 22.04–26.04+ | apt | yes | 26.04+ uses ubuntu2404 toolchain + libxml2 SONAME shims |
| Debian 12+ | apt | yes | debian12 toolchain channel |
| Arch | pacman | yes | Ubuntu 24.04 toolchain tarball + compat |
| Fedora | dnf | yes | fedora39 channel (or distro `swift-lang`) |
| Alpine | apk | **no** (musl) | Install QEMU/OVMF with `linux-dev.sh`; run a binary built on glibc or use Docker |

### Environment overrides

| Variable | Effect |
|----------|--------|
| `BARKVISOR_PORT` | Listen port (default `7777`) |
| `BARKVISOR_DATA_DIR` | Data directory (default `~/.local/share/barkvisor` in dev) |
| `BARKVISOR_FRONTEND_DIR` | Absolute path to SPA **`dist/`** directory that contains `index.html` |

### OrbStack smoke host

```bash
orb create -a arm64 ubuntu:24.04 barkvisor-u24
orb -m barkvisor-u24
```

## Quick start (from source)

```bash
git clone https://github.com/pmdroid/barkvisor.git
cd barkvisor

# 1. System packages + Swift + SONAME compat (Ubuntu/Debian/Arch/Fedora)
./scripts/linux-dev.sh
# or only Swift: ./scripts/install-swift-linux.sh
source scripts/lib/linux-swift-compat.sh && barkvisor_export_swift_env
swift --version

# 2. Build + automated smoke (daemon health + capabilities)
./scripts/linux-smoke.sh

# 3. Run for real (dev data dir: ~/.local/share/barkvisor)
swift run BarkVisorApp
```

On hosts newer than the latest Swift-supported LTS (e.g. Ubuntu **26.04+**),
or on Arch (no official channel), the installer uses the nearest official
toolchain (usually **ubuntu2404** or **debian12**) and adds library shims under
`/usr/local/lib/barkvisor/compat`. Smoke/install/systemd set `LD_LIBRARY_PATH`.

Open `http://localhost:7777` and complete the setup wizard (or use the guest
smoke script below for an API-driven path).

### Frontend SPA (`BARKVISOR_FRONTEND_DIR`)

The API works without a UI, but the setup wizard and VM console need the built
Vue SPA. Prefer the helper script:

```bash
./scripts/linux-frontend-serve.sh
# prints:
#   SPA dist: /path/to/repo/frontend/dist
#   export BARKVISOR_FRONTEND_DIR="..."

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
# dist is frontend/dist — must contain index.html
export BARKVISOR_FRONTEND_DIR="$PWD/dist"
```

Resolution order inside the daemon (`VaporServer.findFrontendDist`):

1. **`BARKVISOR_FRONTEND_DIR`** if it contains `index.html`
2. Installed share path (`Config.frontendDir`)
3. Dev probes: `frontend/dist`, `Sources/BarkVisor/Resources/frontend/dist`

### Optional: Docker (daemon + SPA)

Multi-stage image: Bun builds `frontend/dist`, Swift builds `BarkVisorApp`,
runtime copies both into the **install layout** (`/usr/local/bin/barkvisor` +
`/usr/local/share/barkvisor/frontend/dist`).

```bash
docker build -t barkvisor:dev -f Dockerfile .
# Prefer KVM when available
docker run --rm -it --device /dev/kvm -p 7777:7777 barkvisor:dev
# TCG fallback (slow) if no /dev/kvm
docker run --rm -it -p 7777:7777 barkvisor:dev
```

Open `http://localhost:7777` — SPA is served from the image share path (no
`BARKVISOR_FRONTEND_DIR` required). KVM passthrough needs nested virt or bare
metal; without it the daemon uses TCG when `/dev/kvm` is missing.

### systemd install (root)

```bash
# 1. Release binary
swift build -c release --product BarkVisorApp

# 2. SPA (optional but recommended for UI)
./scripts/linux-frontend-serve.sh

# 3. Dry-run on Orb (no root / no changes)
DRY_RUN=1 ./scripts/install-linux.sh .build/release/BarkVisorApp

# 4. Install + enable
sudo FRONTEND_DIST=./frontend/dist ./scripts/install-linux.sh .build/release/BarkVisorApp
# Install unit only (do not start yet):
# sudo SKIP_START=1 FRONTEND_DIST=./frontend/dist ./scripts/install-linux.sh ...
```

Layout after install:

| Path | Purpose |
|------|---------|
| `/usr/local/bin/barkvisor` | Daemon (sets `Config.prefix` → `/usr/local`) |
| `/usr/local/share/barkvisor/frontend/dist` | SPA (`Config.frontendDir`) |
| `/usr/local/lib/barkvisor/compat` | SONAME shims for non-LTS Ubuntu (e.g. `libxml2.so.2` → host lib) |
| `/etc/barkvisor/barkvisor.env` | Port / data / `LD_LIBRARY_PATH` overrides |
| `/var/lib/barkvisor` | Data + DB |
| `barkvisor.service` | systemd unit (`EnvironmentFile=-/etc/barkvisor/barkvisor.env`) |

```bash
journalctl -u barkvisor.service -f
systemctl status barkvisor.service
```

## First NAT guest boot

A default NAT network is seeded as **"Default NAT"** (`isDefault: true`) on
first launch. Bridged mode is available when a host bridge exists (see
capabilities + Network settings).

### Automated guest smoke

```bash
# Structural check only (no server):
DRY_RUN=1 ./scripts/linux-guest-smoke.sh

# Full API path: build → setup → create NAT VM → start → assert running/starting
./scripts/linux-guest-smoke.sh

# Bootable guest (recommended): provide a cloud image URL
BARKVISOR_CLOUD_IMAGE_URL='https://example.com/ubuntu-24.04-server-cloudimg-arm64.img' \
  ./scripts/linux-guest-smoke.sh
```

What the script does:

1. Builds `BarkVisorApp` (or reuses `.build/*/BarkVisorApp` with `SKIP_BUILD=1`)
2. Starts the server on a free port with a temp `BARKVISOR_DATA_DIR`
3. Completes setup if needed: `POST /api/setup/admin`, `POST /api/setup/bridge/skip`,
   `POST /api/setup/complete` (skips bridge — required on Linux)
4. Logs in via `POST /api/auth/login` when no setup token was returned
5. `GET /api/networks` and selects the default NAT network
6. Creates a small VM (`linux-arm64` on aarch64, `linux-amd64` on x86_64):
   - **With** `BARKVISOR_CLOUD_IMAGE_URL`: `POST /api/images/download` then
     `POST /api/vms` with `cloudImageId` + ~2 GB disk
   - **Without**: `POST /api/disks` then `POST /api/vms` with `existingDiskId`
     (QEMU start still exercises the NAT guest path; the disk has no OS)
7. `POST /api/vms/:id/start` and checks `GET /api/vms/:id` for `running` or `starting`
8. On failure, prints the server log tail

Useful env vars: `BARKVISOR_ADMIN_USER`, `BARKVISOR_ADMIN_PASSWORD`,
`BARKVISOR_VM_TYPE`, `DISK_SIZE_GB`, `CPU_COUNT`, `MEMORY_MB`, `ALLOW_NO_QEMU=1`.

**Note:** create requires `isoId`, `cloudImageId`, or `existingDiskId` — a bare
`diskSizeGB` alone is rejected by `VMLifecycleService`. Use a cloud image URL
for a real boot, or the blank-disk path for a process/start smoke.

### Manual first guest (API / UI)

1. Complete setup (wizard or smoke script). Skip bridge install on Linux.
2. Confirm `GET /api/networks` shows Default NAT.
3. Import a cloud image (`POST /api/images/download` or Image Library UI).
4. Create a VM with `vmType: "linux-arm64"` (or host-matched type), NAT
   `networkId`, and `cloudImageId` + `diskSizeGB`.
5. Start the VM; open console/VNC from the UI or API.

## Data directories

| Mode | Path |
|------|------|
| Development | `~/.local/share/barkvisor` |
| Installed | `/var/lib/barkvisor` |
| Sockets | `/var/run/barkvisor` (installed) or temp dir (dev) |

## Capabilities

`GET /api/system/capabilities` (public) returns flags such as:

- `supportsBridgedNetworking` — `true` (QEMU `-netdev bridge`; host bridge + helper ACL)  
- `supportsManagedBridgeDaemon` — `false` on Linux (no socket_vmnet XPC lifecycle)  
- `supportsUSBPassthrough` — `true` (`lsusb` + `usb-host`)  
- `supportsInAppUpdate` — `false`  
- `guestTypes` — table of stable `vmType` IDs (linux-arm64, …)  

Managed bridge **daemon** polling runs only on macOS (15s interval). Linux does
**not** run a 5s sysfs bridge-sync loop.
- `accelerator` — `kvm` if `/dev/kvm`, else `tcg`  
- `hostArch` — `arm64` / `x86_64`

## Status on main

The Linux foundation stack (platform helpers, privilege stubs, capabilities UI,
build fixes, docs/Dockerfile, systemd install, product firmware/env/smoke, and
complexity cuts) is **merged to `main`**. Branch from `main` for new work; see
`docs/agent-handoff-linux-port.md` for milestones and follow-up themes.

## Phase A: usable NAT guests

### OrbStack (dev / nested — usually **no** `/dev/kvm`)

```bash
orb -m barkvisor-u24   # Ubuntu 24.04 arm64 recommended
export PATH="$HOME/swift/usr/bin:$PATH"
cd /path/to/barkvisor

# Health + capabilities (accelerator reports tcg without KVM)
./scripts/linux-smoke.sh

# Blank disk: proves QEMU start path
SKIP_BUILD=1 ./scripts/linux-guest-smoke.sh

# Real Ubuntu 24.04 minimal cloud image + cloud-init + SSH port-forward
# TCG boots are slow; ALLOW_SSH_TIMEOUT=1 accepts QEMU running if SSH is late
SKIP_BUILD=1 ALLOW_SSH_TIMEOUT=1 ./scripts/linux-real-guest-smoke.sh
```

Default image URL (override with `BARKVISOR_CLOUD_IMAGE_URL`):

`https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-arm64.img`

### Bare metal / KVM host

```bash
# ensure /dev/kvm is readable (group kvm)
ls -l /dev/kvm
sudo usermod -aG kvm "$USER"   # re-login after

./scripts/linux-real-guest-smoke.sh
# Expect accelerator: kvm and guest SSH within a few minutes
```

### Frontend SPA

```bash
# Build SPA and verify GET / serves HTML
./scripts/linux-frontend-serve.sh --verify

# Or run the daemon with SPA permanently for the session
./scripts/linux-frontend-serve.sh --run

# Dev: copy dist into resource search path
./scripts/linux-frontend-serve.sh --install-dev
```

Env: `BARKVISOR_FRONTEND_DIR=/path/to/frontend/dist`

### Packages (Ubuntu 24.04 arm64)

```bash
sudo apt-get install -y qemu-system-arm qemu-utils qemu-efi-aarch64 \
  jq curl ca-certificates openssh-client genisoimage
# optional: swtpm for Windows/TPM guests later
```

### Capabilities

`GET /api/system/capabilities` (public):

| Field | Linux typical |
|-------|----------------|
| `platform` | `Linux` |
| `accelerator` | `kvm` if `/dev/kvm`, else `tcg` |
| `supportsBridgedNetworking` | `true` (host bridge + qemu-bridge-helper) |
| `supportsUSBPassthrough` | `true` (`lsusb` / `usb-host`) |
| `supportsInAppUpdate` | `false` |

## Roadmap (after Phase A)

- Deb/tarball + systemd E2E install
- x86_64 host + guests
- Managed bridge-daemon lifecycle split (product capability vs macOS XPC)
- Windows guests

## Limitations (MVP)

- Bridged networking needs a host bridge (`br0`) and qemu-bridge-helper ACL (not socket_vmnet)
- USB needs `usbutils` + permissions (udev/plugdev)
- No in-app package updates
- Not full macOS feature parity (no managed bridge helper daemon on Linux)
- Firmware/QEMU still resolved via `PATH` / common distro paths
- Windows guests and TPM may need extra packages (`swtpm`) not covered here
- Image download API currently validates `arch: "arm64"` only

## Related scripts

| Script | Purpose |
|--------|---------|
| `scripts/linux-dev.sh` | Install build + QEMU packages (Ubuntu) |
| `scripts/linux-smoke.sh` | Build + health/capabilities smoke |
| `scripts/linux-guest-smoke.sh` | Setup + NAT VM create/start smoke |
| `scripts/linux-real-guest-smoke.sh` | Cloud-image boot + cloud-init + SSH |
| `scripts/linux-frontend-serve.sh` | Build SPA; `--verify` / `--run` / `--install-dev` |
| `scripts/install-linux.sh` | systemd install (`Resources/barkvisor.service`) |

## Bridged networking (QEMU bridge)

Linux bridging does **not** use socket_vmnet. BarkVisor launches:

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
sudo ip addr add 192.168.1.10/24 dev br0   # or use DHCP on br0

# Allow QEMU's helper to attach taps to br0
echo 'allow br0' | sudo tee /etc/qemu/bridge.conf
sudo chmod u+s /usr/lib/qemu/qemu-bridge-helper   # if not already setuid
# path may be /usr/libexec/qemu-bridge-helper on some distros
```

In the UI: create a **bridged** network with bridge interface `br0`, then attach VMs to it.

## USB passthrough

- Capability `supportsUSBPassthrough` is **true** on Linux.
- Device list comes from `lsusb` (`usbutils` package).
- QEMU uses `-device usb-host,vendorid=…,productid=…` (same as macOS).
- Grant access: add user to `plugdev` / udev rules, or run with sufficient permissions.

```bash
sudo apt-get install -y usbutils
lsusb
```
