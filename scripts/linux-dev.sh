#!/usr/bin/env bash
# Prepare a Linux host for BarkVisor development (Ubuntu 24.04 recommended).
# Does not install Swift (use official tarball — see docs/getting-started-linux.md).
set -euo pipefail

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

echo
echo "System packages installed (best-effort)."
if command -v swift >/dev/null 2>&1; then
  swift --version | head -1
else
  echo "Swift not found. Install Ubuntu 24.04 toolchain from https://www.swift.org/install/linux/"
fi
echo "Next: swift build && ./scripts/linux-smoke.sh"
echo "      or:   swift run BarkVisorApp"
