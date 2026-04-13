#!/bin/bash
set -e

BARKVISOR_USER="_barkvisor"
BARKVISOR_GID=300

# --- Find next available UID/GID (starting from 300) ---
find_available_id() {
    local start=$1
    local id=$start
    while dscl . -list /Users UniqueID 2>/dev/null | awk '{print $2}' | grep -q "^${id}$" || \
          dscl . -list /Groups PrimaryGroupID 2>/dev/null | awk '{print $2}' | grep -q "^${id}$"; do
        id=$((id + 1))
    done
    echo "$id"
}

# --- Create system group ---
if ! dscl . -read /Groups/$BARKVISOR_USER &>/dev/null; then
    GID=$(find_available_id $BARKVISOR_GID)
    dscl . -create /Groups/$BARKVISOR_USER
    dscl . -create /Groups/$BARKVISOR_USER PrimaryGroupID "$GID"
    dscl . -create /Groups/$BARKVISOR_USER RealName "BarkVisor Service"
    echo "Created group $BARKVISOR_USER with GID $GID"
else
    GID=$(dscl . -read /Groups/$BARKVISOR_USER PrimaryGroupID | awk '{print $2}')
fi

# --- Create system user ---
if ! dscl . -read /Users/$BARKVISOR_USER &>/dev/null; then
    UID_VAL=$(find_available_id $BARKVISOR_GID)
    dscl . -create /Users/$BARKVISOR_USER
    dscl . -create /Users/$BARKVISOR_USER UniqueID "$UID_VAL"
    dscl . -create /Users/$BARKVISOR_USER PrimaryGroupID "$GID"
    dscl . -create /Users/$BARKVISOR_USER UserShell /usr/bin/false
    dscl . -create /Users/$BARKVISOR_USER NFSHomeDirectory /var/empty
    dscl . -create /Users/$BARKVISOR_USER RealName "BarkVisor Service"
    dscl . -create /Users/$BARKVISOR_USER IsHidden 1
    echo "Created user $BARKVISOR_USER with UID $UID_VAL"
fi

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

chown -R $BARKVISOR_USER:$BARKVISOR_USER /var/lib/barkvisor
chown -R $BARKVISOR_USER:$BARKVISOR_USER /var/log/barkvisor
chown -R $BARKVISOR_USER:$BARKVISOR_USER /var/run/barkvisor

# Ensure wrapper script is executable
chmod +x /usr/local/libexec/barkvisor/barkvisor-wrapper.sh

# --- Clean up downloaded update packages ---
rm -f /var/lib/barkvisor/updates/*.pkg

# --- Fix dylib rpaths for bundled binaries ---
for bin in /usr/local/libexec/barkvisor/*; do
    [ -x "$bin" ] || continue
    install_name_tool -add_rpath /usr/local/lib/barkvisor "$bin" 2>/dev/null || true
done

# --- (Re)load LaunchDaemons ---
launchctl bootout system/dev.barkvisor 2>/dev/null || true
launchctl bootout system/dev.barkvisor.helper 2>/dev/null || true

# Wait for services to fully unload before re-bootstrapping
for i in $(seq 1 30); do
    if ! launchctl print system/dev.barkvisor &>/dev/null && \
       ! launchctl print system/dev.barkvisor.helper &>/dev/null; then
        break
    fi
    sleep 1
done

launchctl bootstrap system /Library/LaunchDaemons/dev.barkvisor.helper.plist
launchctl bootstrap system /Library/LaunchDaemons/dev.barkvisor.plist

echo ""
echo "========================================="
echo "  BarkVisor installed successfully!"
echo "  Open http://localhost:7777 to complete setup."
echo "========================================="
