#!/usr/bin/env bash
# Assemble a FHS install tree for BarkVisor Linux packages.
# Sourced by scripts/build-linux-packages.sh (not meant to be run alone).
#
# Expected env:
#   ROOT          repo root
#   STAGE_ROOT    absolute path to package root (contains usr/, etc/)
#   BIN_SRC       path to BarkVisorApp binary
#   FRONTEND_SRC  optional path to SPA dist/ with index.html
#   BUNDLE_SWIFT  1 (default) to copy Swift runtime libs next to the binary

barkvisor_package_host_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo "x86_64" ;;
    aarch64 | arm64) echo "aarch64" ;;
    *) uname -m ;;
  esac
}

barkvisor_package_deb_arch() {
  case "$(barkvisor_package_host_arch)" in
    x86_64) echo "amd64" ;;
    aarch64) echo "arm64" ;;
    *) echo "all" ;;
  esac
}

barkvisor_package_rpm_arch() {
  barkvisor_package_host_arch
}

barkvisor_package_arch_arch() {
  case "$(barkvisor_package_host_arch)" in
    x86_64) echo "x86_64" ;;
    aarch64) echo "aarch64" ;;
    *) barkvisor_package_host_arch ;;
  esac
}

barkvisor_package_version() {
  if [[ -n "${VERSION:-}" ]]; then
    echo "$VERSION"
    return
  fi
  if [[ -n "${BARKVISOR_VERSION:-}" ]]; then
    echo "$BARKVISOR_VERSION"
    return
  fi
  # Prefer exact tag v1.2.3; otherwise 0.0.0+git.<shortsha>
  if command -v git >/dev/null 2>&1 && git -C "${ROOT:-.}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local exact
    exact="$(git -C "$ROOT" describe --tags --match 'v*' --exact-match 2>/dev/null || true)"
    if [[ -n "$exact" ]]; then
      echo "${exact#v}"
      return
    fi
    echo "0.0.0+git.$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    return
  fi
  echo "0.0.0"
}

# Sanitize version for Debian (no underscores; +git ok).
barkvisor_package_deb_version() {
  local v
  v="$(barkvisor_package_version)"
  v="${v//_/-}"
  echo "$v"
}

barkvisor_find_swift_linux_libdir() {
  # Prefer explicit override
  if [[ -n "${SWIFT_LINUX_LIBDIR:-}" && -d "$SWIFT_LINUX_LIBDIR" ]]; then
    echo "$SWIFT_LINUX_LIBDIR"
    return 0
  fi
  local candidates=()
  if command -v swift >/dev/null 2>&1; then
    local swbin swroot
    swbin="$(command -v swift)"
    swbin="$(readlink -f "$swbin" 2>/dev/null || echo "$swbin")"
    # .../usr/bin/swift → .../usr
    swroot="$(cd "$(dirname "$swbin")/.." && pwd)"
    candidates+=("$swroot/lib/swift/linux")
  fi
  candidates+=(
    /usr/lib/swift/linux
    /opt/swift/usr/lib/swift/linux
    "$HOME/swift/usr/lib/swift/linux"
    /usr/local/lib/swift/linux
  )
  local d
  for d in "${candidates[@]}"; do
    if [[ -d "$d" ]] && compgen -G "$d"/libswiftCore.so* >/dev/null 2>&1; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

barkvisor_stage_install_tree() {
  local stage="${STAGE_ROOT:?STAGE_ROOT required}"
  local bin="${BIN_SRC:?BIN_SRC required}"
  local fe="${FRONTEND_SRC:-}"
  local pkg_root="$ROOT/packaging/linux"

  rm -rf "$stage"
  install -d \
    "$stage/usr/local/bin" \
    "$stage/usr/local/share/barkvisor/frontend/dist" \
    "$stage/usr/local/lib/barkvisor/swift" \
    "$stage/usr/local/lib/barkvisor/compat" \
    "$stage/usr/lib/systemd/system" \
    "$stage/etc/barkvisor" \
    "$stage/var/lib/barkvisor" \
    "$stage/var/run/barkvisor"

  install -m 0755 "$bin" "$stage/usr/local/bin/barkvisor"

  if [[ -n "$fe" && -f "$fe/index.html" ]]; then
    cp -a "$fe"/. "$stage/usr/local/share/barkvisor/frontend/dist/"
  else
    echo "warning: no SPA dist — package will be API-only (set FRONTEND_DIST=)" >&2
    # Place a tiny placeholder so share dir exists
    printf '%s\n' '<!-- BarkVisor SPA not bundled in this package -->' \
      >"$stage/usr/local/share/barkvisor/frontend/dist/MISSING_SPA.html"
  fi

  install -m 0644 "$pkg_root/barkvisor.service" "$stage/usr/lib/systemd/system/barkvisor.service"
  install -m 0644 "$pkg_root/barkvisor.env" "$stage/etc/barkvisor/barkvisor.env"

  # Bundle Swift runtime (required for dynamically linked release binary).
  if [[ "${BUNDLE_SWIFT:-1}" == "1" ]]; then
    local swift_lib
    if swift_lib="$(barkvisor_find_swift_linux_libdir)"; then
      echo "    Swift libs: $swift_lib"
      # Copy shared objects + swift resource modules used at runtime
      cp -a "$swift_lib"/. "$stage/usr/local/lib/barkvisor/swift/" 2>/dev/null || true
      # Also pull transitive non-Swift deps that live next to the toolchain (rare)
      if command -v ldd >/dev/null 2>&1; then
        local line so
        while IFS= read -r line; do
          so="$(echo "$line" | awk '/=>/ {print $3}')"
          [[ -n "$so" && -f "$so" ]] || continue
          case "$so" in
            /lib/* | /usr/lib/* | /lib64/* | /usr/lib64/*) continue ;; # system libs via Depends
            *)
              cp -an "$so" "$stage/usr/local/lib/barkvisor/swift/" 2>/dev/null || true
              ;;
          esac
        done < <(ldd "$bin" 2>/dev/null || true)
      fi
    else
      echo "warning: Swift linux lib dir not found — binary may not start on clean hosts" >&2
      echo "  Set SWIFT_LINUX_LIBDIR= or install the Swift toolchain used to build." >&2
    fi
  fi

  # Keep empty compat dir for LD_LIBRARY_PATH (host can add shims post-install)
  touch "$stage/usr/local/lib/barkvisor/compat/.keep"

  # Optional README in share
  cat >"$stage/usr/local/share/barkvisor/README.txt" <<EOF
BarkVisor Linux package
=======================
Binary:  /usr/local/bin/barkvisor
SPA:     /usr/local/share/barkvisor/frontend/dist
Unit:    barkvisor.service
Env:     /etc/barkvisor/barkvisor.env
Data:    /var/lib/barkvisor

UI:      http://<host>:7777
Docs:    https://github.com/pmdroid/barkvisor/blob/main/docs/getting-started-linux.md
EOF
}
