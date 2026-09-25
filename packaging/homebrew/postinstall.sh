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

if ! id barkvisor >/dev/null 2>&1; then
  next_id=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1)
  next_id=$((next_id + 1))
  dscl . -create /Groups/barkvisor
  dscl . -create /Groups/barkvisor PrimaryGroupID "$next_id"
  dscl . -create /Users/barkvisor
  dscl . -create /Users/barkvisor UserShell /usr/bin/false
  dscl . -create /Users/barkvisor UniqueID "$next_id"
  dscl . -create /Users/barkvisor PrimaryGroupID "$next_id"
  dscl . -create /Groups/barkvisor GroupMembership barkvisor
fi

# brew services require_root runs as root and still cannot mkdir these before
# first start. The daemon exits if /var/run/barkvisor is missing rather than
# swallowing mkdir.
schema="$DATA_DIR/schema-version"
if [ -f "$schema" ]; then
  on_disk=$(tr -cd '0-9' < "$schema" || true)
  if [ -n "$on_disk" ] && [ "$on_disk" -gt 1 ]; then
    echo "unsupported downgrade: schema $on_disk" >&2
    exit 1
  fi
fi

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
if id barkvisor >/dev/null 2>&1; then
  chgrp barkvisor "$RUN_DIR"
  chmod 0770 "$RUN_DIR"
else
  chmod 0700 "$RUN_DIR"
fi
if [ ! -f "$schema" ]; then
  printf '1\n' > "$schema"
fi

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
server_src="$script_dir/homebrew.mxcl.barkvisor-server.plist"
server_dst=/Library/LaunchDaemons/homebrew.mxcl.barkvisor-server.plist
if [ -f "$server_src" ]; then
  cp "$server_src" "$server_dst"
  launchctl bootstrap system "$server_dst" 2>/dev/null || true
fi

# Drop leftover privileged helper from older installs (PAS-294).
# A loaded leftover reconnects ~15s and logs XPC invalidation to Device stderr.
launchctl bootout system/dev.barkvisor.helper 2>/dev/null || true
rm -f /Library/LaunchDaemons/dev.barkvisor.helper.plist
rm -f /Library/PrivilegedHelperTools/dev.barkvisor.helper
rm -f /usr/local/libexec/dev.barkvisor.helper
rm -f /usr/local/libexec/barkvisor/dev.barkvisor.helper
rm -f /usr/local/libexec/BarkVisorHelper
rm -f /usr/local/libexec/barkvisor/BarkVisorHelper
