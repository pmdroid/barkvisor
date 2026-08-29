#!/bin/bash
set -euo pipefail

# =============================================================================
# BarkVisor Uninstaller
# =============================================================================
# Removes the BarkVisor daemon, leftover privileged helper, binaries,
# LaunchDaemons / systemd units, and optionally appliance data under
# /var/lib/barkvisor (root layout, not _barkvisor-only).
#
# Tagged host-bridge files from #378 (bridge.conf allow lines, netplan,
# NetworkManager, systemd-networkd) are removed. Shared br0 is never
# deleted unless the operator passes --remove-bridge AND we created it.
# --purge / --revert may offer that flag; they never default it.
#
# socket_vmnet: stop the service we started. Do not brew uninstall unless
# --uninstall-socket-vmnet is passed.
#
# Usage:
#   sudo ./uninstall.sh                         # uninstall, keep data, keep br0
#   sudo ./uninstall.sh --purge                 # also remove /var/lib/barkvisor
#   sudo ./uninstall.sh --revert                # same tagged cleanup; offer br0
#   sudo ./uninstall.sh --purge --remove-bridge # also delete a created br0
#   sudo ./uninstall.sh --uninstall-socket-vmnet
# =============================================================================

PURGE=false
REVERT=false
REMOVE_BRIDGE=false
UNINSTALL_SOCKET_VMNET=false
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=true ;;
        --revert) REVERT=true ;;
        --remove-bridge) REMOVE_BRIDGE=true ;;
        --uninstall-socket-vmnet) UNINSTALL_SOCKET_VMNET=true ;;
        -h|--help)
            sed -n '4,26p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown flag: $arg" >&2
            exit 2
            ;;
    esac
done

TEST_ROOT="${BARKVISOR_HOST_ROOT:-}"

