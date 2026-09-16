# Settings: Updates

Use **Settings → Updates** to update a Device installed from a macOS `.pkg` or Ubuntu / Debian `.deb`.

## Install an update

1. Click **Check**.
2. Review the available version.
3. Click **Apply** and confirm.
4. Wait for the package to install and the Device to reconnect.

BarkVisor downloads the matching package and checks its checksum before installation. If the checksum is missing or incorrect, the update stops.

The data directory stays in place. Running VMs stay up while the BarkVisor service restarts. The browser may briefly lose its connection during the restart.

## Other installations

Windows zip and portable Linux tarball installations need a manual update. Follow the [Windows](getting-started-windows.md#updates) or [Linux](getting-started-linux.md#other-distros-portable-tarball-no-root) guide.

Development instances do not support package updates. The page explains why **Apply** is unavailable.

Homebrew manages QEMU and other macOS runtime packages, not BarkVisor itself.

## Related

- [Install on macOS](getting-started-installation.md)
- [Install on Linux](getting-started-linux.md)
- [Troubleshooting](getting-started-troubleshooting.md)
