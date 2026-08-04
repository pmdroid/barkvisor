<p align="center">
  <img src="website/hero.png" alt="BarkVisor" width="256">
</p>

<h1 align="center">BarkVisor</h1>

> **Alpha Software** -- BarkVisor is under active development. APIs, configuration, and behavior may change rapidly between releases. Use at your own risk and expect breaking changes.

A headless daemon for managing QEMU virtual machines through a web UI.

**Platforms:** **macOS** (`.pkg` / HVF) and **Linux** (packages + systemd / KVM). See [Linux install](docs/getting-started-linux.md).

## Features

- Create, start, stop, and manage VMs with configurable CPU, RAM, disks, and networks
- UEFI boot and TPM 2.0 support
- Cloud-init provisioning with user data templates
- Deploy VMs from templates, synced from remote catalogs
- qcow2/raw disk management with hot-plug and online resize
- NAT networking with port forwarding; **bridged networking** on macOS (socket_vmnet) and Linux (host bridge + qemu-bridge-helper)
- OS image library with HTTP download and auto-decompression (arm64 and x86_64)
- Live CPU, memory, and disk I/O metrics
- Serial console (xterm.js) and VNC display (NoVNC) in the browser
- JWT authentication, API keys, and audit logging
- SSH key management for VM injection
- Database backups, log rotation, and diagnostic bundles
- USB passthrough (macOS and Linux via `usb-host`)

## Prerequisites

### macOS (primary packaging)

- macOS 26+ (Apple Silicon only for HVF guests today)
- Xcode with Swift 6 toolchain
- [Bun](https://bun.sh) (for the frontend)
- Homebrew

Install build dependencies:

```bash
brew install meson ninja pkg-config glib pixman dylibbundler \
  gnutls jpeg-turbo libpng libssh libusb zstd lzo snappy \
  autoconf automake libtool json-glib swiftlint swiftformat
```

### Linux

Install a **prebuilt** `.deb` / `.rpm` / tarball from [Releases](https://github.com/pmdroid/barkvisor/releases), plus distro QEMU/firmware. Full steps and host checklist: **[docs/getting-started-linux.md](docs/getting-started-linux.md)**.

```bash
# Example (Debian/Ubuntu amd64) after installing QEMU/OVMF from the distro:
sudo dpkg -i barkvisor_*_amd64.deb
sudo systemctl enable --now barkvisor.service
# → http://localhost:7777
```

## Quick Start

### 1. Build and run the backend

```bash
swift build
swift run BarkVisorApp
```

The server starts on `http://localhost:7777`. On first launch a web-based setup wizard creates your admin account.

### 2. Run the frontend (development)

```bash
cd frontend
bun install
bun run dev
```

The Vite dev server starts with hot reload, proxying API calls to the backend.

### 3. Production frontend build

```bash
cd frontend
bun run build
```

The built files go into `Sources/BarkVisor/Resources/frontend/` and are served by the backend directly.

## Development

```bash
make build          # swift build
make test           # swift test
make lint           # swiftlint
make format         # swiftformat
make check          # lint + format check (CI)
```

### Frontend E2E tests

```bash
cd frontend
bun run cy:open     # Interactive Cypress
bun run test:e2e    # Headless Cypress
```

## Installation

### macOS

Download the latest `.pkg` from the releases page and install:

```bash
sudo installer -pkg BarkVisor-<version>.pkg -target /
```

This can also be done entirely over SSH on a remote Mac -- no GUI required.

After installation, open `http://<host-ip>:7777` in a browser to complete setup.

To uninstall:

```bash
sudo ./scripts/uninstall.sh          # keep data
sudo ./scripts/uninstall.sh --purge  # remove everything
```

### Linux

Download `.deb` / `.rpm` / `.tar.gz` from the [releases page](https://github.com/pmdroid/barkvisor/releases) and follow the **install checklist** in [docs/getting-started-linux.md](docs/getting-started-linux.md). Building packages from source is optional (same guide, development section).

## Release Build

The release script compiles QEMU, swtpm, socket_vmnet, and xz-utils from source, builds the frontend, compiles the Swift app, assembles the daemon install layout, and creates a `.pkg` installer.

```bash
# Required: Apple Team ID for XPC code-signing verification
export APPLE_TEAM_ID=YOUR_TEAM_ID

# Optional: signing identity for distribution
export SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"

./scripts/build-release.sh
```

Options:

| Flag | Effect |
|------|--------|
| `--skip-deps` | Reuse cached dependency builds |
| `--no-sign` | Skip code signing |
| `--no-pkg` | Skip installer .pkg creation |
| `--require-notarize` | Fail if notarization credentials are missing |

The output is `build/stage/` (install layout), `build/BarkVisor-<version>-standalone.tar.gz`, and `build/BarkVisor-<version>.pkg`.

## Configuration

**macOS:** installed daemon data is under `/var/lib/barkvisor/`; development builds use `~/Library/Application Support/BarkVisor/`.  
**Linux:** development default is `~/.local/share/barkvisor`; installed layout uses `/var/lib/barkvisor` (see Linux guide). Override with `BARKVISOR_DATA_DIR` / `BARKVISOR_PORT` / `BARKVISOR_FRONTEND_DIR`.

| Path | Contents |
|------|----------|
| `db.sqlite` | Application database |
| `jwt-secret` | Auto-generated JWT signing key |
| `disks/` | VM disk images |
| `images/` | Downloaded OS images |
| `logs/` | Application logs |
| `backups/` | Database backups |

The server listens on port **7777** by default, bound to `0.0.0.0`.

## Documentation

**Website** (landing + docs, one deploy): `cd website && bun install && bun run build` → `website/dist/`. Deploy: `bun run deploy` (Cloudflare Pages). See [website/README.md](website/README.md).

### Getting Started (source Markdown)

- [Installation](docs/getting-started-installation.md) — System requirements, pkg install, SSH install, data directory (macOS)
- [Linux](docs/getting-started-linux.md) — Package install checklist, QEMU deps, systemd
- [First Launch and Setup](docs/getting-started-first-launch.md) — Web-based setup, admin account, bridge helper (macOS) vs host bridge (Linux)
- [Quickstart](docs/getting-started-quickstart.md) — Create and run your first VM (arm64 / x86_64)
- [Development Setup](docs/getting-started-development.md) — Build from source, dev workflow, testing
- [Building Releases](docs/getting-started-building-releases.md) — macOS release script + Linux package builds
- [Troubleshooting](docs/getting-started-troubleshooting.md) — Common issues and solutions

## License

MIT License. See [LICENSE](LICENSE) for details.
