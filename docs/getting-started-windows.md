# Installation (Windows)

This page is the Windows Device. Install the matching zip (`barkvisor-windows-amd64.zip` or `barkvisor-windows-arm64.zip`). The Device daemon runs as a **LocalSystem** Windows service.

QEMU is **not** in the zip. Enable Windows Hypervisor Platform (WHPX) and install QEMU before BarkVisor. Without WHPX, guests do not start. TCG is inventory-only unless you turn on `windowsAllowTCG` in `settings.json`.

| Platform    | Guide                                                                                                                                                              |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **macOS**   | **[getting-started-installation.md](getting-started-installation.md)** — Apple Silicon `.pkg`                                                                      |
| **Linux**   | **[getting-started-linux.md](getting-started-linux.md)** — Ubuntu / Debian `.deb` + systemd; other distros and no-root hosts use the portable tarball on that page |
| **Windows** | This page                                                                                                                                                          |

After install, open `http://localhost:7777` and finish the web setup. First Workload: [Quickstart](getting-started-quickstart.md) and [First launch](getting-started-first-launch.md). Words: **Home**, **Device**, **Workload**, **Library**. See [Product terminology](product-terminology.md).

## System requirements

- **Windows 10 or Windows 11**, 64-bit. Use the zip that matches this Device (`amd64` or `arm64`).
- **Disk space:** at least 2 GB for BarkVisor. Plan more for guest disks. Cloud images are typically 500 MB to 2 GB.
- **RAM:** 8 GB minimum; 16 GB or more recommended. Each running Workload reserves its configured memory.
- **QEMU at `C:\Program Files\qemu`.** The zip does not bundle QEMU, firmware, or `qemu-img`.
- **WHPX** — Windows Hypervisor Platform (`HypervisorPlatform`). Firmware virtualization (Intel VT-x or AMD-V) must be on in BIOS. Reboot after enabling the feature.

NAT networking works. Bridged networking does not. TPM 2.0 emulation is not available on Windows Devices (`swtpm` unixio). Windows 11 guests that require TPM belong on a Linux or macOS Device, or start without TPM (`firmware.tpm=false`).

