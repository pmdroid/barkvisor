# Troubleshooting

Start with the error shown in the console. Open **Logs**, filter to the affected Device or workload, and check events around the time of the failure. **Diagnostics** downloads a support bundle.

## Cannot open the console

The default address on the Device is `http://localhost:7777`.

Check that the installed service is running:

| Platform | Check |
|----------|-------|
| macOS | `sudo launchctl print system/dev.barkvisor` |
| Linux | `systemctl status barkvisor.service` |
| Windows | `Get-Service BarkVisor` in PowerShell |

If another program uses port 7777, identify it before stopping anything. On macOS or Linux, `lsof -i :7777` shows the listener. You can set `BARKVISOR_PORT` in the service environment to use another port.

An API-only Device does not serve the web console. Open the console on another paired Device instead.

## Passkey or setup problems

Use `localhost` when the browser is on the Device. For remote access, use an HTTPS hostname. Raw IP addresses, including `127.0.0.1`, cannot register a BarkVisor passkey.

A passkey is tied to a hostname. If you registered it on `localhost`, return through `localhost`; switching to a LAN name or Tailscale name does not move that credential.

See [remote setup](getting-started-first-launch.md#set-up-a-remote-device) for HTTPS and SSH-tunnel options.

If setup resumes at the image Library step, save the folder and continue. There is no need to delete the database. Deleting it removes accounts and workload records, even if disk files remain.

To change whether sign-in is required, use [Settings → Security](settings-security.md).

## Catalog is empty

Open **Settings → Repositories** and click **Sync**. Check the status for each Device. The Device needs network access to the catalog URL.

Catalog sync loads the list of images and templates. The image itself downloads when you create a VM from a template, or request a download.

## VM will not start

Open the VM's **Logs** tab and check the Device's diagnostics.

| Error | What to check |
|-------|---------------|
| QEMU not found | Install QEMU using your platform's install guide |
| Firmware missing | Install the matching QEMU firmware, OVMF, or AAVMF package |
| Architecture mismatch | Use an image matching the selected Device's architecture |
| Port already in use | Change the conflicting NAT port forward |
| Disk access denied | Check the disk path and VM user's permissions |
| `virtio-gpu-pci` is not a valid device | On Arch, install the separate QEMU display modules |
| GPU passthrough unavailable | Follow the [Linux GPU setup guide](getting-started-gpu-passthrough.md) |

Linux uses KVM when available and slower software emulation otherwise. If guests are unusually slow, check access to `/dev/kvm`.

Windows requires Windows Hypervisor Platform by default. Enable it, enable hardware virtualization in firmware, and reboot. The `doctor` report checks whether the accelerator is usable.

### Windows setup: This PC must support Secure Boot

Windows 11 setup can stop with **This PC must support Secure Boot**. The existing workaround is to bypass the installer check from the VM's VNC console:

1. Press **Shift+F10** to open Command Prompt.
2. Run the command below.
3. Close Command Prompt, go **Back** in setup, and continue.

```bat
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
```

If setup also rejects TPM, the corresponding workaround is:

```bat
reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f
```

These commands bypass checks; they do not enable Secure Boot or provide a TPM. Windows Devices do not support BarkVisor's TPM emulation. Prefer a supported guest configuration where possible.

Click inside VNC first if Shift+F10 is not reaching the guest.

## Network problems

NAT does not require a bridge. To reach an SSH server or web service inside a NAT VM, publish its guest port in the VM's network settings. Restart the VM after changing port forwards.

For bridged networking, use **Networks → Host interfaces → Create → Bridge**. After applying, click **Keep changes** within 60 seconds. See [Networks](using-networks.md).

- On macOS, install Homebrew `socket_vmnet` as your regular user.
- On Linux, use a wired interface. The packaged service permits the QEMU bridge helper; a custom `NoNewPrivileges=true` setting prevents that helper from working.
- On Windows, use NAT. Bridged networking is unavailable.

For paired Devices, confirm the selected address is reachable from the joining Device. Copy the full pairing offer, not just its short code. See [Home and pairing](home-and-pairing.md).

## Blank page or disconnected console

Installed packages include the web UI. If it is missing, reinstall the matching package and confirm the frontend files exist:

| Platform | Frontend directory |
|----------|--------------------|
| macOS / Linux | `/usr/local/share/barkvisor/frontend/dist` |
| Windows | `C:\Program Files\BarkVisor\share\barkvisor\frontend\dist` |

The directory must contain `index.html`. A custom `BARKVISOR_FRONTEND_DIR` setting overrides the lookup.

For contributor builds, see [Development](getting-started-development.md). A packaged installation does not need a frontend build command.

If a reverse proxy serves the console, forward API requests and WebSocket connections to the same Device. Reopen the page and sign in again if console authentication has expired.

## Running VMs after a service restart

Running VMs survive BarkVisor restarts. On startup, BarkVisor reconnects to their processes and consoles.

Use the VM's **Stop** action to shut it down. A stale status after restart should be investigated through logs before changing PID files or deleting data.

## Data, backups, and disk space

| Platform | Installed data directory |
|----------|--------------------------|
| macOS / Linux | `/var/lib/barkvisor` |
| Windows | `C:\ProgramData\BarkVisor` |

Logs are in `logs/`, VM logs in `logs/vms/`, and database backups in `backups/`, unless you configured another location.

A SQLite **database or disk is full** error means the volume holding the database is full. Free space there; it may be different from the image Library's volume.

BarkVisor retries a failed database open. For SQLite corruption, it then tries the newest database backup. If there is no backup, it creates a fresh database and reports the loss of database records. Other database or migration errors leave the database in place.

Before attempting manual recovery, stop the service and preserve the data directory, including `db.sqlite`, `db.sqlite-wal`, and `db.sqlite-shm` if present. Database backups do not contain VM disks or App volumes.

## Read service logs

On Linux:

```sh
journalctl -u barkvisor.service -f
```

On macOS:

```sh
log stream --predicate 'subsystem == "dev.barkvisor"' --level debug
```

On Windows, inspect the newest file under `C:\ProgramData\BarkVisor\logs`.

If an older macOS install repeatedly logs `BarkVisorHelper: XPC connection invalidated`, it may have a leftover helper from a previous installation. Current BarkVisor uses socket_vmnet for bridging. The repository's uninstall script includes cleanup for the old helper.

## Report a problem

Include the BarkVisor version, Device platform, action you took, error text, and relevant logs. A Diagnostics bundle helps with startup and runtime failures. Review it before sharing.
