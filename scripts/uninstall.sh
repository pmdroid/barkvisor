#!/bin/bash
set -euo pipefail

# =============================================================================
# BarkVisor Uninstaller
# =============================================================================
# Removes the BarkVisor daemon, privileged helper, all binaries, libraries,
# firmware, frontend, LaunchDaemons, and optionally all user data.
#
# Usage:
#   sudo ./uninstall.sh              # Uninstall, keep data
#   sudo ./uninstall.sh --purge      # Uninstall and remove all data + system user
# =============================================================================

PURGE=false
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=true ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root: sudo $0 $*"
    exit 1
fi

log() { echo "==> $1"; }

# ---- Stop and unload LaunchDaemons ----

for svc in dev.barkvisor dev.barkvisor.helper; do
    if launchctl print "system/$svc" &>/dev/null; then
        log "Stopping $svc..."
        launchctl bootout "system/$svc" 2>/dev/null || true
    fi
done

# Small delay to let processes exit
sleep 1

# ---- Remove LaunchDaemon plists ----

for plist in /Library/LaunchDaemons/dev.barkvisor.plist \
             /Library/LaunchDaemons/dev.barkvisor.helper.plist; do
    if [ -f "$plist" ]; then
        log "Removing $plist"
        rm -f "$plist"
    fi
done

# ---- Remove privileged helper ----

if [ -f /Library/PrivilegedHelperTools/dev.barkvisor.helper ]; then
    log "Removing privileged helper..."
    rm -f /Library/PrivilegedHelperTools/dev.barkvisor.helper
fi

# ---- Remove binaries, libraries, and shared data ----

if [ -f /usr/local/bin/barkvisor ]; then
    log "Removing /usr/local/bin/barkvisor"
    rm -f /usr/local/bin/barkvisor
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

# ---- Remove legacy .app install (if present) ----

if [ -d /Applications/BarkVisor.app ]; then
    log "Removing /Applications/BarkVisor.app (legacy)"
    rm -rf /Applications/BarkVisor.app
fi

# ---- Remove socket_vmnet bridge plists installed by the helper ----

for plist in /Library/LaunchDaemons/dev.barkvisor.bridge.*.plist; do
    [ -f "$plist" ] || continue
    svc="$(basename "$plist" .plist)"
    launchctl bootout "system/$svc" 2>/dev/null || true
    log "Removing bridge plist $plist"
    rm -f "$plist"
done

# ---- Remove pkg receipts ----

for receipt in dev.barkvisor dev.barkvisor.app; do
    if pkgutil --pkgs 2>/dev/null | grep -q "^${receipt}$"; then
        log "Removing installer receipt: $receipt"
        pkgutil --forget "$receipt" 2>/dev/null || true
    fi
done

# ---- Purge data, logs, and system user ----

if [ "$PURGE" = true ]; then
    log "Purging all data..."

    # Runtime data
    for dir in /var/lib/barkvisor /var/log/barkvisor /var/run/barkvisor; do
        if [ -d "$dir" ]; then
            rm -rf "$dir"
            log "  Removed $dir"
        fi
    done

    # Legacy per-user data
    for home in /Users/*/Library/Application\ Support/BarkVisor; do
        if [ -d "$home" ]; then
            rm -rf "$home"
            log "  Removed $home"
        fi
    done

    # Remove system user and group
    if dscl . -read /Users/_barkvisor &>/dev/null; then
        log "  Removing _barkvisor user"
        dscl . -delete /Users/_barkvisor
    fi
    if dscl . -read /Groups/_barkvisor &>/dev/null; then
        log "  Removing _barkvisor group"
        dscl . -delete /Groups/_barkvisor
    fi
else
    log "User data preserved at /var/lib/barkvisor."
    log "Run with --purge to also remove data, logs, and the _barkvisor system user."
fi

echo ""
log "BarkVisor has been uninstalled."
