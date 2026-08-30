# Troubleshooting

## Server fails to start

### Port 7777 already in use

BarkVisor's HTTP server binds to port 7777 by default (configured in `Config.port`). If another process is using that port, the server will fail to start. Check for conflicts:

```sh
lsof -i :7777
```

Kill the conflicting process. The server always binds to `0.0.0.0`.

### Permission errors on data directory

For installed daemon builds, BarkVisor stores all data under:

```
/var/lib/barkvisor/
```

For development builds (`swift run`):

| Platform | Default data directory |
|----------|------------------------|
| macOS | `~/Library/Application Support/BarkVisor/` |
| Linux | `~/.local/share/barkvisor/` |

Override with `BARKVISOR_DATA_DIR`. If the directory or its contents have incorrect permissions, the server will fail during initialization:

```sh
ls -la /var/lib/barkvisor/
# or: ls -la ~/.local/share/barkvisor/
```

### Database corruption recovery

On startup, BarkVisor attempts to open and migrate the SQLite database at:

```
/var/lib/barkvisor/db.sqlite                              # installed daemon
~/Library/Application Support/BarkVisor/db.sqlite         # macOS dev
~/.local/share/barkvisor/db.sqlite                        # Linux dev
```

If the database fails to open, the server automatically attempts to restore from the most recent backup in the backups directory. If no backup is available, a fresh database is created (all data is lost). Check server logs for messages like `Database failed to open` or `Database restored from backup`.

Database backups are enabled by default and run daily. The backup directory defaults to:

```
/var/lib/barkvisor/backups/                           # installed daemon
~/Library/Application Support/BarkVisor/backups/      # macOS dev
~/.local/share/barkvisor/backups/                     # Linux dev
```

Backup retention is 30 days by default, configurable via the `backupRetentionDays` UserDefaults key.

### Checking server logs

BarkVisor writes structured JSON logs to:

```
/var/lib/barkvisor/logs/                              # installed daemon
~/Library/Application Support/BarkVisor/logs/         # macOS dev
~/.local/share/barkvisor/logs/                        # Linux dev
```

Override with `BARKVISOR_LOG_DIR`. Levels: `debug`, `info`, `warn`, `error`, `fatal`. On macOS, BarkVisor also logs to the unified log (subsystem `dev.barkvisor`).

```sh
# macOS
log stream --predicate 'subsystem == "dev.barkvisor"' --level debug

# Linux (systemd install)
journalctl -u barkvisor.service -f
```

### Linux-specific

Linux install guide: [Installation (Linux)](getting-started-linux.md).

- **QEMU not found:** install distro QEMU (see the Linux install checklist).
- **UEFI guest fails to boot:** ensure OVMF/AAVMF packages are installed; HAOS needs a real VARS template (not an empty file).
- **Bridge fails:** use **Networks → Bridge setup → Device address (DHCP/static) → Apply/Revert**, or run the equivalent commands on that page. Rollback is a host timer. Under systemd, do not set `NoNewPrivileges=true` on the unit (packaged unit allows the setuid helper).
- **Blank SPA after package install:** confirm `/usr/local/share/barkvisor/frontend/dist` has `index.html` (or `BARKVISOR_FRONTEND_DIR`).
- **Slow guests:** many nested/cloud hosts lack `/dev/kvm` → TCG. The daemon is root; dropped QEMU needs group `kvm` when KVM is present.
- **Stop / restart (systemd):** `sudo systemctl restart barkvisor.service` and `journalctl -u barkvisor.service -f`. The unit uses `KillMode=process`, so a restart signals only the daemon — running Workloads stay up and are reattached. Use Workload Stop to shut a guest down.

## Onboarding issues

### Re-triggering setup

BarkVisor shows a web-based setup screen on first launch when no admin user exists. Setup completion is tracked in the database (the presence of a user with a non-empty password).

To re-trigger setup, delete the database and restart BarkVisor:

```sh
# macOS
sudo launchctl bootout system/dev.barkvisor
sudo rm /var/lib/barkvisor/db.sqlite
sudo launchctl bootstrap system /Library/LaunchDaemons/dev.barkvisor.plist

# Linux
sudo systemctl stop barkvisor.service
sudo rm /var/lib/barkvisor/db.sqlite
sudo systemctl start barkvisor.service
```

Then open `http://localhost:7777` to go through the setup wizard again.

### Password validation

During onboarding, the initial password must be at least 10 characters. The password is hashed with bcrypt before storage. If a password has already been set for the default user, onboarding will report an error.

### Catalog sync failures

