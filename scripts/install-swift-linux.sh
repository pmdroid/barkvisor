#!/usr/bin/env bash
# Install an official Swift Linux toolchain + SONAME compatibility for this host.
#
# Works on Ubuntu 22.04, 24.04, 26.04 (and similar). On hosts newer than the
# latest Swift-supported LTS, installs that LTS toolchain and adds compat libs
# (see scripts/lib/linux-swift-compat.sh).
#
# Usage:
#   ./scripts/install-swift-linux.sh              # install to /opt/swift
#   SWIFT_VERSION=6.2.3 PREFIX=$HOME/swift ./scripts/install-swift-linux.sh
#   ./scripts/install-swift-linux.sh --check      # only ensure compat + print env
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/linux-swift-compat.sh
source "$ROOT/scripts/lib/linux-swift-compat.sh"

SWIFT_VERSION="${SWIFT_VERSION:-6.2.3}"
PREFIX="${PREFIX:-/opt/swift}"
CHECK_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --check) CHECK_ONLY=1 ;;
    -h | --help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
  esac
done

if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  echo "Host: ${PRETTY_NAME:-$NAME $VERSION_ID} ($(uname -m))"
  echo "Swift channel: $(barkvisor_swift_ubuntu_channel "${VERSION_ID:-}")"
fi

echo "==> ensuring system packages + SONAME compat"
barkvisor_ensure_swift_compat || true
barkvisor_export_swift_env

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  if command -v swift >/dev/null 2>&1; then
    swift --version | head -2
    echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
    echo "swift OK"
  else
    echo "swift not on PATH (run without --check to install)"
    exit 1
  fi
  exit 0
fi

if command -v swift >/dev/null 2>&1 && swift build --help >/dev/null 2>&1; then
  echo "Swift already usable:"
  swift --version | head -2
  echo "export LD_LIBRARY_PATH=\"${LD_LIBRARY_PATH:-}\""
  exit 0
fi

URL="$(barkvisor_swift_download_url "$SWIFT_VERSION")"
echo "==> downloading $URL"
TMP="$(mktemp -d /tmp/swift-install.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/swift.tgz" "$URL"

echo "==> installing to $PREFIX"
if [[ -w "$(dirname "$PREFIX")" ]] || [[ "$(id -u)" -eq 0 ]]; then
  mkdir -p "$PREFIX"
  tar -xzf "$TMP/swift.tgz" -C "$PREFIX" --strip-components=1
else
  sudo mkdir -p "$PREFIX"
  sudo tar -xzf "$TMP/swift.tgz" -C "$PREFIX" --strip-components=1
fi

# Re-apply compat after toolchain lands (and export PATH)
barkvisor_ensure_swift_compat || true
barkvisor_export_swift_env
export PATH="${PREFIX}/usr/bin:${PATH}"

if ! swift build --help >/dev/null 2>&1; then
  echo "error: swift still not runnable after install" >&2
  echo "  LD_LIBRARY_PATH=$LD_LIBRARY_PATH" >&2
  ldd "${PREFIX}/usr/bin/swift-build" 2>&1 | grep "not found" || true
  exit 1
fi

echo
echo "Swift installed:"
swift --version | head -2
echo
echo "Add to your shell profile:"
echo "  export PATH=\"${PREFIX}/usr/bin:\$PATH\""
if [[ -d "${BARKVISOR_COMPAT_DIR:-}" ]]; then
  echo "  export LD_LIBRARY_PATH=\"${BARKVISOR_COMPAT_DIR}\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}\""
fi
echo "  # or: source $ROOT/scripts/lib/linux-swift-compat.sh && barkvisor_export_swift_env"
