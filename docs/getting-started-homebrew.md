# Installation (Homebrew)

This page is the macOS **Homebrew** install for a BarkVisor **Device**. NAT **Workloads** work after `brew services start`. Bridged networking is a second, optional step.

| Platform | Guide |
|----------|--------|
| **macOS (Homebrew)** | This page |
| **macOS (.pkg)** | [getting-started-installation.md](getting-started-installation.md) |
| **Linux** | [getting-started-linux.md](getting-started-linux.md) |

Formula sources live in [packaging/homebrew/README.md](../packaging/homebrew/README.md).

## Requirements

- **Apple Silicon (arm64)** only. The formula has `depends_on arch: :arm64`. Intel Macs are not supported.
- **Homebrew** on the default Apple Silicon prefix: `/opt/homebrew`.
- **Xcode** or Command Line Tools (source / `HEAD` builds).
- Do **not** mix this with the `.pkg` LaunchDaemon on the same host. Both bind **port 7777**.

## What you get

`brew install` puts the Device daemon in the keg and registers a **root** `brew services` LaunchDaemon (`homebrew.mxcl.barkvisor`) running as `_barkvisor`.

| Path | Role |
|------|------|
| `$(brew --prefix)` | Homebrew prefix (`/opt/homebrew` on Apple Silicon) |
| `$(brew --prefix barkvisor)` | Keg (`/opt/homebrew/opt/barkvisor`) |
| `/var/lib/barkvisor` | Device data (not in the keg) |
| `/var/run/barkvisor` | QEMU sockets |
| `/var/log/barkvisor` | `server.log` / `server.err` |

QEMU, swtpm, socket_vmnet, and cdrtools are Homebrew dependencies. They are not bundled in the keg.

The privileged XPC helper is **in the keg**, not loaded. `barkvisor-install-helper` copies the ad-hoc signed binary to `/Library/PrivilegedHelperTools` and writes the MachServices plist under `/Library/LaunchDaemons`. Skip that unless you need bridged networking.

## Install

From a checkout (no tap yet):

```sh
brew install --formula ./packaging/homebrew/barkvisor.rb
sudo "$(brew --prefix barkvisor)/share/barkvisor/postinstall"
sudo brew services start barkvisor
```

`postinstall` creates `_barkvisor`, `/var/lib/barkvisor`, `/var/run/barkvisor`, and `/var/log/barkvisor`. `brew services` loads the daemon plist that keeps QEMU children alive across daemon restarts (`AbandonProcessGroup`). The daemon exits if `/var/run/barkvisor` is missing; re-run postinstall rather than expecting `_barkvisor` to mkdir `/var/run`.

Open `http://localhost:7777` (or the Device IP) and finish [first launch](getting-started-first-launch.md). Then create a NAT Workload from [Quickstart](getting-started-quickstart.md).

Off-LAN: install [Tailscale](https://tailscale.com/download) separately. BarkVisor detects `tailscale` and can advertise the tailnet address. See [Home and pairing](home-and-pairing.md#remote-access-tailscale).

## NAT vs bridged networking

NAT Workloads work without the helper. Bridged networking on macOS uses `dev.barkvisor.helper` plus Homebrew `socket_vmnet`.

- **NAT:** start the Device with `brew services`; no extra install.
- **Bridge:** run `sudo barkvisor-install-helper` (below). `brew services` does not load that LaunchDaemon.

## Bridged networking (optional)

```sh
sudo barkvisor-install-helper
```

That command:

1. Verifies the keg helper is code-signed (`codesign --verify --strict`)
2. Copies it to `/Library/PrivilegedHelperTools/dev.barkvisor.helper`
3. Writes `/Library/LaunchDaemons/dev.barkvisor.helper.plist` with Mach service `dev.barkvisor.helper`
4. Bootstraps the LaunchDaemon

The formula ad-hoc signs **both** `barkvisor` (`dev.barkvisor.app`) and the helper (`codesign -s -`). The helper accepts that Homebrew client only when the executable path is under the Homebrew prefix. The `.pkg` helper still requires the BarkVisor Team ID; SMJobBless is unchanged. Unsigned binaries and ad-hoc binaries outside the prefix are rejected.

`socket_vmnet` is already a formula dependency. If a bridge still fails, see [Troubleshooting](getting-started-troubleshooting.md#macos-privileged-helper-and-socket_vmnet).

Remove the helper without uninstalling the Device:

```sh
sudo launchctl bootout system/dev.barkvisor.helper
sudo rm -f /Library/LaunchDaemons/dev.barkvisor.helper.plist
sudo rm -f /Library/PrivilegedHelperTools/dev.barkvisor.helper
```

## Service status and logs

```sh
sudo brew services info barkvisor
curl -sS http://127.0.0.1:7777/api/health
```

Launchd file logs:

```sh
tail -f /var/log/barkvisor/server.log /var/log/barkvisor/server.err
```

Unified log:

```sh
log stream --predicate 'subsystem == "dev.barkvisor"' --level debug
```

This Device is a **Home** of one until you pair more Devices. Words: [Product terminology](product-terminology.md).

## Upgrade

```sh
brew update
brew upgrade barkvisor
sudo "$(brew --prefix barkvisor)/share/barkvisor/postinstall"
sudo brew services restart barkvisor
```

If you installed the helper, run `sudo barkvisor-install-helper` again after upgrade so `/Library/PrivilegedHelperTools` matches the keg.

## Do not mix .pkg and Homebrew

The `.pkg` LaunchDaemon (`dev.barkvisor`) and Homebrew `brew services` (`homebrew.mxcl.barkvisor`) both listen on **port 7777**. Uninstall or stop one stack before starting the other. Data in `/var/lib/barkvisor` is shared; that is not a supported mixed install.

## Uninstall

```sh
sudo brew services stop barkvisor
brew uninstall barkvisor
```

The helper is outside the keg. Remove it with the commands in [Bridged networking](#bridged-networking-optional) if you installed it.

`--purge` of `/var/lib/barkvisor` deletes Workload disks, Library images, and the local database. Only do that if you mean it:

```sh
sudo brew services stop barkvisor
brew uninstall barkvisor
sudo rm -rf /var/lib/barkvisor /var/run/barkvisor /var/log/barkvisor
```

`scripts/uninstall.sh --purge` is for the **.pkg** install, not Homebrew.
