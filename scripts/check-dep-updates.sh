#!/bin/bash
set -euo pipefail

# =============================================================================
# Dependency Version Checker
# =============================================================================
# Checks pinned dependency versions in build-release.sh against latest upstream
# releases. Outputs a summary and optionally updates the file in place.
#
# Usage:
#   ./scripts/check-dep-updates.sh          # Check only (dry run)
#   ./scripts/check-dep-updates.sh --update  # Update build-release.sh in place
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/build-release.sh"
UPDATE=false

for arg in "$@"; do
    case "$arg" in
        --update) UPDATE=true ;;
    esac
done

UPDATES_FOUND=false

check_version() {
    local name="$1" current="$2" latest="$3" var_name="$4"

    if [ "$current" = "$latest" ]; then
        echo "  ✓ $name: $current (up to date)"
    else
        echo "  ✗ $name: $current → $latest"
        UPDATES_FOUND=true
        if [ "$UPDATE" = true ]; then
            sed -i '' "s|${var_name}:-${current}|${var_name}:-${latest}|g" "$BUILD_SCRIPT"
            echo "    Updated in build-release.sh"
        fi
    fi
}

echo "Checking dependency versions..."
echo ""

# QEMU — latest stable from download page
CURRENT_QEMU=$(grep 'QEMU_VERSION=' "$BUILD_SCRIPT" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
LATEST_QEMU=$(curl -fsSL "https://download.qemu.org/" 2>/dev/null \
    | grep -oE 'qemu-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.xz"' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)
check_version "QEMU" "$CURRENT_QEMU" "${LATEST_QEMU:-$CURRENT_QEMU}" "QEMU_VERSION"

# xz-utils — latest tag from GitHub
CURRENT_XZ=$(grep 'XZ_VERSION=' "$BUILD_SCRIPT" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
LATEST_XZ=$(git ls-remote --tags https://github.com/tukaani-project/xz.git 2>/dev/null \
    | grep -v '{}' | grep -oE 'v([0-9]+\.[0-9]+\.[0-9]+)$' \
    | sed 's/^v//' | sort -V | tail -1)
check_version "xz-utils" "$CURRENT_XZ" "${LATEST_XZ:-$CURRENT_XZ}" "XZ_VERSION"

# libtpms — latest tag from GitHub
CURRENT_LIBTPMS=$(grep 'LIBTPMS_VERSION=' "$BUILD_SCRIPT" | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
LATEST_LIBTPMS=$(git ls-remote --tags https://github.com/stefanberger/libtpms.git 2>/dev/null \
    | grep -v '{}' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
check_version "libtpms" "$CURRENT_LIBTPMS" "${LATEST_LIBTPMS:-$CURRENT_LIBTPMS}" "LIBTPMS_VERSION"

# swtpm — latest stable tag from GitHub (exclude rc)
CURRENT_SWTPM=$(grep 'SWTPM_VERSION=' "$BUILD_SCRIPT" | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
LATEST_SWTPM=$(git ls-remote --tags https://github.com/stefanberger/swtpm.git 2>/dev/null \
    | grep -v '{}' | grep -v 'rc' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
check_version "swtpm" "$CURRENT_SWTPM" "${LATEST_SWTPM:-$CURRENT_SWTPM}" "SWTPM_VERSION"

# socket_vmnet — latest stable tag from GitHub (exclude rc)
CURRENT_VMNET=$(grep 'SOCKET_VMNET_VERSION=' "$BUILD_SCRIPT" | head -1 | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
LATEST_VMNET=$(git ls-remote --tags https://github.com/lima-vm/socket_vmnet.git 2>/dev/null \
    | grep -v '{}' | grep -v 'rc' | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
check_version "socket_vmnet" "$CURRENT_VMNET" "${LATEST_VMNET:-$CURRENT_VMNET}" "SOCKET_VMNET_VERSION"

# AAVMF — latest deb from Ubuntu mirror
CURRENT_AAVMF=$(grep 'AAVMF_DEB_VERSION=' "$BUILD_SCRIPT" | head -1 | grep -oE '[0-9]+\.[0-9]+-[0-9a-z]+')
LATEST_AAVMF=$(curl -fsSL "https://mirrors.edge.kernel.org/ubuntu/pool/main/e/edk2/" 2>/dev/null \
    | grep -oE 'qemu-efi-aarch64_([^"]+)_all\.deb' \
    | sed 's/qemu-efi-aarch64_//;s/_all\.deb//' | sort -V | tail -1)
check_version "AAVMF" "$CURRENT_AAVMF" "${LATEST_AAVMF:-$CURRENT_AAVMF}" "AAVMF_DEB_VERSION"

echo ""
if [ "$UPDATES_FOUND" = true ]; then
    echo "Updates available."
    exit 2  # Signal to CI that updates were found
else
    echo "All dependencies are up to date."
    exit 0
fi
