#!/usr/bin/env bash
# Prepare a Linux host for BarkVisor development (any current Ubuntu).
# Installs system packages, Swift toolchain (if missing), and SONAME compat.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/linux-swift-compat.sh
source "$ROOT/scripts/lib/linux-swift-compat.sh"

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq \
  curl ca-certificates binutils git build-essential pkg-config \
  libcurl4-openssl-dev libxml2-dev libsqlite3-dev libncurses-dev \
  zlib1g-dev libzstd-dev libedit-dev uuid-dev \
  qemu-system-arm qemu-utils qemu-efi-aarch64 genisoimage \
  || true

# Optional x86 guests on amd64 hosts
if [[ "$(uname -m)" = "x86_64" ]]; then
  $SUDO apt-get install -y -qq qemu-system-x86 ovmf || true
fi

# Optional TPM
$SUDO apt-get install -y -qq swtpm || true

# Swift + SONAME shims (works on 22.04 / 24.04 / 26.04)
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
