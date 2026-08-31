---
title: "Settings: Updates"
description: "Apply a checksummed .deb or .pkg on a root Device."
---
**Settings → Updates** (`?tab=updates`) is the appliance upgrade path. It is for a root Device installed from Ubuntu / Debian `.deb` or macOS Apple Silicon `.pkg`, with data under `/var/lib/barkvisor`.

`swift run`, a smoke instance, and a leftover Homebrew keg stay fail-closed. Those Devices explain why Apply is unavailable.

## What you see

- Current version on this Device
- A newer GitHub release, or “already on the latest”
- **Check**, then **Apply** after you confirm

The Device downloads the matching asset and verifies the `.sha256` sidecar before it installs. A missing or bad checksum refuses the apply.

| Platform | Apply |
|----------|--------|
| Ubuntu / Debian | `dpkg -i` the newer `.deb`, then restart `barkvisor.service` (`KillMode=process`) |
| macOS Apple Silicon | `installer -pkg … -target /`, then reload the LaunchDaemon |

The data directory is preserved. GRDB runs new migrations on start. Running Workloads stay up across the daemon restart.

There is no XPC helper and no `sudo brew`. Do not `brew upgrade barkvisor`.

## Test a local update

Production Check and Apply hit GitHub Releases (`https://api.github.com/repos/pmdroid/barkvisor/releases`). Packaged appliances do not expose a free-form update URL.

To exercise Apply without publishing a release, serve a GitHub-shaped feed from built packages, then point one Device at it.

1. Build a package **newer** than the Device under test.
   macOS: `scripts/build-release.sh` writes `build/BarkVisor-<ver>.pkg` plus a `.sha256`.
   Linux: `scripts/build-linux-packages.sh` writes `build/linux-packages/barkvisor_<ver>_<arch>.deb` plus a `.sha256`.
   See [Building releases](/docs/getting-started/building-releases/).

2. Serve the feed:
   ```sh
   mise run local-updates
   # or point --dir at the package folder
   scripts/serve-local-updates.sh --dir build/linux-packages --tag v9.9.9
   ```
   The script prints `BARKVISOR_UPDATE_URL=http://127.0.0.1:<port>/repos/pmdroid/barkvisor/releases` and listens on loopback only. Use `--tag` when the filename version is not the version you want advertised.

3. Point the Device at that URL.
   - Any build: set `BARKVISOR_UPDATE_URL` and restart.
     Linux package: add it to `/etc/barkvisor/barkvisor.env`, then `sudo systemctl restart barkvisor.service`.
     macOS package: add `BARKVISOR_UPDATE_URL` under `EnvironmentVariables` in `/Library/LaunchDaemons/dev.barkvisor.plist`, then `sudo launchctl kickstart -k system/dev.barkvisor`.
   - Dev builds only (version contains `dev` or `0.0.0`): Settings → Updates → Test update URL.

Check offers the feed only when the tag is newer than the installed Device. `--prerelease` is for the beta channel.

The server binds `127.0.0.1`. On a remote Device, copy the assets onto that unit and run the script there, or tunnel the port so `127.0.0.1:<port>` on the Device reaches the machine that is serving.

## Related

- [Installation (macOS)](/docs/getting-started/installation/)
- [Installation (Linux)](/docs/linux/)
- [Settings](/docs/using/settings/)
