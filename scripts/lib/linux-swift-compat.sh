# Swift / BarkVisor runtime compatibility for all current Ubuntu versions.
#
# Official Swift Linux toolchains target a specific Ubuntu LTS (22.04 / 24.04).
# Newer hosts (e.g. Ubuntu 26.04 "resolute") ship different library SONAMEs
# (libxml2.so.16 instead of libxml2.so.2), which breaks `swift build` and any
# dynamically linked BarkVisorApp binary built with that toolchain.
#
# This helper installs a small compat directory of symlinks and exports
# LD_LIBRARY_PATH so both the toolchain and the daemon resolve correctly.
#
# Usage (after ROOT is set):
#   # shellcheck source=lib/linux-swift-compat.sh
#   source "$ROOT/scripts/lib/linux-swift-compat.sh"
#   barkvisor_ensure_swift_compat
#   barkvisor_export_swift_env

BARKVISOR_COMPAT_DIR="${BARKVISOR_COMPAT_DIR:-/usr/local/lib/barkvisor/compat}"

barkvisor_host_multiarch() {
  if command -v dpkg-architecture >/dev/null 2>&1; then
    dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null && return 0
  fi
  case "$(uname -m)" in
    x86_64 | amd64) echo "x86_64-linux-gnu" ;;
    aarch64 | arm64) echo "aarch64-linux-gnu" ;;
    *) echo "x86_64-linux-gnu" ;;
  esac
}

barkvisor_lib_dirs() {
  local ma
  ma="$(barkvisor_host_multiarch)"
  printf '%s\n' "/usr/lib/${ma}" "/lib/${ma}" /usr/lib /lib
}

# Return 0 if SONAME is already visible to the dynamic linker.
barkvisor_soname_present() {
  local soname="$1" d
  if command -v ldconfig >/dev/null 2>&1; then
    ldconfig -p 2>/dev/null | grep -qF "${soname} " && return 0
  fi
  for d in $(barkvisor_lib_dirs); do
    [[ -e "${d}/${soname}" ]] && return 0
  done
  # Also honor an already-populated compat dir.
  [[ -e "${BARKVISOR_COMPAT_DIR}/${soname}" ]] && return 0
  return 1
}

# Find a real library that can satisfy a missing SONAME.
barkvisor_find_compat_target() {
  local soname="$1" d cand

  for d in $(barkvisor_lib_dirs); do
    if [[ -e "${d}/${soname}" ]]; then
      echo "${d}/${soname}"
      return 0
    fi
  done

  case "$soname" in
    libxml2.so.2)
      # Ubuntu 26+ / Debian trixie+: package provides libxml2.so.16
      # Prefer the real SONAME over the development linker name (libxml2.so).
      for d in $(barkvisor_lib_dirs); do
        if [[ -e "${d}/libxml2.so.16" ]]; then
          echo "${d}/libxml2.so.16"
          return 0
        fi
      done
      for d in $(barkvisor_lib_dirs); do
        # shellcheck disable=SC2012
        if compgen -G "${d}/libxml2.so.2.*" >/dev/null 2>&1; then
          # shellcheck disable=SC2012
          ls -1 "${d}"/libxml2.so.2.* 2>/dev/null | head -1
          return 0
        fi
        if [[ -e "${d}/libxml2.so" ]]; then
          # Resolve symlink to real file when possible
          readlink -f "${d}/libxml2.so" 2>/dev/null || echo "${d}/libxml2.so"
          return 0
        fi
      done
      ;;
    libncurses.so.6 | libtinfo.so.6)
      # Arch ships only wide-char SONAMEs (libncursesw / libtinfo.so.6 sometimes).
      # Ubuntu Swift toolchains link the non-wide libncurses.so.6.
      for d in $(barkvisor_lib_dirs); do
        if [[ -e "${d}/libncursesw.so.6" ]]; then
          echo "${d}/libncursesw.so.6"
          return 0
        fi
        if [[ -e "${d}/libtinfo.so.6" ]]; then
          echo "${d}/libtinfo.so.6"
          return 0
        fi
        if [[ -e "${d}/libncursesw.so" ]]; then
          readlink -f "${d}/libncursesw.so" 2>/dev/null || echo "${d}/libncursesw.so"
          return 0
        fi
      done
      ;;
  esac
  return 1
}

barkvisor_ensure_compat_dir() {
  local dir="${1:-$BARKVISOR_COMPAT_DIR}"
  if [[ -d "$dir" && -w "$dir" ]]; then
    echo "$dir"
    return 0
  fi
  if mkdir -p "$dir" 2>/dev/null && [[ -w "$dir" ]]; then
    BARKVISOR_COMPAT_DIR="$dir"
    echo "$dir"
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo mkdir -p "$dir" 2>/dev/null; then
    BARKVISOR_COMPAT_DIR="$dir"
    echo "$dir"
    return 0
  fi
  # Unprivileged fallback
  dir="${XDG_DATA_HOME:-$HOME/.local/share}/barkvisor/compat"
  mkdir -p "$dir"
  BARKVISOR_COMPAT_DIR="$dir"
  echo "$dir"
}