Optional for cloud-init seed ISOs: **xorriso** or **mkisofs** on `PATH` (MSYS2). Optional for off-LAN access: **Tailscale**. BarkVisor can advertise the tailnet address. It does not bundle Tailscale. See [Home and pairing](home-and-pairing.md#device-url).

## Enable Windows features

Do this first. An elevated PowerShell:

```powershell
Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform, VirtualMachinePlatform |
  Select-Object FeatureName, State
```

Turn the features on:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All
```

Or DISM:

```bat
dism /online /enable-feature /featurename:HypervisorPlatform /all
dism /online /enable-feature /featurename:VirtualMachinePlatform /all
```

Or GUI: **Settings → System → Optional features → More Windows features** (or Control Panel → Programs → Turn Windows features on or off). Check **Windows Hypervisor Platform** and **Virtual Machine Platform**. Leave **Hyper-V** off unless you already use it. QEMU talks to WHPX through `WinHvPlatform.dll`, not the Hyper-V Manager UI.

If the hypervisor is parked:

```bat
bcdedit /enum {current}
bcdedit /set hypervisorlaunchtype auto
```

Reboot. Confirm `C:\Windows\System32\WinHvPlatform.dll` exists. Doctor later checks that DLL and `WHvGetCapability`.

BIOS: Intel VT-x, AMD-V / SVM, and any "virtualization technology" toggle. Nested VMs inside another hypervisor need nested virtualization enabled on that host.

## Install QEMU and other software

QEMU, firmware, and `qemu-img` come from the QEMU Windows installer. BarkVisor looks here, in order:

1. `C:\Program Files\qemu\qemu-system-x86_64.exe` (and `qemu-system-aarch64.exe` on arm64)
2. `C:\Program Files\qemu\bin\`
3. `C:\msys64\ucrt64\bin\`
4. `PATH`

Firmware lives next to the binaries: `C:\Program Files\qemu\share` (OVMF / edk2 `*.fd` files).

```powershell
winget install --id SoftwareFreedomConservancy.QEMU -e
```

`winget install qemu` also works. The installer must place `qemu-system-x86_64.exe` at `C:\Program Files\qemu\qemu-system-x86_64.exe`. `packaging\windows\install.ps1` refuses to continue without that file.

MSYS2 is the other channel:

```sh
pacman -S mingw-w64-ucrt-x86_64-qemu
```

Keep `C:\msys64\ucrt64\bin` on `PATH` if you use MSYS2 QEMU instead of the official installer.

Cloud-init seed ISOs need an mkisofs-compatible tool:

```sh
pacman -S mingw-w64-ucrt-x86_64-libisoburn
```

That puts `xorriso.exe` on `PATH`. ISO-only installs (Windows installer ISOs, no cloud-init) do not need it.

Confirm:

```powershell
Get-Item "C:\Program Files\qemu\qemu-system-x86_64.exe"
Get-Item "C:\Program Files\qemu\qemu-img.exe"
Get-ChildItem "C:\Program Files\qemu\share" -Filter "*.fd" | Select-Object -First 10 Name
```

## Install the zip

Pick the zip that matches this Device:

| Host           | Asset                         |
| -------------- | ----------------------------- |
| Windows x86_64 | `barkvisor-windows-amd64.zip` |
| Windows ARM64  | `barkvisor-windows-arm64.zip` |

CI workflow **Windows Package** (`.github/workflows/windows-package.yml`) builds both on tag `v*` and on manual dispatch. Download the artifact from that run, or from [Releases](https://github.com/pmdroid/barkvisor/releases) when the zip is attached.

The zip is the payload only: `BarkVisor.exe`, Swift and VC runtime DLLs, and `share\barkvisor\frontend\dist\`. It does not include QEMU. `install.ps1` lives in the repo at `packaging\windows\install.ps1`.

Elevated PowerShell. Extract, then point the install script at that folder:

```powershell
$zip = "$env:USERPROFILE\Downloads\barkvisor-windows-amd64.zip"
$payload = "$env:TEMP\barkvisor-payload"
if (Test-Path -LiteralPath $payload) { Remove-Item -LiteralPath $payload -Recurse -Force }
Expand-Archive -LiteralPath $zip -DestinationPath $payload -Force
Get-ChildItem $payload
# BarkVisor.exe, *.dll, share\barkvisor\frontend\dist\index.html
```

If this machine has a git checkout:

```powershell
Set-Location path\to\barkvisor
powershell -ExecutionPolicy Bypass -File .\packaging\windows\install.ps1 -Source $payload
```

If it does not, download the script first (read it, then run it):

```powershell
Invoke-WebRequest -UseBasicParsing `
  -Uri https://raw.githubusercontent.com/pmdroid/barkvisor/main/packaging/windows/install.ps1 `
  -OutFile "$env:TEMP\barkvisor-install.ps1"
powershell -ExecutionPolicy Bypass -File "$env:TEMP\barkvisor-install.ps1" -Source $payload
```

`install.ps1` copies `BarkVisor.exe` and `*.dll` into `C:\Program Files\BarkVisor`, copies the SPA into `C:\Program Files\BarkVisor\share\barkvisor\frontend\dist`, creates `C:\ProgramData\BarkVisor` (SYSTEM and Administrators only), registers the **BarkVisor** service (`LocalSystem`, start=auto), and starts it.

Open `http://localhost:7777`. Use **localhost**, not `127.0.0.1`, for passkeys.

### Remote / LAN

The service binds `0.0.0.0:7777`. Allow inbound TCP 7777 if you open the UI from another machine:

```powershell
New-NetFirewallRule -DisplayName "BarkVisor" -Direction Inbound -Protocol TCP -LocalPort 7777 -Action Allow
```

Off-LAN: install Tailscale yourself.

## Service

```powershell
Get-Service BarkVisor
sc.exe query BarkVisor
sc.exe stop BarkVisor
sc.exe start BarkVisor
```

Event Viewer and `C:\ProgramData\BarkVisor\logs` hold daemon logs. `KillMode` is not a Windows concept. Stopping the service stops the daemon. Running QEMU Workloads are separate processes. `uninstall.ps1` also stops leftover `qemu-system*` processes.

### Doctor

With the service running (`/api/health` must answer, or doctor fails `api-health`):

```powershell
& "C:\Program Files\BarkVisor\BarkVisor.exe" doctor
```

It checks QEMU, WHPX, firmware, `qemu-img`, the ISO tool, the data directory, and port 7777. The same report is `GET /api/system/doctor`.

## What gets installed

```
C:\Program Files\BarkVisor\
  BarkVisor.exe
  *.dll                         # Swift runtime + VC redistributable
  share\barkvisor\frontend\dist\
C:\ProgramData\BarkVisor\
  run\
```

QEMU stays under `C:\Program Files\qemu`. It is not copied into the BarkVisor prefix.

## Data directory

Installed Device:

```
C:\ProgramData\BarkVisor\
```

`swift run` / unpackaged exe uses `%LOCALAPPDATA%\BarkVisor`. Override with `BARKVISOR_DATA_DIR`.

| Path           | Purpose                                                                  |
| -------------- | ------------------------------------------------------------------------ |
| `db.sqlite`    | SQLite (users, Workloads, disks, networks, images, templates, audit log) |
| `jwt-secret`   | JWT signing secret                                                       |
| `disks/`       | Guest disks                                                              |
| `images/`      | Downloaded ISOs and cloud images (Library)                               |
| `logs/`        | Server logs (`BARKVISOR_LOG_DIR` overrides)                              |
| `logs/vms/`    | Per-Workload logs                                                        |
| `backups/`     | Database backups                                                         |
| `cloud-init/`  | Seed ISOs (`user-data` + `meta-data` only)                               |
| `efivars/`     | UEFI NVRAM                                                               |
| `monitor/`     | QMP sockets                                                              |
| `tus-uploads/` | Resumable uploads                                                        |
| `pids/`        | QEMU PID files                                                           |
| `console/`     | Serial sockets                                                           |

Short sockets live under `C:\ProgramData\BarkVisor\run` (installed) or `%TEMP%` (dev).

## Updates

**Settings → Updates** applies checksummed `.deb` and `.pkg` on Linux and macOS appliances. The Windows zip is a manual replace: stop the service, extract the newer zip over `C:\Program Files\BarkVisor` (or re-run `install.ps1 -Source`), start the service. `C:\ProgramData\BarkVisor` stays put. GRDB migrates on start.

## Uninstalling

From a checkout:

```powershell
powershell -ExecutionPolicy Bypass -File .\packaging\windows\uninstall.ps1
```

That stops and deletes the service, stops leftover `qemu-system*` processes, and removes `C:\Program Files\BarkVisor`. Data under `C:\ProgramData\BarkVisor` stays unless you pass `-PurgeData`.

QEMU is left installed.

## Building from source (optional)

End users should use the zip. To build on Windows:

```powershell
cd frontend
bun install --frozen-lockfile
bun run build
cd ..
.\scripts\windows-swift.ps1 --% build -c release --product BarkVisorApp
.\scripts\stage-windows-payload.ps1 `
  -SourceDir .build\release `
  -FrontendDir frontend\dist `
  -OutDir build\windows-payload
powershell -ExecutionPolicy Bypass -File .\packaging\windows\install.ps1 -Source build\windows-payload
```

CI: `.github/workflows/windows-package.yml` (zip) and `.github/workflows/windows-ci.yml` (build + filtered tests).
