# Distro detection + package install helpers for Linux hosts.
#
# Supported *build* targets (glibc + official Swift toolchains):
#   Ubuntu / Debian (apt), Arch (pacman, uses Ubuntu LTS Swift tarball + compat)
# Runtime-only note for Alpine (musl): no official Swift toolchain; see docs.
#
# Usage (after ROOT is set):
#   # shellcheck source=lib/linux-distro.sh
#   source "$ROOT/scripts/lib/linux-distro.sh"
#   barkvisor_detect_distro
#   barkvisor_install_dev_packages

barkvisor_detect_distro() {
  BARKVISOR_DISTRO_ID="unknown"
  BARKVISOR_DISTRO_LIKE=""
  BARKVISOR_DISTRO_VERSION=""
  BARKVISOR_PKG_MGR="unknown"

  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    BARKVISOR_DISTRO_ID="${ID:-unknown}"
    BARKVISOR_DISTRO_LIKE="${ID_LIKE:-}"
    BARKVISOR_DISTRO_VERSION="${VERSION_ID:-}"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    BARKVISOR_PKG_MGR="apt"
  elif command -v pacman >/dev/null 2>&1; then
    BARKVISOR_PKG_MGR="pacman"
  elif command -v apk >/dev/null 2>&1; then
    BARKVISOR_PKG_MGR="apk"
  elif command -v dnf >/dev/null 2>&1; then
    BARKVISOR_PKG_MGR="dnf"
  elif command -v zypper >/dev/null 2>&1; then
    BARKVISOR_PKG_MGR="zypper"
  fi

  export BARKVISOR_DISTRO_ID BARKVISOR_DISTRO_LIKE BARKVISOR_DISTRO_VERSION BARKVISOR_PKG_MGR
}

barkvisor_is_debian_family() {
  barkvisor_detect_distro
  case "$BARKVISOR_DISTRO_ID" in
    debian | ubuntu | linuxmint | pop | raspbian) return 0 ;;
  esac
  case " $BARKVISOR_DISTRO_LIKE " in
    *" debian "* | *" ubuntu "*) return 0 ;;
  esac
  return 1
}

barkvisor_is_arch_family() {
  barkvisor_detect_distro
  case "$BARKVISOR_DISTRO_ID" in
    arch | manjaro | endeavouros | garuda) return 0 ;;
  esac
  case " $BARKVISOR_DISTRO_LIKE " in
    *" arch "*) return 0 ;;
  esac
  return 1
}

barkvisor_is_alpine() {
  barkvisor_detect_distro
  [[ "$BARKVISOR_DISTRO_ID" == "alpine" ]] || [[ "$BARKVISOR_PKG_MGR" == "apk" ]]
}

barkvisor_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "error: root or sudo required for: $*" >&2
    return 1
  fi
}

# Install packages with the host package manager (best-effort; ignores missing names).
barkvisor_pkg_install() {
  local pkg
  [[ "$#" -eq 0 ]] && return 0
  barkvisor_detect_distro
  case "$BARKVISOR_PKG_MGR" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      barkvisor_sudo apt-get update -qq || true
      # Bulk first (fast); if any name is missing, fall back per-package.
      if ! barkvisor_sudo apt-get install -y -qq "$@" 2>/dev/null; then
        for pkg in "$@"; do
          barkvisor_sudo apt-get install -y -qq "$pkg" 2>/dev/null || true
        done
      fi
      ;;
    pacman)
      barkvisor_sudo pacman -Sy --noconfirm --needed "$@" 2>/dev/null || true
      ;;
    apk)
      barkvisor_sudo apk add --no-cache "$@" 2>/dev/null || true
      ;;
    dnf)
      # Bulk first; fall back per-package so Fedora vs Rocky name differences
      # (qemu-system-x86 vs qemu-kvm) do not abort the whole set.
      if ! barkvisor_sudo dnf install -y "$@" 2>/dev/null; then
        for pkg in "$@"; do
          barkvisor_sudo dnf install -y "$pkg" 2>/dev/null || true
        done
      fi
      ;;
    zypper)
      barkvisor_sudo zypper --non-interactive install -y "$@" 2>/dev/null || true
      ;;
    *)
      echo "warning: unknown package manager; install build deps manually: $*" >&2
      return 1
      ;;
  esac
}

