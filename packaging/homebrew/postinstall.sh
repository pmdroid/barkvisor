#!/bin/bash
# Create the _barkvisor user and Device data directories (PAS-291).
# Does not install the privileged helper LaunchDaemon (PAS-292).
set -euo pipefail

BARKVISOR_USER="_barkvisor"
BARKVISOR_GID=300
DATA_DIR=/var/lib/barkvisor
RUN_DIR=/var/run/barkvisor
LOG_DIR=/var/log/barkvisor

if [ "$(id -u)" -ne 0 ]; then
    echo "BarkVisor Homebrew postinstall must run as root (sudo)." >&2
    exit 1
fi

find_available_id() {
    local start=$1
    local id=$start
    while dscl . -list /Users UniqueID 2>/dev/null | awk '{print $2}' | grep -q "^${id}$" ||
        dscl . -list /Groups PrimaryGroupID 2>/dev/null | awk '{print $2}' | grep -q "^${id}$"; do
        id=$((id + 1))
    done
    echo "$id"
}

if ! dscl . -read "/Groups/$BARKVISOR_USER" &>/dev/null; then
    GID=$(find_available_id "$BARKVISOR_GID")
    dscl . -create "/Groups/$BARKVISOR_USER"
    dscl . -create "/Groups/$BARKVISOR_USER" PrimaryGroupID "$GID"
    dscl . -create "/Groups/$BARKVISOR_USER" RealName "BarkVisor Service"
    echo "Created group $BARKVISOR_USER with GID $GID"
else
    GID=$(dscl . -read "/Groups/$BARKVISOR_USER" PrimaryGroupID | awk '{print $2}')
fi

if ! dscl . -read "/Users/$BARKVISOR_USER" &>/dev/null; then
    UID_VAL=$(find_available_id "$BARKVISOR_GID")
    dscl . -create "/Users/$BARKVISOR_USER"
    dscl . -create "/Users/$BARKVISOR_USER" UniqueID "$UID_VAL"
    dscl . -create "/Users/$BARKVISOR_USER" PrimaryGroupID "$GID"
    dscl . -create "/Users/$BARKVISOR_USER" UserShell /usr/bin/false
    dscl . -create "/Users/$BARKVISOR_USER" NFSHomeDirectory /var/empty
    dscl . -create "/Users/$BARKVISOR_USER" RealName "BarkVisor Service"
    dscl . -create "/Users/$BARKVISOR_USER" IsHidden 1
    echo "Created user $BARKVISOR_USER with UID $UID_VAL"
fi

# brew services runs as _barkvisor and cannot mkdir these. The daemon
# exits if /var/run/barkvisor is missing rather than swallowing mkdir.
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

chown -R "$BARKVISOR_USER:$BARKVISOR_USER" "$DATA_DIR" "$LOG_DIR" "$RUN_DIR"
chmod 0755 "$DATA_DIR" "$LOG_DIR"
chmod 0700 "$RUN_DIR"
