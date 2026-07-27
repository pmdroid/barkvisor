# Linux (experimental)

> **Status:** initial / experimental. BarkVisor on Linux targets a **NAT-only**
> headless daemon: create VMs, start/stop, console/VNC, images, auth. Bridged
> networking, USB passthrough, and in-app updates are **not** supported yet
> (the UI hides them when `GET /api/system/capabilities` reports them off).

## Requirements

| Component | Notes |
|-----------|--------|
| Host OS | Linux (**Ubuntu 24.04 LTS recommended** — matches official Swift tarballs). Ubuntu 26.04 ships `libxml2.so.16` and breaks the Ubuntu 24.04 Swift package. |
| Arch | `aarch64` or `x86_64` (matches guest types you enable) |
| Swift | 6.2+ toolchain for **ubuntu2404** (see [swift.org](https://www.swift.org/install/linux/)) |
| QEMU | Distro package, e.g. `qemu-system-arm` / `qemu-system-x86` + `qemu-utils` |
| KVM | `/dev/kvm` readable by the barkvisor user (add to `kvm` group) |

### OrbStack smoke host

```bash
orb create -a arm64 ubuntu:24.04 barkvisor-u24
orb -m barkvisor-u24
```

## Quick start (from source)

```bash
# 1. Install Swift toolchain (example: extract official tarball into ~/swift)
export PATH="$HOME/swift/usr/bin:$PATH"
swift --version

# 2. System packages (Ubuntu/Debian names vary by release)
sudo apt-get update
sudo apt-get install -y build-essential pkg-config git \
  libcurl4-openssl-dev libxml2-dev libsqlite3-dev libncurses-dev \
  zlib1g-dev libzstd-dev libedit-dev uuid-dev \
  qemu-system-arm qemu-utils   # or qemu-system-x86 on amd64

# 3. Build
git clone https://github.com/pmdroid/barkvisor.git
cd barkvisor
swift build

# 4. Run (dev data dir: ~/.local/share/barkvisor)
swift run BarkVisorApp
```

Open `http://localhost:7777` and complete the setup wizard.

### Optional: Docker

```bash
docker build -t barkvisor:dev -f Dockerfile .
docker run --rm -it --device /dev/kvm -p 7777:7777 barkvisor:dev
```

KVM passthrough requires nested virt or bare metal. Without `/dev/kvm`, QEMU
may fall back slowly or fail depending on config.

## Data directories

| Mode | Path |
|------|------|
| Development | `~/.local/share/barkvisor` |
| Installed | `/var/lib/barkvisor` |
| Sockets | `/var/run/barkvisor` (installed) or temp dir (dev) |

## Capabilities

`GET /api/system/capabilities` (public) returns flags such as:

- `supportsBridgedNetworking` — `false` on Linux for now  
- `supportsUSBPassthrough` — `false`  
- `supportsInAppUpdate` — `false`  
- `accelerator` — `kvm`  
- `hostArch` — `arm64` / `x86_64`

## Stack / PR order

Linux work is stacked for easy rebase:

1. Platform foundation  
2. QEMU + privilege stubs  
3. Capabilities UI  
4. Linux build fixes (if any)  
5. This docs/Dockerfile PR  
6. systemd install PR  

When restacking: rebase each branch onto its parent, force-with-lease, keep PR
`base` pointing at the parent branch (not always `main`).

## Limitations (MVP)

- No bridged networking (use NAT + port forwards)
- No USB passthrough listing
- No in-app package updates
- Firmware/QEMU still resolved via `PATH` / common distro paths
- Windows guests and TPM may need extra packages (`swtpm`) not covered here

## Next steps

- systemd unit: see `Resources/barkvisor.service` and `scripts/install-linux.sh`
- Smoke: create a `linux-arm64` or `linux-amd64` VM with NAT only
