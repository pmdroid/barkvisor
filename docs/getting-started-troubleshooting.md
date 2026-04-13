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

For development builds (`swift run`), the data directory is `~/Library/Application Support/BarkVisor/`.

If this directory or its contents have incorrect permissions, the server will fail during initialization. Check permissions:

```sh
ls -la /var/lib/barkvisor/
```

### Database corruption recovery

On startup, BarkVisor attempts to open and migrate the SQLite database at:

```
/var/lib/barkvisor/db.sqlite          # installed daemon
~/Library/Application Support/BarkVisor/db.sqlite   # dev builds
```

If the database fails to open, the server automatically attempts to restore from the most recent backup in the backups directory. If no backup is available, a fresh database is created (all data is lost). Check server logs for messages like `Database failed to open` or `Database restored from backup`.

Database backups are enabled by default and run daily. The backup directory defaults to:

```
/var/lib/barkvisor/backups/           # installed daemon
~/Library/Application Support/BarkVisor/backups/     # dev builds
```

Backup retention is 30 days by default, configurable via the `backupRetentionDays` UserDefaults key.

### Checking server logs

BarkVisor writes structured JSON logs to:

```
/var/lib/barkvisor/logs/              # installed daemon
~/Library/Application Support/BarkVisor/logs/        # dev builds
```

This path can be overridden with the `BARKVISOR_LOG_DIR` environment variable. The log system supports five levels: `debug`, `info`, `warn`, `error`, and `fatal`. BarkVisor also logs to the system unified log under the subsystem `dev.barkvisor` with categories `server`, `vm`, `auth`, `images`, `metrics`, `audit`, `sync`, and `app`.

To view system logs:

```sh
log stream --predicate 'subsystem == "dev.barkvisor"' --level debug
```

## Onboarding issues

### Re-triggering setup

BarkVisor shows a web-based setup screen on first launch when no admin user exists. Setup completion is tracked in the database (the presence of a user with a non-empty password).

To re-trigger setup, delete the database and restart BarkVisor:

```sh
sudo launchctl bootout system/dev.barkvisor
sudo rm /var/lib/barkvisor/db.sqlite
sudo launchctl bootstrap system /Library/LaunchDaemons/dev.barkvisor.plist
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

In release installs, BarkVisor looks for `qemu-system-aarch64` and `qemu-img` in `/usr/local/libexec/barkvisor/`. During development (running via `swift run`), it falls back to:

1. `/opt/homebrew/bin/`
2. `/usr/local/bin/`
3. PATH lookup via `which`

If you see an error like `qemu-system-aarch64 not found`, install QEMU via Homebrew:

```sh
brew install qemu
```

### Firmware not found

BarkVisor resolves QEMU firmware (EFI images, VGA BIOS) from:

1. `/usr/local/share/barkvisor/qemu/` (installed daemon)
2. `/opt/homebrew/share/qemu/`
3. `/usr/local/share/qemu/`

If VMs fail to boot with firmware errors, verify the firmware files exist at one of these paths.

### VM log files

Per-VM stdout/stderr output is captured in:

```
/var/lib/barkvisor/logs/vms/          # installed daemon
~/Library/Application Support/BarkVisor/logs/vms/    # dev builds
```

Check these logs for QEMU error messages, boot failures, or crash output.

### VMs survive daemon restart (by design)

When the BarkVisor daemon stops, running QEMU processes are intentionally left alive. The daemon detaches its monitoring but does not kill the processes. On next launch, `VMProcessMonitor` scans the PID files directory:

```
/var/lib/barkvisor/pids/              # installed daemon
~/Library/Application Support/BarkVisor/pids/        # dev builds
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

### Privileged helper approval

BarkVisor uses a privileged XPC helper (`BarkVisorHelper`) installed as a LaunchDaemon at `/Library/LaunchDaemons/dev.barkvisor.helper.plist`. The helper binary is located at `/Library/PrivilegedHelperTools/dev.barkvisor.helper` and communicates via the Mach service `dev.barkvisor.helper`.

If the helper is not running, bridge networking operations will fail. Check its status:

```sh
sudo launchctl print system/dev.barkvisor.helper
```

### socket_vmnet not found

Bridged networking requires `socket_vmnet` from the lima-vm project. In release installs, it is bundled at `/usr/local/libexec/barkvisor/socket_vmnet`. During development, BarkVisor looks for it under `/opt/homebrew/opt/socket_vmnet/bin/` and `/usr/local/opt/socket_vmnet/bin/`.

If bridged networking fails, install it:

```sh
brew install socket_vmnet
```

### Bridge socket missing

Each bridge interface has an associated unix socket created by the `socket_vmnet` daemon. If a VM cannot connect to the bridge, check the bridge state via the helper:

- Verify the LaunchDaemon plist exists
- Verify the daemon is running (`launchctl list | grep barkvisor`)
- Check that the socket file is present at the expected path

Bridge state is synced periodically by `BridgeSyncService`.

### XPC connection errors

If the privileged helper cannot be reached, you will see log messages like `XPC connection interrupted` or `XPC connection invalidated`. Common causes:

- The helper binary is not code signed with a matching team ID
- The helper plist is not installed in `/Library/LaunchDaemons/`
- The helper was not approved in System Settings

The XPC client uses a 5-second timeout for general operations (ping, version, status queries) and a 15-second timeout for bridge operations (install, remove, start, stop).

## Frontend

### Blank page in the web UI

If you see a blank page at `http://localhost:7777`, the frontend has not been built. During development, build it with:

```sh
cd frontend && bun install && bun run build
```

The server searches for the frontend `dist/` directory in several locations:

1. `/usr/local/share/barkvisor/frontend/dist/` (installed daemon)
2. `Sources/BarkVisor/Resources/frontend/dist/` relative to the project root or current working directory
3. `frontend/dist/` relative to the project root or current working directory

If none of these contain an `index.html`, the SPA middleware is not registered and all non-API routes return 404.

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

### XPC team ID mismatch

In release builds, the build script injects the real `APPLE_TEAM_ID` into the helper protocol source before compiling. If the team ID in the main app does not match the team ID in the helper, XPC connections will be rejected by macOS. This typically happens when:

- The build was not done with `build-release.sh` (the team ID stays as `DEVELOPMENT`)
- The helper and main app were signed with different identities
- The helper was replaced without rebuilding the main app

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

- `system-info.json` -- macOS version, CPU count, physical memory
- `barkvisor-info.json` -- app version, uptime, data directory paths
- `vm-states.json` -- currently running VMs with their PIDs and VNC socket paths
- Recent log files

The bundle is created in the system temp directory and automatically cleaned up after 15 minutes.

### Database backups

Automatic database backups run daily when enabled (on by default). Backups are stored in:

```
/var/lib/barkvisor/backups/           # installed daemon
~/Library/Application Support/BarkVisor/backups/     # dev builds
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