# Dev/runtime packages needed to build and run BarkVisor + QEMU guests.
barkvisor_install_dev_packages() {
  barkvisor_detect_distro
  local arch
  arch="$(uname -m)"

  echo "==> distro: ${BARKVISOR_DISTRO_ID:-?} ${BARKVISOR_DISTRO_VERSION:-} (pkg=${BARKVISOR_PKG_MGR})"

  case "$BARKVISOR_PKG_MGR" in
    apt)
      local pkgs=(
        curl ca-certificates binutils git build-essential pkg-config
        libcurl4-openssl-dev libsqlite3-dev libncurses-dev
        zlib1g-dev libzstd-dev libedit-dev uuid-dev
        qemu-utils genisoimage swtpm
        # libxml: classic + Ubuntu 26 rename
        libxml2-dev libxml2 libxml2-16
      )
      if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        pkgs+=(qemu-system-arm qemu-efi-aarch64)
      else
        pkgs+=(qemu-system-x86 ovmf qemu-system-arm qemu-efi-aarch64)
      fi
      barkvisor_pkg_install "${pkgs[@]}"
      ;;
    pacman)
      local pkgs=(
        base-devel git curl ca-certificates pkgconf
        curl sqlite ncurses zlib zstd libedit util-linux
        libxml2 qemu-base qemu-system-x86 qemu-system-aarch64
        edk2-ovmf edk2-armvirt cdrtools swtpm
      )
      barkvisor_pkg_install "${pkgs[@]}"
      ;;
    apk)
      # Alpine is musl: Swift.org toolchains are glibc — build is not supported.
      # Still install QEMU + OVMF so a prebuilt BarkVisor binary can run guests.
      echo "warning: Alpine (musl) cannot build with official Swift glibc toolchains." >&2
      echo "  Install a prebuilt binary from a glibc host, or use Docker." >&2
      local pkgs=(
        git curl ca-certificates build-base pkgconf
        curl-dev sqlite-dev ncurses-dev zlib-dev zstd-dev libedit-dev
        libxml2-dev qemu-system-x86_64 qemu-system-aarch64 qemu-img
        ovmf cdrkit swtpm
      )
      barkvisor_pkg_install "${pkgs[@]}"
      ;;
    dnf)
      # Rocky/RHEL/Fedora — include tar (minimal cloud images often omit it).
      # Package IDs diverge: Fedora has qemu-system-*; EL uses qemu-kvm.
      # genisoimage is often genisoimage or xorriso (mkisofs-compat).
      local pkgs=(
        tar gzip git curl ca-certificates gcc gcc-c++ make pkgconf-pkg-config
        glibc-devel binutils
        libcurl-devel libxml2-devel sqlite-devel ncurses-devel
        zlib-devel libzstd-devel libedit-devel libuuid-devel
        qemu-img genisoimage xorriso swtpm edk2-ovmf
        # Fedora names
        qemu-system-x86 qemu-system-aarch64 edk2-aarch64
        # Rocky / Alma / RHEL names
        qemu-kvm
      )
      barkvisor_pkg_install "${pkgs[@]}"
      # RHEL-family ships qemu as /usr/libexec/qemu-kvm only.
      if [[ ! -x /usr/bin/qemu-system-x86_64 ]] && [[ -x /usr/libexec/qemu-kvm ]]; then
        barkvisor_sudo ln -sfn /usr/libexec/qemu-kvm /usr/local/bin/qemu-system-x86_64 2>/dev/null || true
        echo "note: linked /usr/local/bin/qemu-system-x86_64 → /usr/libexec/qemu-kvm"
      fi
      ;;
    *)
      echo "warning: install QEMU, OVMF/AAVMF, build-essential equivalents manually" >&2
      return 1
      ;;
  esac
}

# Print host glibc version (e.g. 2.34) or empty if musl/unknown.
barkvisor_glibc_version() {
  if command -v ldd >/dev/null 2>&1; then
    ldd --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1
  fi
}

# Compare two dotted versions: 0 if $1 >= $2.
barkvisor_version_ge() {
  local a="$1" b="$2"
  local IFS=.
  # shellcheck disable=SC2206
  local -a aa=($a) bb=($b)
  local i
  for i in 0 1 2 3; do
    local x="${aa[i]:-0}" y="${bb[i]:-0}"
    if ((10#$x > 10#$y)); then return 0; fi
    if ((10#$x < 10#$y)); then return 1; fi
  done
  return 0
}

# Minimum glibc for the official Swift.org channel this distro maps to.
# - debian12 toolchain: bookworm (2.36)
# - ubuntu2204: jammy (2.35)
# - ubuntu2404 / fedora39: need ≥ 2.38 (Rocky/RHEL 9 = 2.34 fails here)
barkvisor_swift_min_glibc() {
  barkvisor_detect_distro
  case "${BARKVISOR_DISTRO_ID:-}" in
    debian)
      echo "2.36"
      ;;
    ubuntu)
      case "${BARKVISOR_DISTRO_VERSION:-}" in
        22.* | 22) echo "2.35" ;;
        *) echo "2.38" ;;
      esac
      ;;
    *)
      # Fedora, Rocky/RHEL/Alma, Arch (ubuntu2404 tarball), unknown
      echo "2.38"
      ;;
  esac
}

# True if this host can run an official Swift 6.2+ toolchain for its channel.
# Rocky/RHEL 9 (glibc 2.34) cannot; Debian 12 (2.36) can via the debian12 channel.
barkvisor_swift_build_supported() {
  if barkvisor_is_alpine; then
    return 1
  fi
  if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
    return 1
  fi
  local ver min
  ver="$(barkvisor_glibc_version)"
  min="$(barkvisor_swift_min_glibc)"
  if [[ -z "$ver" ]]; then
    return 0
  fi
  barkvisor_version_ge "$ver" "$min"
}
