# Installation (Linux)

This page is the Ubuntu / Debian appliance. Install the matching `.deb`. The Device daemon runs as **root**. Other distros (Arch, SteamOS, Fedora) and no-root hosts: see [Other distros: portable tarball, no root](#other-distros-portable-tarball-no-root).

This milestone is **Ubuntu / Debian `.deb`** and **macOS `.pkg`**. Not rpm, not Fedora, not Arch as the operator channel. Packaging still knows how to emit those formats for builders. See [Building releases](getting-started-building-releases.md).

| Platform | Guide |
|----------|--------|
| **macOS** | **[getting-started-installation.md](getting-started-installation.md)** — Apple Silicon `.pkg` |
| **Linux** | This page |
| **Windows** | **[getting-started-windows.md](getting-started-windows.md)** — zip, QEMU, Windows Hypervisor Platform |

After install, open `http://localhost:7777` (or the Device IP) and finish the web setup. First Workload: [Quickstart](getting-started-quickstart.md) and [First launch](getting-started-first-launch.md). Words: **Home**, **Device**, **Workload**, **Library**. See [Product terminology](product-terminology.md).

## Bootstrap (inspect, then run)

Do not pipe a script into `sudo bash`. Download it, read it, then run it.

```sh
curl -fsSL https://raw.githubusercontent.com/pmdroid/barkvisor/main/scripts/get-barkvisor.sh -o get-barkvisor.sh
less get-barkvisor.sh
sudo bash get-barkvisor.sh
```

SSH / non-TTY:

```sh
sudo bash get-barkvisor.sh --yes
```

The script picks the matching GitHub release `.deb` (`amd64` or `arm64`), checks the `.sha256` sidecar, then `dpkg -i` and enables root `barkvisor.service`. It waits for `/api/health`. Fedora is refused. It never runs `sudo brew`.

## System requirements

- **Ubuntu or Debian** on x86_64 (amd64) or aarch64 (arm64). Install the `.deb` that matches this Device.
- **Disk space:** at least 2 GB for BarkVisor. Plan more for guest disks. Cloud images are typically 500 MB to 2 GB.
- **RAM:** 8 GB minimum; 16 GB or more recommended. Each running Workload reserves its configured memory.
- **QEMU and firmware from the distro.** The `.deb` depends on distro QEMU, UEFI firmware, ISO tools, and `usbutils`. They are not bundled inside the BarkVisor payload.
- **KVM (recommended)** — `/dev/kvm` for the dropped QEMU user. Without KVM, guests run under TCG (slower). The Device daemon itself is root.

Typical `.deb` dependencies:

| Need | Debian / Ubuntu |
|------|-----------------|
| QEMU | `qemu-system-x86` / `qemu-system-arm` / `qemu-utils` (or `qemu-kvm`) |
| UEFI firmware | `ovmf` / `qemu-efi-aarch64` |
| Cloud-init seed ISO | `genisoimage` (or `xorriso` / `mkisofs`) |
| USB listing | `usbutils` |

Optional for Windows guests with TPM: distro **`swtpm`**.

Optional for Application Workloads: **Docker Engine** and **Compose v2** (`docker-ce` or `docker.io`, plus `docker-compose-v2`). BarkVisor does not install Docker. Missing Docker is a doctor warning, not a failure — VMs still run.

Optional for off-LAN access: **Tailscale** from your distro or [tailscale.com/download](https://tailscale.com/download). BarkVisor can advertise the tailnet address. It does not bundle Tailscale. See [Home and pairing](home-and-pairing.md#remote-access-tailscale).

The unit uses `SupplementaryGroups=kvm`. When group **disk** exists, the package writes `barkvisor.service.d/disk.conf` so dropped QEMU can open `/dev/sdX`.

```sh
ls -l /dev/kvm /dev/sda
sudo usermod -aG kvm,disk barkvisor
sudo systemctl daemon-reload
sudo systemctl restart barkvisor.service
```

## Installing the `.deb`

```sh
sudo dpkg -i barkvisor_*_amd64.deb    # or *_arm64.deb
# if dpkg reports missing deps:
sudo apt-get install -f -y
sudo systemctl enable --now barkvisor.service
```

Open `http://localhost:7777` (or `http://<device-ip>:7777`).

### Installing over SSH

```sh
scp barkvisor_*_amd64.deb user@remote-linux:~/
ssh user@remote-linux 'sudo dpkg -i ~/barkvisor_*_amd64.deb && sudo systemctl enable --now barkvisor.service'
```

### systemd

The package installs `barkvisor.service` and `/etc/barkvisor/barkvisor.env`.

```sh
systemctl status barkvisor.service
journalctl -u barkvisor.service -f
```

The unit is **root**:

- `User=root`
- `Group=barkvisor`
- `ProtectSystem=strict`
- `KillMode=process` (a restart signals only the daemon; running Workloads stay up)

QEMU drops to `barkvisor` / `qemu` with `kvm` / `disk`. Do not set `NoNewPrivileges=true` if you need bridged networking. The packaged unit leaves that off so setuid `qemu-bridge-helper` works.

Common overrides in `/etc/barkvisor/barkvisor.env`:

| Variable | Default | Effect |
|----------|---------|--------|
| `BARKVISOR_PORT` | `7777` | HTTP listen port |
| `BARKVISOR_DATA_DIR` | `/var/lib/barkvisor` | Data directory |
| `BARKVISOR_FRONTEND_DIR` | (share path) | Override SPA location if needed |
| `BARKVISOR_JOIN_CODE` | (unset) | Pairing offer on **first boot** only |
| `LD_LIBRARY_PATH` | set by package | Swift runtime + optional compat shims |

After edits: `sudo systemctl restart barkvisor.service`.

## API-only Device (no SPA)

Packages ship two binaries. One process per Device. Do not enable both units.

| Binary | systemd unit | Use |
|--------|--------------|-----|
| `/usr/local/bin/barkvisor` | `barkvisor.service` | Home Device with the web UI |
| `/usr/local/bin/barkvisor-agent` | `barkvisor-agent.service` | API-only worker Device (no SPA) |

`barkvisor-agent` is a symlink to the same ELF. Invoking that name skips the SPA even if `frontend/dist` is on disk. Default package install enables `barkvisor.service`.

From a package, switch to API-only:

```sh
sudo systemctl disable --now barkvisor.service
sudo systemctl enable --now barkvisor-agent.service
```

From a source checkout, skip the SPA copy and enable the agent unit even if `frontend/dist` exists:

```sh
sudo SKIP_FRONTEND=1 ./scripts/install-linux.sh
```

Join a Home **from that Device** (console-local `POST http://127.0.0.1:7777/api/pairing/join`, not through Home):

```sh
barkvisor-agent join --code 'barkvisor://pair/v1?…'
# barkvisor join --code works too
```

Or set `BARKVISOR_JOIN_CODE` in `/etc/barkvisor/barkvisor.env` before first boot. If the other Device is unreachable, this Device still starts and keeps local SQLite.

Paste the full pairing offer (`barkvisor://pair/v1?…`) issued on the other Device (Settings → Pairing → Add a Device). The short code alone is not enough.

Then manage Workloads from the other Device SPA. See [Home and pairing](home-and-pairing.md), [Product terminology](product-terminology.md), and [First launch](getting-started-first-launch.md).

## Other distros: portable tarball, no root

Ubuntu / Debian is the packaged appliance. The release tarball (`barkvisor-<version>-linux-<arch>.tar.gz`) runs on any glibc host with distro QEMU — Arch, SteamOS, Fedora, openSUSE. Without root, install it into your home prefix and run the agent as your user under `systemctl --user`.

### Dependencies (install first)

QEMU, firmware, and ISO tools are distro packages — never bundled:

| Need | Arch / SteamOS | Fedora | Ubuntu / Debian |
|------|----------------|--------|-----------------|
| QEMU system | `qemu-base` (x86_64; aarch64 Arch hosts need `qemu-emulators-full`) | `qemu-kvm` | `qemu-system-x86` |
| Display device modules | `qemu-hw-display-virtio-gpu` + `qemu-hw-display-virtio-gpu-pci` | included | included |
| `qemu-img` | `qemu-base` (x86_64) or the standalone `qemu-img` package | `qemu-img` | `qemu-utils` |
| UEFI firmware | `edk2-ovmf` (x86_64), `edk2-aarch64` (arm64) | `edk2-ovmf` | `ovmf` / `qemu-efi-aarch64` |
| Cloud-init seed ISO | `cdrtools` | `genisoimage` or `xorriso` | `genisoimage` |
| swtpm (Windows guests) | `swtpm` | `swtpm` | `swtpm` |

Arch and SteamOS split QEMU device modules out of `qemu-base`: without `qemu-hw-display-virtio-gpu` and `qemu-hw-display-virtio-gpu-pci`, VM start fails with `'virtio-gpu-pci' is not a valid device model name`. The `.deb` dependency list above does not apply here.

SteamOS only: initialize signing keys before `pacman -S` if pacman reports unknown trust:

```sh
sudo pacman-key --init
sudo pacman-key --populate archlinux holo
```

If SteamOS reports a read-only root filesystem, enable SteamOS developer mode first (`steamos-readonly disable` or `steamos-devmode enable`, depending on the SteamOS version).

### Install the tarball into your home prefix

Do **not** run the tarball's `install.sh` without root — it installs system units and requires root. For a user install:

```sh
tar -xzf barkvisor-<version>-linux-<arch>.tar.gz
mkdir -p ~/.local/opt
mv barkvisor-<version>-linux-<arch> ~/.local/opt/barkvisor-<version>
ln -sfn ~/.local/opt/barkvisor-<version> ~/.local/opt/barkvisor
rm -rf ~/.local/opt/barkvisor/root/usr/local/share/barkvisor/frontend
mkdir -p ~/.local/bin
ln -sf ~/.local/opt/barkvisor/root/usr/local/bin/barkvisor-agent ~/.local/bin/barkvisor-agent
export LD_LIBRARY_PATH=~/.local/opt/barkvisor/root/usr/local/lib/barkvisor/swift:~/.local/opt/barkvisor/root/usr/local/lib/barkvisor/compat
```

Run the binary named **`barkvisor-agent`** — it serves the API without the SPA. Removing the bundled SPA keeps this a **user** install: data lives under `~/.local/share/barkvisor` (or set `BARKVISOR_DATA_DIR`). If the SPA stays on disk, the daemon treats the prefix as an installed appliance and expects `/var/lib/barkvisor`, which your user cannot write. Run it as your user, not with `sudo`.

The `LD_LIBRARY_PATH` export is required for **every** CLI invocation of this binary (doctor, join, the unit below) — the binary links the bundled Swift runtime in that directory and does not embed an rpath for the home prefix.

### systemd user unit

```ini
# ~/.config/systemd/user/barkvisor-agent.service
[Unit]
Description=BarkVisor agent (API-only Device)
After=network-online.target

[Service]
Environment=LD_LIBRARY_PATH=%h/.local/opt/barkvisor/root/usr/local/lib/barkvisor/swift:%h/.local/opt/barkvisor/root/usr/local/lib/barkvisor/compat
ExecStart=%h/.local/opt/barkvisor/root/usr/local/bin/barkvisor-agent serve
Restart=on-failure
RestartSec=3
# Keep running Workloads alive across daemon restarts (matches the packaged unit).
KillMode=process

[Install]
WantedBy=default.target
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now barkvisor-agent.service
loginctl enable-linger "$USER"   # keep running after logout
journalctl --user -u barkvisor-agent.service -f
```

### Verify the host

With the unit running (`/api/health` must answer, or doctor fails `api-health`):

```sh
barkvisor-agent doctor
```

It checks `qemu-img`, the mkisofs-compatible ISO tool, the QEMU device modules (`virtio-gpu-pci`, `virtio-blk-pci`, `qemu-xhci`), and KVM — the same resolvers the daemon uses at VM start. Older builds without these checks report only the QEMU system binary.

Join a Home from this Device (`barkvisor-agent join --code 'barkvisor://pair/v1?…'`, with the `LD_LIBRARY_PATH` export above in your shell), or set `BARKVISOR_JOIN_CODE` in the unit's `Environment=` — first boot only, same semantics as the packaged unit.

Unprivileged means **NAT networking only**: bridged networking (`qemu-bridge-helper`) and VFIO passthrough need root. Doctor's agent-as-user note lists exactly that.

Updates are manual: extract the newer tarball into a fresh versioned directory (`~/.local/opt/barkvisor-<new>`), repoint the `~/.local/opt/barkvisor` symlink with `ln -sfn`, **repeat the SPA removal** from the install step, then `systemctl --user restart barkvisor-agent.service`.

## What gets installed

```
/usr/local/
  bin/
    barkvisor                         # Home Device daemon (SPA + API)
    barkvisor-agent                   # API-only Device (symlink; no SPA)
  lib/
    barkvisor/
      swift/                          # Bundled Swift runtime
      compat/                         # Optional SONAME shims
  share/
    barkvisor/
      frontend/dist/
/etc/
  barkvisor/barkvisor.env
/usr/lib/systemd/system/
  barkvisor.service
  barkvisor-agent.service
/var/lib/barkvisor/
/var/run/barkvisor/
```

QEMU, OVMF/AAVMF, ISO tools, and usbutils are **required distro packages**, not files inside the BarkVisor payload.

## Data directory

Installed appliance:

```
/var/lib/barkvisor/
```

`swift run` uses `~/.local/share/barkvisor/`. Override with `BARKVISOR_DATA_DIR`.

| Path | Purpose |
|------|---------|
| `db.sqlite` | SQLite (users, Workloads, disks, networks, images, templates, audit log) |
| `jwt-secret` | JWT signing secret |
| `disks/` | Guest disks |
| `images/` | Downloaded ISOs and cloud images (Library) |
| `logs/` | Server logs (`BARKVISOR_LOG_DIR` overrides) |
| `logs/vms/` | Per-Workload logs |
| `backups/` | Database backups |
| `cloud-init/` | Seed ISOs (`user-data` + `meta-data` only) |
| `efivars/` | UEFI NVRAM |
| `monitor/` | QMP sockets |
| `tus-uploads/` | Resumable uploads |
| `pids/` | QEMU PID files |
| `console/` | Serial sockets |

Short unix sockets live under `/var/run/barkvisor/` (installed) or `$TMPDIR` (dev).

## Updates

On a root `.deb` appliance, open **Settings → Updates**. The Device downloads the newer checksummed `.deb` and runs `dpkg -i`, then restarts the unit. `/var/lib/barkvisor` stays put. GRDB migrates on start. `KillMode=process` keeps Workloads up across the daemon restart.

`swift run` and smoke instances do not get this path.

## Uninstalling

```sh
sudo ./scripts/uninstall.sh
```

Or remove the package:

```sh
sudo dpkg -r barkvisor
# purge config as well:
# sudo dpkg -P barkvisor
```

Uninstall and `postrm` strip **marker-tagged** host-bridge files only (`# barkvisor:allow-br0`, `# managed-by: barkvisor`, `90-barkvisor-*`). Foreign `allow` lines and installer netplan stay. Shared `br0` is **never** default-deleted. `--purge` / `--revert` may offer `--remove-bridge`. That flag only deletes a `br0` this Device created.

`--purge` also removes `/var/lib/barkvisor`. Without it, appliance data stays.

## Bridged networking

NAT works out of the box. Bridged mode uses a host `br0` plus QEMU `qemu-bridge-helper`. There is no XPC helper.

Prefer **Networks → Host interfaces → Create → Bridge** on the Device. After Apply, click **Keep changes** within 60 seconds, otherwise the host auto-reverts. Wi-Fi is refused.

Host address on `br0` is DHCP or static for this Device. Configure it in **Networks → Host interfaces** — no terminal needed.

See [Networks](using-networks.md).

## GPU and PCI passthrough (optional)

GPU attach needs IOMMU groups, vfio-pci, and KVM. macOS does not offer VFIO. Setup: [GPU passthrough](getting-started-gpu-passthrough.md).

- The GPU list labels **NVIDIA**, **Intel**, and **AMD**. Multiple cards per vendor stay separate rows.
- Attach/detach a GPU like USB when the Device is ready. Occupancy is the host GPU driver. **In use by host** does not block Attach.
- Passing the host GPU can blank the host display. The UI warns. Attach still works.
- Workload detail also has a **PCI** picker for non-GPU VFIO devices. The boot disk and the last remaining uplink are excluded.

If passthrough is unavailable, the UI says why. Do not invent a macOS VFIO path.

## Host block devices (optional)

Create Disk on Linux can attach a host block device as **raw**. BarkVisor refuses devices the host already uses (mounted filesystems, swap, the data-dir volume). Dropped QEMU needs the **disk** group (`/dev/sdX` is `root:disk`). Install writes `barkvisor.service.d/disk.conf` when that group exists and restarts a running unit. macOS has no block-device option. See [Create a Workload](create-workload.md#disks).

## Docker (optional)

```sh
docker build -t barkvisor:dev -f Dockerfile .
docker run --rm -it --device /dev/kvm -p 7777:7777 barkvisor:dev
# Without KVM (TCG):
docker run --rm -it -p 7777:7777 barkvisor:dev
```

Open `http://localhost:7777`. For a Home Device, prefer the `.deb` + systemd install above.

## Building from source (optional)

End users should use the `.deb`. To build and run from a git checkout, see [Development](getting-started-development.md) and:

```sh
./scripts/linux-dev.sh
source scripts/lib/linux-swift-compat.sh && barkvisor_export_swift_env
swift run BarkVisorApp
```

Package artifacts (builders; `.deb` is the appliance channel):

```sh
./scripts/build-linux-packages.sh
# or from macOS: ./scripts/build-linux-packages.sh --docker
```

### Guest-boot smoke (optional)

From a source checkout, opt-in Gherkin scenarios wrap the existing guest
smoke scripts. They are **not** part of `mise run prepush`.

```sh
mise run guest-smoke        # blank disk (fast)
mise run guest-smoke-real   # Ubuntu cloud image + SSH
mise run host-network-extra-ip  # dummy NIC extra-IP add/remove (Docker on macOS)
```

Expect **minutes on KVM**, or **up to ~15 minutes on TCG**. If
`qemu-system-*` is missing the mapper skips with a clear message. See
[Development, guest-boot BDD](getting-started-development.md#guest-boot-bdd-opt-in-not-prepush).

Optional GitHub Actions guest-boot lanes probe `/dev/kvm` on
`ubuntu-24.04` and can use a self-hosted `linux`/`kvm` runner. They are
**never a required check**. See [Guest-boot CI](ci-kvm-runner.md).