On first launch, BarkVisor seeds a default image repository and templates from remote JSON files hosted on GitHub. If these fetches fail (network issues, DNS resolution, corporate proxy), the image library will be empty. You can trigger a manual sync from the web UI's image library page, or check that the URLs are reachable:

```
https://raw.githubusercontent.com/pmdroid/barkvisor/refs/heads/main/repos/images.json
https://raw.githubusercontent.com/pmdroid/barkvisor/refs/heads/main/repos/templates.json
```

## QEMU and VM issues

### QEMU binary not found

**macOS** looks for `qemu-system-aarch64` and `qemu-img` in Homebrew first, then a leftover `/usr/local/libexec/barkvisor/` copy:

1. `/opt/homebrew/bin/`
2. `/usr/local/bin/`
3. leftover libexec
4. PATH via `which`

```sh
brew install qemu
```

**Linux** uses distro QEMU on `$PATH`. Install QEMU from the distro using [System Requirements](getting-started-linux.md#system-requirements) in the Linux install guide.

### Firmware not found

BarkVisor resolves QEMU firmware (EFI images, VGA BIOS) from:

1. `/opt/homebrew/share/qemu/` / `/usr/local/share/qemu/` (macOS Homebrew)
2. leftover `/usr/local/share/barkvisor/qemu/` if present
3. Distro OVMF / AAVMF paths on Linux (edk2 packages)

If VMs fail to boot with firmware errors, verify the firmware files exist at one of these paths.

### VM log files

Per-VM stdout/stderr output is captured in:

```
/var/lib/barkvisor/logs/vms/                         # installed (macOS/Linux)
~/Library/Application Support/BarkVisor/logs/vms/    # macOS dev
~/.local/share/barkvisor/logs/vms/                   # Linux dev
```

Check these logs for QEMU error messages, boot failures, or crash output.

### VMs survive daemon restart (by design)

When the BarkVisor daemon stops, running QEMU processes are intentionally left alive. The daemon detaches its monitoring but does not kill the processes. On next launch, `VMProcessMonitor` scans the PID files directory:

```
/var/lib/barkvisor/pids/                             # installed (macOS/Linux)
~/Library/Application Support/BarkVisor/pids/        # macOS dev
~/.local/share/barkvisor/pids/                       # Linux dev
```

Each `.pid` file contains the QEMU process ID. If the process is still running, BarkVisor reconnects to its QMP and VNC sockets and resumes monitoring. If the process has exited, the stale PID file is cleaned up and the VM state is updated in the database.

This means a quit-and-relaunch cycle does not interrupt running VMs.

### Forcing VM cleanup

If a VM appears stuck in a running state but its QEMU process is gone, delete the corresponding PID file and restart BarkVisor:

```sh
sudo rm /var/lib/barkvisor/pids/<vm-id>.pid
sudo launchctl kickstart system/dev.barkvisor
```

## Helper and networking

### macOS: Homebrew socket_vmnet

On **macOS**, bridged/vmnet networking uses Homebrew `socket_vmnet`. Install the package as your user (`brew install socket_vmnet`). Do not `sudo brew install`. Then use the same sheet as Linux: **Networks → Bridge setup → Device address (DHCP/static) → Apply/Revert**. Copyable `networksetup` commands stay on that page. There is no XPC helper.

```sh
brew install socket_vmnet
```

The default service socket is `/opt/homebrew/var/run/socket_vmnet` (Intel Homebrew: `/usr/local/var/run/socket_vmnet`). If a Workload cannot attach:

- Confirm **Bridge setup** Applied and Re-check is green
- Confirm the socket file exists
- NAT Workloads do not need this service

A leftover `dev.barkvisor.helper` from older installs is unused. Logs that repeat `BarkVisorHelper: XPC connection invalidated` mean that old helper is still trying to reconnect — not an in-tree XPC client. Homebrew/pkg postinstall boots leftover helpers out. You can also:

```sh
sudo launchctl bootout system/dev.barkvisor.helper
sudo rm -f /Library/LaunchDaemons/dev.barkvisor.helper.plist
sudo rm -f /Library/PrivilegedHelperTools/dev.barkvisor.helper
```

NAT Workloads do not need `socket_vmnet`.

### Linux: host bridge

On **Linux**, bridged VMs use QEMU `-netdev bridge` with a host `br*` interface and `qemu-bridge-helper` ACL in `/etc/qemu/bridge.conf`. Prefer **Networks → Bridge setup → Device address (DHCP/static) → Apply/Revert**. See [Bridged networking](getting-started-linux.md#bridged-networking) and [Networks](using-networks.md).

## Frontend

### Blank page in the web UI

If you see a blank page at `http://localhost:7777`, the frontend has not been built. During development, build it with:

```sh
cd frontend && bun install && bun run build
```

The server searches for the frontend `dist/` directory in several locations:

1. `BARKVISOR_FRONTEND_DIR` if set and contains `index.html`
2. `/usr/local/share/barkvisor/frontend/dist/` (installed daemon)
3. `Sources/BarkVisor/Resources/frontend/dist/` (dev probes)
4. `frontend/dist/` (dev probes)

On Linux, `./scripts/linux-frontend-serve.sh` builds the SPA and can start the daemon with the correct env. If none of these paths contain `index.html`, the SPA middleware is not registered and non-API routes return 404.

### API proxy errors

The frontend expects the API to be served from the same origin. CORS is configured to allow requests from `http://localhost:7777` and `http://127.0.0.1:7777` when the server binds to `0.0.0.0`. If you access the UI from a different hostname, CORS will reject the requests.

### WebSocket ticket failures

WebSocket and SSE connections use a single-use ticket system instead of passing JWTs in URL query parameters. The client exchanges its JWT for a short-lived ticket via an authenticated POST endpoint, then passes only the ticket in the connection URL.

If WebSocket connections fail with authentication errors:

- Ensure your JWT has not expired
- Check that the ticket was consumed successfully (tickets are single-use and time-limited)
- Verify the server clock is accurate (ticket expiry depends on system time)

## Code signing

### Hypervisor entitlement

QEMU requires the `com.apple.security.hypervisor` entitlement to use Apple's Hypervisor.framework. Without it, VMs will fail to start with a permission error. This entitlement is applied during the build process (see `scripts/build-release.sh` step 10).

For ad-hoc signed development builds, ensure the entitlement is present:

```sh
codesign -d --entitlements - /path/to/qemu-system-aarch64
```

### Gatekeeper blocks the installer

If macOS blocks the BarkVisor `.pkg` installer, go to **System Settings > Privacy & Security** and click "Open Anyway". For properly notarized builds (created with `--require-notarize`), Gatekeeper should not intervene.

### SQLite “database or disk is full”

Logs with SQLite error-code **13** (`database or disk is full`) mean the **data dir** volume is out of space. LogService prunes logs (and extra DB backups) on those writes, skips the insert, and warns once. Free space on the data directory (not necessarily the Library path). Then restart is not required once writes succeed again.

### Leftover helper vs current networking

Current macOS bridged/vmnet uses Homebrew `socket_vmnet`. BarkVisor does not ship a privileged XPC helper. An **XPC team ID mismatch** message from old docs applied to `dev.barkvisor.helper`, which this tree no longer builds. Ignore it, or remove the leftover helper as above.

## Performance

### Metrics polling frequency

The metrics collector polls each running VM via QMP every 5 seconds and stores samples in a ring buffer of 360 entries (30 minutes of history). If you have many VMs, this can generate significant QMP traffic. Metrics are not persisted to disk.

### Disk info cache

Disk size information is refreshed every 30 seconds by running `qemu-img info` on each disk. This runs in the background and results are cached in memory. If you have a large number of disks, the refresh cycle may take noticeable time.

### Concurrent qemu-img operations

Disk creation, resizing, and info queries all invoke `qemu-img` as a subprocess. These are not globally rate-limited, so creating many disks simultaneously may cause resource contention.

## Diagnostics

### Diagnostic bundle

BarkVisor provides an API endpoint to generate a diagnostic bundle. The bundle is a `.tar.gz` archive containing:

- `system-info.json` -- host OS version, CPU count, physical memory
- `barkvisor-info.json` -- app version, uptime, data directory paths
- `vm-states.json` -- currently running VMs with their PIDs and VNC socket paths
- Recent log files

The bundle is created in the system temp directory and automatically cleaned up after 15 minutes.

### Database backups

Automatic database backups run daily when enabled (on by default). Backups are stored in:

```
/var/lib/barkvisor/backups/                          # installed (macOS/Linux)
~/Library/Application Support/BarkVisor/backups/     # macOS dev
~/.local/share/barkvisor/backups/                    # Linux dev
```

You can customize the backup directory and retention period (default 30 days) via the settings API or UserDefaults keys `backupDirectory` and `backupRetentionDays`.

### Log levels

The application log system supports five levels in increasing severity: `debug`, `info`, `warn`, `error`, `fatal`. Logs are written as JSON lines with fields for timestamp, level, category, message, and optional VM ID, request ID, and error details. Old log files are pruned daily.

### Rate limit bypass for testing

Login rate limiting (10 attempts per 5-minute window per IP) can be disabled by setting the environment variable:

```sh
DISABLE_RATE_LIMIT=1
```

This is intended for automated testing only.
