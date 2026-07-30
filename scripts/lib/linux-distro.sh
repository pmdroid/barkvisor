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
      for pkg in "$@"; do
        barkvisor_sudo apt-get install -y -qq "$pkg" 2>/dev/null || true
      done
      ;;
    pacman)
      barkvisor_sudo pacman -Sy --noconfirm --needed "$@" 2>/dev/null || true
      ;;
    apk)
      barkvisor_sudo apk add --no-cache "$@" 2>/dev/null || true
      ;;
    dnf)
      barkvisor_sudo dnf install -y "$@" 2>/dev/null || true
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
      local pkgs=(
        tar gzip git curl ca-certificates gcc gcc-c++ make pkgconf-pkg-config
        libcurl-devel libxml2-devel sqlite-devel ncurses-devel
        zlib-devel libzstd-devel libedit-devel libuuid-devel
        qemu-img genisoimage swtpm
        qemu-system-x86 edk2-ovmf qemu-system-aarch64 edk2-aarch64
      )
      barkvisor_pkg_install "${pkgs[@]}"
      ;;
    *)
      echo "warning: install QEMU, OVMF/AAVMF, build-essential equivalents manually" >&2
      return 1
      ;;
  esac
}

# True if this host can run official Swift toolchains (glibc).
barkvisor_swift_build_supported() {
  if barkvisor_is_alpine; then
    return 1
  fi
  # musl without being alpine-labelled
  if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
    return 1
  fi
  return 0
}