barkvisor_install_soname() {
  local soname="$1"
  local compat_dir target dest

  if barkvisor_soname_present "$soname"; then
    return 0
  fi
  target="$(barkvisor_find_compat_target "$soname" || true)"
  if [[ -z "$target" ]]; then
    echo "warning: cannot satisfy missing ${soname}" >&2
    return 1
  fi
  compat_dir="$(barkvisor_ensure_compat_dir)"
  dest="${compat_dir}/${soname}"
  if [[ -e "$dest" || -L "$dest" ]]; then
    return 0
  fi
  if ln -sfn "$target" "$dest" 2>/dev/null; then
    :
  else
    sudo ln -sfn "$target" "$dest"
  fi
  echo "compat: ${soname} -> ${target} (via ${compat_dir})"
}

barkvisor_required_sonames() {
  # Extend this list if future Ubuntu bumps break additional Swift deps.
  # libncurses.so.6: Arch provides only libncursesw.so.6.
  printf '%s\n' "libxml2.so.2" "libncurses.so.6" "libtinfo.so.6"
}

# Install base runtime packages (best-effort, multi-distro) + SONAME shims.
barkvisor_ensure_swift_compat() {
  local soname failed=0

  if command -v apt-get >/dev/null 2>&1; then
    # Install one package at a time so renamed Ubuntu packages (libxml2 →
    # libxml2-16, libcurl4 → libcurl4t64) do not abort the whole set.
    local packages=(
      ca-certificates zlib1g libzstd1 libedit2 libsqlite3-0 libncurses6
      libxml2-16 libxml2 libcurl4t64 libcurl4
    )
    local pkg
    for pkg in "${packages[@]}"; do
      if [[ "$(id -u)" -eq 0 ]]; then
        apt-get install -y -qq "$pkg" 2>/dev/null || true
      elif command -v sudo >/dev/null 2>&1; then
        sudo apt-get install -y -qq "$pkg" 2>/dev/null || true
      fi
    done
  elif command -v pacman >/dev/null 2>&1; then
    local packages=(ca-certificates zlib zstd libedit sqlite ncurses libxml2 curl)
    if [[ "$(id -u)" -eq 0 ]]; then
      pacman -Sy --noconfirm --needed "${packages[@]}" 2>/dev/null || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo pacman -Sy --noconfirm --needed "${packages[@]}" 2>/dev/null || true
    fi
  elif command -v apk >/dev/null 2>&1; then
    # Alpine is musl — SONAME shims rarely help official Swift (glibc) toolchains.
    local packages=(ca-certificates zlib zstd libedit sqlite-libs ncurses-libs libxml2 curl)
    if [[ "$(id -u)" -eq 0 ]]; then
      apk add --no-cache "${packages[@]}" 2>/dev/null || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo apk add --no-cache "${packages[@]}" 2>/dev/null || true
    fi
  elif command -v dnf >/dev/null 2>&1; then
    local packages=(ca-certificates zlib libzstd libedit sqlite-libs ncurses-libs libxml2 libcurl tar gzip)
    if [[ "$(id -u)" -eq 0 ]]; then
      dnf install -y "${packages[@]}" 2>/dev/null || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo dnf install -y "${packages[@]}" 2>/dev/null || true
    fi
  fi

  while IFS= read -r soname; do
    [[ -z "$soname" ]] && continue
    if ! barkvisor_soname_present "$soname"; then
      barkvisor_install_soname "$soname" || failed=1
    fi
  done < <(barkvisor_required_sonames)

  # Never keep reverse shims in the compat dir (e.g. libxml2.so.16 -> libxml2.so.2).
  # Only provide *older* SONAMEs expected by the Swift toolchain.
  if [[ -d "$BARKVISOR_COMPAT_DIR" ]]; then
    local f base
    for f in "$BARKVISOR_COMPAT_DIR"/libxml2.so.* "$BARKVISOR_COMPAT_DIR"/libncurses*.so.*; do
      [[ -e "$f" || -L "$f" ]] || continue
      base="$(basename "$f")"
      case "$base" in
        libxml2.so.2 | libncurses.so.6 | libtinfo.so.6) continue ;;
        *)
          rm -f "$f" 2>/dev/null || sudo rm -f "$f" 2>/dev/null || true
          ;;
      esac
    done
  fi

  if command -v ldconfig >/dev/null 2>&1; then
    local conf=/etc/ld.so.conf.d/barkvisor-compat.conf
    if [[ -d "$BARKVISOR_COMPAT_DIR" && "$BARKVISOR_COMPAT_DIR" == /usr/local/lib/* ]]; then
      if [[ "$(id -u)" -eq 0 ]]; then
        echo "$BARKVISOR_COMPAT_DIR" >"$conf"
        ldconfig 2>/dev/null || true
      elif command -v sudo >/dev/null 2>&1; then
        echo "$BARKVISOR_COMPAT_DIR" | sudo tee "$conf" >/dev/null
        sudo ldconfig 2>/dev/null || true
      fi
    fi
  fi

  return "$failed"
}

barkvisor_export_swift_env() {
  local compat="${BARKVISOR_COMPAT_DIR}"
  if [[ ! -d "$compat" ]]; then
    local alt="${XDG_DATA_HOME:-$HOME/.local/share}/barkvisor/compat"
    [[ -d "$alt" ]] && compat="$alt"
  fi
  if [[ -d "$compat" ]]; then
    export LD_LIBRARY_PATH="${compat}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi
  if [[ -d /opt/swift/usr/bin ]]; then
    export PATH="/opt/swift/usr/bin:${PATH}"
  elif [[ -d "$HOME/swift/usr/bin" ]]; then
    export PATH="$HOME/swift/usr/bin:${PATH}"
  fi
}

# Map host Ubuntu VERSION_ID → official Swift download channel.
# Hosts newer than the latest supported LTS use that LTS + SONAME compat.
# Kept for call sites/tests; prefer barkvisor_swift_channel for multi-distro.
barkvisor_swift_ubuntu_channel() {
  local ver="${1:-}"
  if [[ -z "$ver" && -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    ver="${VERSION_ID:-24.04}"
  fi
  case "$ver" in
    22.04*) echo "ubuntu2204" ;;
    24.04*) echo "ubuntu2404" ;;
    *)
      # 25.x / 26.04 / unknown → newest supported LTS toolchain + compat
      echo "ubuntu2404"
      ;;
  esac
}

# Resolve official Swift.org release *channel* for this host.
# Prints: ubuntu2204 | ubuntu2404 | debian12 | fedora39
# Arch / unknown glibc → ubuntu2404 + SONAME compat.
# Alpine/musl is unsupported for builds (caller should refuse).
barkvisor_swift_channel() {
  local id="" ver=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    id="${ID:-}"
    ver="${VERSION_ID:-}"
  fi
  case "$id" in
    ubuntu | linuxmint | pop)
      barkvisor_swift_ubuntu_channel "$ver"
      ;;
    debian | raspbian)
      # Official channel is debian12; older/newer still use that tarball + compat.
      echo "debian12"
      ;;
    fedora)
      echo "fedora39"
      ;;
    rocky | rhel | almalinux | centos | ol)
      # Prefer Fedora toolchain when host glibc is new enough; otherwise still
      # report fedora39 (install script refuses on glibc < 2.38).
      echo "fedora39"
      ;;
    arch | archarm | manjaro | endeavouros | garuda | "")
      # No official Arch/generic channel — use Ubuntu 24.04 toolchain + compat.
      # Orb/alarm images often use ID=archarm.
      echo "ubuntu2404"
      ;;
    alpine)
      # musl — no official toolchain; still return a channel for messaging.
      echo "ubuntu2404"
      ;;
    *)
      # ID_LIKE=debian/ubuntu/rhel/fedora
      if [[ " ${ID_LIKE:-} " == *" debian "* ]] || [[ " ${ID_LIKE:-} " == *" ubuntu "* ]]; then
        if [[ " ${ID_LIKE:-} " == *" ubuntu "* ]] || [[ "$id" == *ubuntu* ]]; then
          barkvisor_swift_ubuntu_channel "$ver"
        else
          echo "debian12"
        fi
      elif [[ " ${ID_LIKE:-} " == *" rhel "* ]] || [[ " ${ID_LIKE:-} " == *" fedora "* ]] || [[ " ${ID_LIKE:-} " == *" centos "* ]]; then
        echo "fedora39"
      else
        echo "ubuntu2404"
      fi
      ;;
  esac
}

# Print official Swift Linux tarball URL for this host.
# Args: [swift_version]  default 6.3.3
barkvisor_swift_download_url() {
  local version="${1:-6.3.3}"
  local channel file_tag arch_suffix=""
  channel="$(barkvisor_swift_channel)"
  case "$channel" in
    ubuntu2204) file_tag="ubuntu22.04" ;;
    ubuntu2404) file_tag="ubuntu24.04" ;;
    debian12) file_tag="debian12" ;;
    fedora39) file_tag="fedora39" ;;
    *)
      channel="ubuntu2404"
      file_tag="ubuntu24.04"
      ;;
  esac
  case "$(uname -m)" in
    aarch64 | arm64)
      arch_suffix="-aarch64"
      # download path segment uses channel-aarch64
      echo "https://download.swift.org/swift-${version}-release/${channel}-aarch64/swift-${version}-RELEASE/swift-${version}-RELEASE-${file_tag}-aarch64.tar.gz"
      ;;
    *)
      echo "https://download.swift.org/swift-${version}-release/${channel}/swift-${version}-RELEASE/swift-${version}-RELEASE-${file_tag}.tar.gz"
      ;;
  esac
}
