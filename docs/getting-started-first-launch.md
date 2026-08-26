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

Screenshots below were captured from a first-run setup on **Linux** (OrbStack). On **macOS**, bridged/vmnet is Homebrew `socket_vmnet` (install it yourself; BarkVisor does not start that daemon). Linux uses a host bridge. NAT works without either.

### 1. Welcome

![Setup welcome screen](/docs/onboarding/setup-welcome.png)

Choose **Set up this Device** to create a new Home on this machine, or **Join an existing Home** if another Device already issued a pairing code (Settings → Pairing → Add a Device). Paste the full pairing code (`barkvisor://pair/v1?…`) — the short code alone is not enough. This Device still runs if the other Device is later unreachable.

On an **API-only Device** (no SPA), join from that host instead of the wizard:

```sh
barkvisor-agent join --code 'barkvisor://pair/v1?…'
```

Or set `BARKVISOR_JOIN_CODE` in the daemon environment before first boot. Join is console-local (`POST http://127.0.0.1:7777/api/pairing/join`) and is not proxied through Home. Full walkthrough: [Home and pairing](home-and-pairing.md). See also [Installation (Linux)](getting-started-linux.md#api-only-device-no-spa).

### 2. Create admin account

![Create admin account](/docs/onboarding/setup-admin.png)

- **Username** — defaults to `admin`, but you can choose any name.
- **Password** — minimum 10 characters. You must type it twice to confirm.
- The password is hashed with **bcrypt** before being stored in the database. The plaintext password is never written to disk.
- This account is used to log into the web UI. JWT tokens are issued on login, signed with the auto-generated secret stored in `<dataDir>/jwt-secret`.

![Admin account filled in](/docs/onboarding/setup-admin-filled.png)

Click **Continue**. (If you see “Password already set”, setup was partially completed earlier — stop the daemon, delete the data directory, and start again for a clean wizard.)

### 3. Sync image catalog

![Sync image catalog](/docs/onboarding/setup-catalog.png)

Click **Sync Catalog** so OS images and templates are available immediately (or **Skip** and sync later from the Registry).

![Catalog sync finished](/docs/onboarding/setup-catalog-synced.png)

When the sync finishes, click **Continue**.

### 4. Finish and open the dashboard

![Setup complete — All Set](/docs/onboarding/setup-ready.png)

Click **Launch Dashboard**. BarkVisor signs you in automatically and opens the main UI.

![Dashboard after setup](/docs/onboarding/setup-dashboard.png)

SetupMiddleware stops blocking API routes once setup is complete.

## Words we use

This Device is already a **Home** of one. Later, more Devices join that Home — not a cluster, datacenter, or quorum. See [Home and pairing](home-and-pairing.md) and [Product terminology](product-terminology.md). What shipped is in the [Changelog](changelog.md).

## After Setup

Once setup is complete, BarkVisor runs as a **headless daemon** serving the web UI on port 7777. There is no native desktop UI — all management happens through the browser (macOS and Linux).

On subsequent launches, the server detects the existing admin user and starts normally without showing the setup screen (you land on **Login** instead).

## Bridged networking (optional)

NAT works out of the box on every host. Bridged networking uses the native path for each platform:

### macOS

Install **socket_vmnet** with Homebrew and start its service. BarkVisor only attaches QEMU to that socket; it does not bless a privileged helper or configure bridges:

```sh
brew install socket_vmnet
sudo brew services start socket_vmnet
```

NAT Workloads work without this. First-run setup does not install a helper.

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
