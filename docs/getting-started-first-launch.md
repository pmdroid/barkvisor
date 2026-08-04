# First Launch and Setup

## What Happens at Startup

When BarkVisor starts for the first time:

1. The data directory is created (see [Installation (macOS)](getting-started-installation.md) or [Installation (Linux)](getting-started-linux.md) for paths).
2. The **SQLite database** is created and migrated to the latest schema.
3. **Default records are seeded** into the database:
   - A **Default NAT** network, which provides internet access to VMs through the host network stack with no additional configuration (macOS and Linux).
   - The **BarkVisor Official** image repository (`images` type), pointing to the official image catalog.
   - The **BarkVisor Templates** repository (`templates` type), pointing to the official VM template catalog.
4. The HTTP server starts on port **7777** immediately.
5. The **SetupMiddleware** detects that no admin user exists and blocks all non-setup API routes, returning a setup-required response.

## Web-Based Setup

Open your browser and navigate to `http://localhost:7777` (or `http://<host-ip>:7777`). Since no admin account exists yet, the UI presents a setup wizard.

Screenshots below were captured from a first-run setup on **Linux** (OrbStack). On **macOS**, an extra optional step configures the managed bridge helper; on Linux that step is skipped.

### 1. Welcome

![Setup welcome screen](/docs/onboarding/setup-welcome.png)

Click **Get Started** to begin.

### 2. Create admin account

![Create admin account](/docs/onboarding/setup-admin.png)

- **Username** — defaults to `admin`, but you can choose any name.
- **Password** — minimum 10 characters. You must type it twice to confirm.
- The password is hashed with **bcrypt** before being stored in the database. The plaintext password is never written to disk.
- This account is used to log into the web UI. JWT tokens are issued on login, signed with the auto-generated secret stored in `<dataDir>/jwt-secret`.

### 3. Sync image catalog

![Sync image catalog](/docs/onboarding/setup-catalog.png)

Optionally **Sync Catalog** so OS images and templates are available immediately. You can also sync later from the Registry / image library.

### 4. Finish

![Setup complete](/docs/onboarding/setup-ready.png)

Complete the wizard to finish setup. The UI then opens the main application (login or dashboard). SetupMiddleware stops blocking API routes once an admin user exists.

## After Setup

Once setup is complete, BarkVisor runs as a **headless daemon** serving the web UI on port 7777. There is no native desktop UI -- all management happens through the browser (macOS and Linux).

On subsequent launches, the server detects the existing admin user and starts normally without showing the setup screen.

## Bridged networking (optional)

NAT works out of the box on every host. Bridged networking uses the native path for each platform:

### macOS

A **privileged helper** (`dev.barkvisor.helper`) plus **socket_vmnet** manage bridges via the vmnet stack. The helper is installed as a launchd service with the package. You can manage bridges from the Networks page; first-run setup may prompt to install or start the helper.

### Linux

Bridged networking uses a host Linux bridge plus QEMU’s `qemu-bridge-helper` (see [Installation (Linux)](getting-started-linux.md#bridged-networking-optional)). No separate BarkVisor helper install is required.

## Catalog Sync

Image and template catalogs from built-in repositories are synced automatically in the background on each startup. You can also trigger a manual sync from the Repositories page, or add custom repositories from the web UI.

## Shutdown Behavior

The daemon handles SIGTERM and SIGINT signals for graceful shutdown. When the daemon stops while VMs are running, QEMU processes continue running in the background. On next launch, BarkVisor reconnects to them.

To stop the daemon:

```sh
# macOS (launchd)
sudo launchctl bootout system/dev.barkvisor

# Linux (systemd)
sudo systemctl stop barkvisor.service
```

To stop the daemon and shut down all VMs first, use the web UI to stop VMs before stopping the daemon.