if [ -z "$TEST_ROOT" ] && [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root: sudo $0 $*"
    exit 1
fi

log() { echo "==> $1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/tagged-bridge-cleanup.sh
. "$SCRIPT_DIR/lib/tagged-bridge-cleanup.sh"

# ---- Stop leftover helper-era and appliance LaunchDaemons (macOS) ----

if [ -z "$TEST_ROOT" ]; then
    for svc in dev.barkvisor dev.barkvisor.helper; do
        if command -v launchctl >/dev/null 2>&1 && launchctl print "system/$svc" &>/dev/null; then
            log "Stopping $svc..."
            launchctl bootout "system/$svc" 2>/dev/null || true
        fi
    done

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop barkvisor.service >/dev/null 2>&1 || true
        systemctl stop barkvisor-agent.service >/dev/null 2>&1 || true
        systemctl disable barkvisor.service >/dev/null 2>&1 || true
        systemctl disable barkvisor-agent.service >/dev/null 2>&1 || true
    fi

    sleep 1
fi

# ---- Remove LaunchDaemon plists + leftover privileged helper (PAS-294) ----

if [ -z "$TEST_ROOT" ]; then
    for plist in /Library/LaunchDaemons/dev.barkvisor.plist \
                 /Library/LaunchDaemons/dev.barkvisor.helper.plist; do
        if [ -f "$plist" ]; then
            log "Removing $plist"
            rm -f "$plist"
        fi
    done

    if [ -f /Library/PrivilegedHelperTools/dev.barkvisor.helper ]; then
        log "Removing leftover privileged helper..."
        rm -f /Library/PrivilegedHelperTools/dev.barkvisor.helper
    fi
    rm -f /usr/local/libexec/dev.barkvisor.helper
    rm -f /usr/local/libexec/barkvisor/dev.barkvisor.helper
fi

# ---- socket_vmnet: stop what we started; do not brew uninstall unless asked ----

if [ -z "$TEST_ROOT" ]; then
    if command -v launchctl >/dev/null 2>&1; then
        if launchctl print system/homebrew.mxcl.socket_vmnet &>/dev/null; then
            log "Stopping Homebrew socket_vmnet service (leaving the formula installed)"
            launchctl bootout system/homebrew.mxcl.socket_vmnet 2>/dev/null || true
        fi
    fi
    if command -v brew >/dev/null 2>&1; then
        brew services stop socket_vmnet >/dev/null 2>&1 || true
    fi
    # Leftover helper-era bridge plists stay in this script (#379 owns socket-vmnet.*.plist).
    for plist in /Library/LaunchDaemons/dev.barkvisor.bridge.*.plist; do
        [ -f "$plist" ] || continue
        svc="$(basename "$plist" .plist)"
        launchctl bootout "system/$svc" 2>/dev/null || true
        log "Removing leftover helper bridge plist $plist"
        rm -f "$plist"
    done

    if [ "$UNINSTALL_SOCKET_VMNET" = true ]; then
        if command -v brew >/dev/null 2>&1; then
            log "Uninstalling Homebrew socket_vmnet because --uninstall-socket-vmnet was passed"
            brew uninstall socket_vmnet || true
        fi
    fi
fi

# ---- Remove binaries, libraries, and shared data ----

if [ -z "$TEST_ROOT" ]; then
    if [ -f /usr/local/bin/barkvisor ]; then
        log "Removing /usr/local/bin/barkvisor"
        rm -f /usr/local/bin/barkvisor
    fi

    if [ -e /usr/local/bin/barkvisor-agent ]; then
        log "Removing /usr/local/bin/barkvisor-agent"
        rm -f /usr/local/bin/barkvisor-agent
    fi

    if [ -d /usr/local/libexec/barkvisor ]; then
        log "Removing /usr/local/libexec/barkvisor/ (QEMU, swtpm, etc.)"
        rm -rf /usr/local/libexec/barkvisor
    fi

    if [ -d /usr/local/lib/barkvisor ]; then
        log "Removing /usr/local/lib/barkvisor/ (shared libraries)"
        rm -rf /usr/local/lib/barkvisor
    fi

    if [ -d /usr/local/share/barkvisor ]; then
        log "Removing /usr/local/share/barkvisor/ (frontend, firmware)"
        rm -rf /usr/local/share/barkvisor
    fi

    if [ -d /Applications/BarkVisor.app ]; then
        log "Removing /Applications/BarkVisor.app (legacy)"
        rm -rf /Applications/BarkVisor.app
    fi

    for receipt in dev.barkvisor dev.barkvisor.app; do
        if command -v pkgutil >/dev/null 2>&1 && pkgutil --pkgs 2>/dev/null | grep -q "^${receipt}$"; then
            log "Removing installer receipt: $receipt"
            pkgutil --forget "$receipt" 2>/dev/null || true
        fi
    done
fi

# ---- Tagged bridge.conf / netplan / NM / networkd (never default-delete br0) ----

log "Removing marker-tagged host-bridge files (shared br0 stays)"
barkvisor_cleanup_tagged_bridge
if [ "$REMOVE_BRIDGE" = true ]; then
    export BARKVISOR_REMOVE_BRIDGE=1
    barkvisor_maybe_remove_bridge
fi
if [ "$PURGE" = true ] || [ "$REVERT" = true ]; then
    if [ "$REMOVE_BRIDGE" != true ]; then
        barkvisor_offer_bridge_removal
    fi
fi

# ---- Purge appliance data (root layout) ----

if [ -n "${BARKVISOR_DATA_DIR:-}" ]; then
    DATA_DIR="$BARKVISOR_DATA_DIR"
elif [ -n "$TEST_ROOT" ]; then
    DATA_DIR="${TEST_ROOT}/var/lib/barkvisor"
else
    DATA_DIR=/var/lib/barkvisor
fi

if [ "$PURGE" = true ]; then
    log "Purging appliance data at ${DATA_DIR}..."

    if [ -n "$TEST_ROOT" ]; then
        set -- \
            "${TEST_ROOT}/var/lib/barkvisor" \
            "${TEST_ROOT}/var/log/barkvisor" \
            "${TEST_ROOT}/var/run/barkvisor"
    else
        set -- /var/lib/barkvisor /var/log/barkvisor /var/run/barkvisor
    fi
    for dir in "$@"; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            log "  Removed $dir"
        fi
    done

    if [ -z "$TEST_ROOT" ]; then
        for home in /Users/*/Library/Application\ Support/BarkVisor; do
            if [ -d "$home" ]; then
                rm -rf "$home"
                log "  Removed $home"
            fi
        done

        # Leftover system user from older pkgs. Appliance data is root-owned.
        if command -v dscl >/dev/null 2>&1; then
            if dscl . -read /Users/_barkvisor &>/dev/null; then
                log "  Removing leftover _barkvisor user"
                dscl . -delete /Users/_barkvisor
            fi
            if dscl . -read /Groups/_barkvisor &>/dev/null; then
                log "  Removing leftover _barkvisor group"
                dscl . -delete /Groups/_barkvisor
            fi
        fi
    fi
else
    log "Appliance data preserved at ${DATA_DIR}."
    log "Run with --purge to also remove data and logs under /var/lib/barkvisor."
fi

echo ""
log "BarkVisor has been uninstalled."
