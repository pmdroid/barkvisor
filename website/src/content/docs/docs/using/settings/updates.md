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

## Related

- [Installation (macOS)](/docs/getting-started/installation/)
- [Installation (Linux)](/docs/linux/)
- [Settings](/docs/using/settings/)
