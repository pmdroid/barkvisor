# First Launch and Setup

## What Happens at Startup

When BarkVisor starts for the first time:

1. The data directory is created (see [Installation](getting-started-installation.md) for paths).
2. The **SQLite database** is created and migrated to the latest schema.
3. **Default records are seeded** into the database:
   - A **Default NAT** network, which provides internet access to VMs through your Mac's network stack with no additional configuration.
   - The **BarkVisor Official** image repository (`images` type), pointing to the official image catalog.
   - The **BarkVisor Templates** repository (`templates` type), pointing to the official VM template catalog.
4. The HTTP server starts on port **7777** immediately.
5. The **SetupMiddleware** detects that no admin user exists and blocks all non-setup API routes, returning a setup-required response.

## Web-Based Setup

Open your browser and navigate to `http://localhost:7777`. Since no admin account exists yet, the UI presents a setup screen.

### Create Admin Account

Set up the administrator account for the web interface.

- **Username** -- defaults to `admin`, but you can choose any name.
- **Password** -- minimum 10 characters. You must type it twice to confirm.
- The password is hashed with **bcrypt** before being stored in the database. The plaintext password is never written to disk.
- This account is used to log into the web UI. JWT tokens are issued on login, signed with the auto-generated secret stored in `<dataDir>/jwt-secret`.

Once the admin account is created, the SetupMiddleware allows all API routes and redirects you to the login page.

## After Setup

Once setup is complete, BarkVisor runs as a **headless daemon** serving the web UI on port 7777. There is no native macOS UI -- all management happens through the browser.

On subsequent launches, the server detects the existing admin user and starts normally without showing the setup screen.

## System Helper

BarkVisor includes a **privileged helper** (`dev.barkvisor.helper`) for operations that require elevated privileges:

- **Network bridges** for bridged VM networking (via socket_vmnet)

The helper is installed as a launchd service during package installation. You can manage bridges from the Networks page in the web UI.

## Catalog Sync

Image and template catalogs from built-in repositories are synced automatically in the background on each startup. You can also trigger a manual sync from the Repositories page, or add custom repositories from the web UI.

## Shutdown Behavior

The daemon handles SIGTERM and SIGINT signals for graceful shutdown. When the daemon stops while VMs are running, QEMU processes continue running in the background. On next launch, BarkVisor reconnects to them.

To stop the daemon:

```
sudo launchctl bootout system/dev.barkvisor
```

To stop the daemon and shut down all VMs first, use the web UI to stop VMs before stopping the daemon.
