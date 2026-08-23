# Installation (Homebrew)

This page is the macOS **Homebrew** install for a BarkVisor **Device**. NAT **Workloads** work after `brew services start`. Bridged networking is a second, optional step.

| Platform | Guide |
|----------|--------|
| **macOS (Homebrew)** | This page |
| **macOS (.pkg)** | [getting-started-installation.md](getting-started-installation.md) |
| **Linux** | [getting-started-linux.md](getting-started-linux.md) |

Formula sources live in [packaging/homebrew/README.md](../packaging/homebrew/README.md).

## What you get

`brew install` puts the Device daemon in the keg and registers a **root** `brew services` LaunchDaemon (`homebrew.mxcl.barkvisor`) running as `_barkvisor`. Data is `/var/lib/barkvisor`. Sockets are `/var/run/barkvisor`.

QEMU, swtpm, socket_vmnet, and cdrtools are Homebrew dependencies. They are not bundled in the keg.

The privileged XPC helper is **in the keg**, not loaded. `barkvisor-install-helper` copies the signed binary to `/Library/PrivilegedHelperTools` and writes the MachServices plist under `/Library/LaunchDaemons`. Skip that unless you need bridged networking.

## Install

From a checkout (no tap yet):

```sh
brew install --formula ./packaging/homebrew/barkvisor.rb
sudo "$(brew --prefix barkvisor)/share/barkvisor/postinstall"
sudo brew services start barkvisor
```

`postinstall` creates `_barkvisor` and the data directories. `brew services` loads the daemon plist that keeps QEMU children alive across daemon restarts (`AbandonProcessGroup`).

Open `http://localhost:7777` (or the Device IP) and finish [first launch](getting-started-first-launch.md). Then create a NAT Workload from [Quickstart](getting-started-quickstart.md).

Off-LAN: install [Tailscale](https://tailscale.com/download) separately. BarkVisor detects `tailscale` and can advertise the tailnet address. See [Home and pairing](home-and-pairing.md#remote-access-tailscale).

## Bridged networking (optional)

NAT Workloads do not use the helper. Bridged networking on macOS uses `dev.barkvisor.helper` plus Homebrew `socket_vmnet`.

```sh
sudo barkvisor-install-helper
```

That command:

1. Verifies the keg helper is code-signed (`codesign --verify --strict`)
2. Copies it to `/Library/PrivilegedHelperTools/dev.barkvisor.helper`
3. Writes `/Library/LaunchDaemons/dev.barkvisor.helper.plist` with Mach service `dev.barkvisor.helper`
4. Bootstraps the LaunchDaemon

`socket_vmnet` is already a formula dependency. If a bridge still fails, see [Troubleshooting](getting-started-troubleshooting.md#macos-privileged-helper-and-socket_vmnet).

Remove the helper without uninstalling the Device:

```sh
sudo launchctl bootout system/dev.barkvisor.helper
sudo rm -f /Library/LaunchDaemons/dev.barkvisor.helper.plist
sudo rm -f /Library/PrivilegedHelperTools/dev.barkvisor.helper
```

## Service status

```sh
sudo brew services info barkvisor
curl -sS http://127.0.0.1:7777/api/health
```

Logs: `/var/log/barkvisor/server.log` and `server.err`.

This Device is a **Home** of one until you pair more Devices. Words: [Product terminology](product-terminology.md).

## Uninstall

```sh
sudo brew services stop barkvisor
brew uninstall barkvisor
```

The helper is outside the keg. Remove it with the commands in [Bridged networking](#bridged-networking-optional) if you installed it.

`--purge` of `/var/lib/barkvisor` deletes Workload disks, Library images, and the local database. Only do that if you mean it.
