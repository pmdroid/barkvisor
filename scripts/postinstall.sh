#!/bin/bash
set -e

# Appliance LaunchDaemon runs as root. Do not create a dedicated daemon user.
# Data dirs are owned by root. Leftover system users from older pkgs are
# removed only by scripts/uninstall.sh --purge.

# --- Create directories ---
mkdir -p /var/lib/barkvisor/backups
mkdir -p /var/lib/barkvisor/firmware
mkdir -p /var/lib/barkvisor/images
mkdir -p /var/lib/barkvisor/disks
mkdir -p /var/lib/barkvisor/cloud-init
mkdir -p /var/lib/barkvisor/efivars
mkdir -p /var/lib/barkvisor/monitor
mkdir -p /var/lib/barkvisor/tus-uploads
mkdir -p /var/lib/barkvisor/pids
mkdir -p /var/lib/barkvisor/console
mkdir -p /var/log/barkvisor
mkdir -p /var/run/barkvisor

chmod 0755 /var/lib/barkvisor /var/log/barkvisor
chmod 0700 /var/run/barkvisor

# --- Clean up downloaded update packages ---
rm -f /var/lib/barkvisor/updates/*.pkg

# --- Fix dylib rpaths for bundled binaries ---
for bin in /usr/local/libexec/barkvisor/*; do
    [ -x "$bin" ] || continue
    install_name_tool -add_rpath /usr/local/lib/barkvisor "$bin" 2>/dev/null || true
done

# --- Drop leftover privileged helper from older pkgs (PAS-294) ---
launchctl bootout system/dev.barkvisor.helper 2>/dev/null || true
rm -f /Library/LaunchDaemons/dev.barkvisor.helper.plist
rm -f /Library/PrivilegedHelperTools/dev.barkvisor.helper
rm -f /usr/local/libexec/dev.barkvisor.helper
rm -f /usr/local/libexec/barkvisor/dev.barkvisor.helper
rm -f /usr/local/libexec/BarkVisorHelper
rm -f /usr/local/libexec/barkvisor/BarkVisorHelper

# --- (Re)load LaunchDaemons ---
launchctl bootout system/dev.barkvisor 2>/dev/null || true

# Wait for the daemon to fully unload before re-bootstrapping
for i in $(seq 1 30); do
    if ! launchctl print system/dev.barkvisor &>/dev/null; then
        break
    fi
    sleep 1
done

launchctl bootstrap system /Library/LaunchDaemons/dev.barkvisor.plist

echo ""
echo "========================================="
echo "  BarkVisor installed successfully!"
echo "  Open http://localhost:7777 to complete setup."
echo "========================================="
