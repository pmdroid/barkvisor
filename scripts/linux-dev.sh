#!/usr/bin/env bash
# Prepare a Linux host for BarkVisor development.
# Supports package managers: apt (Ubuntu/Debian), pacman (Arch), apk (Alpine runtime),
# dnf (Fedora). Installs QEMU/firmware deps, Swift (glibc hosts), and SONAME compat.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/linux-distro.sh
source "$ROOT/scripts/lib/linux-distro.sh"
# shellcheck source=lib/linux-swift-compat.sh
source "$ROOT/scripts/lib/linux-swift-compat.sh"

barkvisor_detect_distro
echo "==> BarkVisor linux-dev on ${BARKVISOR_DISTRO_ID:-?} ${BARKVISOR_DISTRO_VERSION:-} ($(uname -m))"

barkvisor_install_dev_packages || true

if barkvisor_is_alpine || ! barkvisor_swift_build_supported; then
  echo
  if barkvisor_is_alpine || { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; then
    echo "This host uses musl (Alpine) — official Swift toolchains are glibc-only."
  else
    echo "This host glibc $(barkvisor_glibc_version 2>/dev/null || echo '?') is below the"
    echo "minimum $(barkvisor_swift_min_glibc) for this distro's Swift channel."
  fi
  echo "  • Runtime: install QEMU/OVMF packages (done best-effort above), run a binary"
  echo "    built on a supported glibc host (Ubuntu 24.04+/Debian 12+/Fedora/Rocky 10+/Arch)."
  echo "  • Build: use those distros — or Docker (Dockerfile)."
  exit 0
fi

echo "==> Swift channel: $(barkvisor_swift_channel)"
"$ROOT/scripts/install-swift-linux.sh" || true
barkvisor_ensure_swift_compat || true
barkvisor_export_swift_env

echo
echo "System packages installed (best-effort)."
if command -v swift >/dev/null 2>&1 && swift build --help >/dev/null 2>&1; then
  swift --version | head -1
  echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
else
  echo "Swift not usable yet. Re-run: ./scripts/install-swift-linux.sh"
fi
echo "Next: swift build && ./scripts/linux-smoke.sh"
echo "      or:   swift run BarkVisorApp"
