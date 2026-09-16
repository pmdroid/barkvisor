# Install on Windows

Install BarkVisor from a prebuilt zip. You need 64-bit Windows 10 or 11 and QEMU installed separately. BarkVisor runs as a Windows service and opens in your browser.

For other computers, use the [macOS](getting-started-installation.md) or [Linux](getting-started-linux.md) guide.

## System requirements

Choose the BarkVisor zip matching your computer: `amd64` for x86_64 or `arm64` for ARM64. Allow memory and storage for the VMs you plan to run.

Windows Devices support NAT networking. Bridged networking and TPM emulation are unavailable. Guests that need TPM emulation should run on a Linux or macOS Device.

## Enable Windows features

Enable **Windows Hypervisor Platform** and **Virtual Machine Platform** in Windows Features, then restart the computer. Hardware virtualization must also be enabled in the computer's firmware settings.

You can enable the features in an administrator PowerShell:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All
```

BarkVisor uses QEMU's [Windows Hypervisor Platform accelerator](https://www.qemu.org/docs/master/system/whpx.html). Without it, guests do not start by default.

## Install QEMU and other software

Install QEMU using its [Windows download instructions](https://www.qemu.org/download/), or with:

```powershell
winget install --id SoftwareFreedomConservancy.QEMU -e
```

The BarkVisor install script currently requires this file:

```text
C:\Program Files\qemu\qemu-system-x86_64.exe
```

This check also applies when installing the ARM64 BarkVisor zip. A QEMU installation found elsewhere by the daemon may still fail the install script's check.

For cloud images that use cloud-init, also install an ISO creation tool such as `xorriso` or `mkisofs` and make it available on the service's PATH. An ISO-only guest installation does not need that tool.

## Install the zip

1. Download `barkvisor-windows-amd64.zip` or `barkvisor-windows-arm64.zip` from [Releases](https://github.com/pmdroid/barkvisor/releases). If no zip is attached, the **Windows Package** workflow provides build artifacts.
2. Extract it to a new folder. It should contain `BarkVisor.exe`, DLL files, and `share\barkvisor\frontend\dist`.
3. Download the repository's [install script](https://github.com/pmdroid/barkvisor/blob/main/packaging/windows/install.ps1), inspect it, and run it in an administrator PowerShell.

For example, if the extracted files and script are in Downloads:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\install.ps1" -Source "$env:USERPROFILE\Downloads\barkvisor-payload"
```

Replace the paths with your actual folders. The zip contains the application files; the install script is downloaded separately. You do not need to compile the application.

The script installs BarkVisor under `C:\Program Files\BarkVisor`, creates its data folder, and starts the **BarkVisor** service as LocalSystem.

## Complete setup

Open `http://localhost:7777`. Use `localhost`, not `127.0.0.1`, for passkeys. Follow [First launch](getting-started-first-launch.md), then [create your first VM](getting-started-quickstart.md).

For another computer's browser, follow [remote setup](getting-started-first-launch.md#set-up-a-remote-device). If the firewall blocks remote access, add a rule appropriate for your private network.

## Data and service

Application data is in `C:\ProgramData\BarkVisor`. This includes the database, VM disks, images, and logs. Updates preserve this folder.

Check the service or run diagnostics in PowerShell:

```powershell
Get-Service BarkVisor
& "C:\Program Files\BarkVisor\BarkVisor.exe" doctor
```

The service must be running for the diagnostic API check to pass. Logs are under `C:\ProgramData\BarkVisor\logs`.

## Updates

Windows updates are manual:

1. Download and extract the newer zip.
2. Stop the service with `Stop-Service BarkVisor`.
3. Run the install script again with `-Source` pointing to the new extracted folder.
4. Confirm the service starts and reopen the console.

Keep `C:\ProgramData\BarkVisor`. **Settings → Updates** applies packages on macOS and Debian-based Linux Devices; it does not replace the Windows zip.

## Uninstalling

Download and inspect the [uninstall script](https://github.com/pmdroid/barkvisor/blob/main/packaging/windows/uninstall.ps1), then run it as administrator.

It removes the service and application files, and stops leftover `qemu-system*` processes. Shut down guests first; the script can affect other QEMU processes on the same computer.

Data remains unless you pass `-PurgeData`. That option deletes the BarkVisor data folder. QEMU itself remains installed.

## Building from source (optional)

Contributor build and staging commands are in [Development](getting-started-development.md#windows-packages).
