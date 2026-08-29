#!/bin/bash
# Create Device data directories as root (PAS-291 / #386).
# Does not create a dedicated daemon user. Does not install a privileged helper (PAS-294).
# Never run Homebrew install as root against a user prefix.
set -euo pipefail

DATA_DIR=/var/lib/barkvisor
RUN_DIR=/var/run/barkvisor
LOG_DIR=/var/log/barkvisor

if [ "$(id -u)" -ne 0 ]; then
    echo "BarkVisor Homebrew postinstall must run as root (sudo)." >&2
    exit 1
fi

# brew services require_root runs as root and still cannot mkdir these before
# first start. The daemon exits if /var/run/barkvisor is missing rather than
# swallowing mkdir.
mkdir -p \
    "$DATA_DIR/backups" \
    "$DATA_DIR/firmware" \
    "$DATA_DIR/images" \
    "$DATA_DIR/disks" \
    "$DATA_DIR/cloud-init" \
    "$DATA_DIR/efivars" \
    "$DATA_DIR/monitor" \
    "$DATA_DIR/tus-uploads" \
    "$DATA_DIR/pids" \
    "$DATA_DIR/console" \
    "$LOG_DIR" \
    "$RUN_DIR"

chmod 0755 "$DATA_DIR" "$LOG_DIR"
chmod 0700 "$RUN_DIR"

# Drop leftover privileged helper from older installs (PAS-294).
# A loaded leftover reconnects ~15s and logs XPC invalidation to Device stderr.
launchctl bootout system/dev.barkvisor.helper 2>/dev/null || true
rm -f /Library/LaunchDaemons/dev.barkvisor.helper.plist
rm -f /Library/PrivilegedHelperTools/dev.barkvisor.helper
rm -f /usr/local/libexec/dev.barkvisor.helper
rm -f /usr/local/libexec/barkvisor/dev.barkvisor.helper
rm -f /usr/local/libexec/BarkVisorHelper
rm -f /usr/local/libexec/barkvisor/BarkVisorHelper
