# Installation (macOS)

This page is the Apple Silicon appliance. Install the signed `.pkg`. The Device daemon runs as **root**.

This milestone is **Ubuntu / Debian `.deb`** and **macOS `.pkg`**. Not rpm, not Fedora, not a Homebrew keg for the app (`#381` is closed). Homebrew is only for Mac **runtime** `qemu` / `swtpm` / `socket_vmnet`.

| Platform | Guide |
|----------|--------|
| **macOS** | This page |
| **Linux** | **[getting-started-linux.md](getting-started-linux.md)** — Ubuntu / Debian `.deb` + systemd |

After install, open `http://localhost:7777` and finish the web setup. First Workload: [Quickstart](getting-started-quickstart.md) and [First launch](getting-started-first-launch.md). Words: **Home**, **Device**, **Workload**, **Library**. See [Product terminology](product-terminology.md).

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

The script picks the matching GitHub release `.pkg`, checks the `.sha256` sidecar, then `installer -pkg … -target /`. It starts the root LaunchDaemon and waits for `/api/health`. Intel Macs are refused. It never runs `sudo brew` or `brew upgrade barkvisor`.

Pin a release with `--version v1.2.3`. Print the plan with `--dry-run`.

## System requirements

- **macOS 26.0 or later** (Swift Package Manager platform minimum).
- **Apple Silicon only.** Intel Macs are not a product package.
- **Disk space:** at least 2 GB for the app. Cloud images are typically 500 MB to 2 GB; guest disks grow to the size you allocate.
- **RAM:** 8 GB minimum; 16 GB or more recommended. Each running Workload reserves its configured memory.

## Installing from the `.pkg`

If you already have the asset:

```sh
sudo installer -pkg BarkVisor-<version>.pkg -target /
```

The installer places files under `/usr/local/` and loads `dev.barkvisor`. Open `http://<device>:7777`.

### Installing over SSH

```sh
scp BarkVisor-<version>.pkg user@remote-mac:~/
ssh user@remote-mac 'sudo installer -pkg ~/BarkVisor-<version>.pkg -target /'
```

Off-LAN: install [Tailscale](https://tailscale.com/download) yourself. BarkVisor can advertise the tailnet address. It does not bundle Tailscale. See [Home and pairing](home-and-pairing.md#remote-access-tailscale).

### Gatekeeper and notarization

Release builds are Developer ID signed and notarized. If Gatekeeper blocks an unsigned development `.pkg`, open **System Settings → Privacy & Security** and choose **Open Anyway**.

Entitlements on the QEMU/runtime bits:

- `com.apple.security.hypervisor` — HVF
- `com.apple.security.network.server` — listen on `:7777`
- `com.apple.security.network.client` — catalogs, image downloads, guest NAT

## Homebrew runtime (not the app)

The `.pkg` does **not** ship QEMU, swtpm, or socket_vmnet. Install them as your user:

```sh
brew install qemu swtpm socket_vmnet
```

Do not `sudo brew install`. Do not `brew upgrade barkvisor`. The Homebrew keg is not the appliance channel. App updates are [Settings → Updates](settings-updates.md).

The root Device daemon starts `socket_vmnet` through a BarkVisor-owned LaunchDaemon. NAT Workloads do not need that service.

## Root daemon

`/Library/LaunchDaemons/dev.barkvisor.plist` has no `UserName`. The control plane is root. There is no XPC helper and no SMJobBless.

On Linux, QEMU drops to `barkvisor` / `qemu` with `kvm` / `disk`. On macOS, HVF and USB have not been proven after a uid drop, so QEMU stays the daemon uid.

`barkvisor-agent` is a symlink to `barkvisor`. launchd still starts `barkvisor` (SPA). For an API-only Mac, point `Program` at `/usr/local/bin/barkvisor-agent` and join with `barkvisor-agent join --code`. One process per Device.

## What gets installed

```
/usr/local/
  bin/
    barkvisor                   # Home Device daemon (SPA + API)
    barkvisor-agent             # API-only Device (symlink; no SPA)
  libexec/barkvisor/            # unused for QEMU (Homebrew); leftover-safe
  lib/barkvisor/
    *.dylib
  share/barkvisor/
    templates.json
    frontend/dist/
/Library/
  LaunchDaemons/
    dev.barkvisor.plist
```

## Data directory

Installed appliance:

```
/var/lib/barkvisor/
```

`swift run` uses `~/Library/Application Support/BarkVisor/`.

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

Short unix sockets live under `/var/run/barkvisor/` (installed) or `$TMPDIR/barkvisor/` (dev).

## Updates

On a root `.pkg` appliance, open **Settings → Updates**. The Device downloads the newer checksummed `.pkg` and runs `installer -pkg … -target /`, then reloads the LaunchDaemon. `/var/lib/barkvisor` stays put. GRDB migrates on start. Workloads stay up across the daemon restart (`AbandonProcessGroup`).

`swift run`, smoke instances, and a leftover Homebrew keg do not get this path.

Do not `brew upgrade barkvisor`.

## Uninstalling

```sh
sudo ./scripts/uninstall.sh
```

That stops the LaunchDaemon, removes binaries and the plist, strips leftover `dev.barkvisor.helper`, and stops `socket_vmnet` if this Device started it. Appliance data under `/var/lib/barkvisor` stays unless you pass `--purge`.

`--uninstall-socket-vmnet` is the only way the script runs `brew uninstall socket_vmnet`. It never default-deletes a Linux `br0` (see [Linux uninstall](getting-started-linux.md#uninstalling)).

Older leftover helper files:

```sh
sudo launchctl bootout system/dev.barkvisor.helper
sudo rm -f /Library/LaunchDaemons/dev.barkvisor.helper.plist
sudo rm -f /Library/PrivilegedHelperTools/dev.barkvisor.helper
```
