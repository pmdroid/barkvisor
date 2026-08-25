#!/usr/bin/env bash
# Build BarkVisor Linux distribution packages from a release binary.
#
# Formats (select with FORMATS=...):
#   tar   — portable install tree tarball (all distros, always recommended)
#   deb   — Debian/Ubuntu (.deb) via dpkg-deb
#   rpm   — Fedora/RHEL/Rocky/Alma (.rpm) via rpmbuild
#   arch  — Arch Linux package via makepkg (when available)
#   all   — tar+deb+rpm+arch (skips formats whose tools are missing unless STRICT=1)
#
# Usage:
#   # On a Linux build host after: swift build -c release --product BarkVisorApp
#   ./scripts/linux-frontend-serve.sh
#   ./scripts/build-linux-packages.sh
#
#   VERSION=1.0.0 FORMATS=tar,deb ./scripts/build-linux-packages.sh \
#     .build/release/BarkVisorApp
#
#   # Docker helper (builds binary + packages inside Ubuntu 24.04):
#   ./scripts/build-linux-packages.sh --docker
#
# Outputs under build/linux-packages/ (override with OUT_DIR=).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/linux-package-stage.sh
source "$ROOT/scripts/lib/linux-package-stage.sh"

OUT_DIR="${OUT_DIR:-$ROOT/build/linux-packages}"
FORMATS="${FORMATS:-all}"
BUNDLE_SWIFT="${BUNDLE_SWIFT:-1}"
STRICT="${STRICT:-0}"
DOCKER_MODE=0
BIN_SRC=""
FRONTEND_SRC="${FRONTEND_DIST:-}"

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help) usage 0 ;;
    --docker) DOCKER_MODE=1; shift ;;
    --formats) FORMATS="${2:?}"; shift 2 ;;
    --out) OUT_DIR="${2:?}"; shift 2 ;;
    --version) VERSION="${2:?}"; shift 2 ;;
    --frontend) FRONTEND_SRC="${2:?}"; shift 2 ;;
    --no-swift-bundle) BUNDLE_SWIFT=0; shift ;;
    --) shift; break ;;
    -*)
      echo "unknown option: $1" >&2
      usage 1
      ;;
    *)
      BIN_SRC="$1"
      shift
      break
      ;;
  esac
done

if [[ "$DOCKER_MODE" == "1" ]]; then
  exec "$ROOT/scripts/build-linux-packages-docker.sh" \
    ${VERSION:+--version "$VERSION"} \
    ${FORMATS:+--formats "$FORMATS"} \
    ${OUT_DIR:+--out "$OUT_DIR"}
fi

# --- resolve binary ---
if [[ -z "$BIN_SRC" ]]; then
  for cand in \
    "$ROOT/.build/release/BarkVisorApp" \
    "$ROOT/.build/debug/BarkVisorApp"; do
    if [[ -x "$cand" ]]; then
      BIN_SRC="$cand"
      break
    fi
  done
fi
if [[ -z "$BIN_SRC" || ! -x "$BIN_SRC" ]]; then
  echo "error: BarkVisorApp binary not found. Build first:" >&2
  echo "  swift build -c release --product BarkVisorApp" >&2
  echo "Or pass the path: $0 /path/to/BarkVisorApp" >&2
  exit 1
fi

# --- resolve SPA ---
if [[ -z "$FRONTEND_SRC" ]]; then
  for cand in \
    "$ROOT/frontend/dist" \
    "$ROOT/Sources/BarkVisor/Resources/frontend/dist"; do
    if [[ -f "$cand/index.html" ]]; then
      FRONTEND_SRC="$cand"
      break
    fi
  done
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: package build must run on Linux (or use --docker)." >&2
  echo "  On macOS: ./scripts/build-linux-packages.sh --docker" >&2
  exit 1
fi

VERSION="$(barkvisor_package_version)"
DEB_VERSION="$(barkvisor_package_deb_version)"
DEB_ARCH="$(barkvisor_package_deb_arch)"
RPM_ARCH="$(barkvisor_package_rpm_arch)"
ARCH_ARCH="$(barkvisor_package_arch_arch)"
HOST_ARCH="$(barkvisor_package_host_arch)"
STAGE_ROOT="$OUT_DIR/stage"
PKG_META="$ROOT/packaging/linux"

mkdir -p "$OUT_DIR"
export ROOT STAGE_ROOT BIN_SRC FRONTEND_SRC BUNDLE_SWIFT VERSION

echo "==> BarkVisor Linux packages"
echo "    version:  $VERSION (deb: $DEB_VERSION)"
echo "    arch:     $HOST_ARCH (deb=$DEB_ARCH rpm=$RPM_ARCH)"
echo "    binary:   $BIN_SRC"
echo "    frontend: ${FRONTEND_SRC:-"(none)"}"
echo "    formats:  $FORMATS"
echo "    out:      $OUT_DIR"

echo "==> Staging install tree"
barkvisor_stage_install_tree

want_format() {
  local f="$1"
  [[ "$FORMATS" == "all" ]] && return 0
  [[ ",$FORMATS," == *",$f,"* ]] && return 0
  return 1
}

skip_or_fail() {
  local msg="$1"
  if [[ "$STRICT" == "1" ]]; then
    echo "error: $msg" >&2
    exit 1
  fi
  echo "skip: $msg" >&2
}

# ---------- tar.gz (portable; works on all supported distros) ----------
build_tar() {
  local name="barkvisor-${VERSION}-linux-${HOST_ARCH}"
  local tar_path="$OUT_DIR/${name}.tar.gz"
  local stage_named="$OUT_DIR/$name"
  rm -rf "$stage_named"
  mkdir -p "$stage_named"
  cp -a "$STAGE_ROOT"/. "$stage_named/root/"
  # Portable installer helper next to the tree
  cat >"$stage_named/install.sh" <<'EOS'
#!/usr/bin/env bash
# Install staged BarkVisor tree onto this host (root).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_TREE="$HERE/root"
[[ "$(id -u)" -eq 0 ]] || { echo "run as root"; exit 1; }
cp -a "$ROOT_TREE"/. /
if ! getent passwd barkvisor >/dev/null 2>&1; then
  useradd --system --home /var/lib/barkvisor --shell /usr/sbin/nologin barkvisor 2>/dev/null \
    || useradd --system --home /var/lib/barkvisor --shell /bin/false barkvisor
fi
getent group kvm >/dev/null 2>&1 && usermod -aG kvm barkvisor || true
if getent group disk >/dev/null 2>&1; then
  usermod -aG disk barkvisor || true
  mkdir -p /etc/systemd/system/barkvisor.service.d
  printf '%s\n' '[Service]' 'SupplementaryGroups=disk' \
    >/etc/systemd/system/barkvisor.service.d/disk.conf
fi
install -d -o barkvisor -g barkvisor -m 0755 /var/lib/barkvisor /var/run/barkvisor
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl enable barkvisor.service
  systemctl try-restart barkvisor.service >/dev/null 2>&1 || true
  echo "Start with: systemctl start barkvisor.service"
fi
echo "Installed. UI: http://$(hostname -I 2>/dev/null | awk '{print $1}'):7777"
EOS
  chmod 0755 "$stage_named/install.sh"
  cat >"$stage_named/README.md" <<EOF
# BarkVisor ${VERSION} (Linux ${HOST_ARCH})

Portable install tree matching the systemd package layout.

\`\`\`bash
sudo ./install.sh
# or: sudo cp -a root/. /
\`\`\`

Supported hosts: Ubuntu, Debian, Fedora, Rocky/Alma/RHEL 10+, Arch (glibc).
Alpine: use this tarball only if you ship a musl-compatible build (official
Swift toolchains are glibc).

Prefer distro packages when available:
- Debian/Ubuntu: \`barkvisor_${DEB_VERSION}_${DEB_ARCH}.deb\`
- Fedora/RHEL: \`barkvisor-${VERSION}-1.*.rpm\`
- Arch: build with the included PKGBUILD (see arch/ if present)

Docs: https://github.com/pmdroid/barkvisor/blob/main/docs/getting-started-linux.md
EOF
  tar -C "$OUT_DIR" -czf "$tar_path" "$name"
  echo "    wrote $tar_path"
  # checksum
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$OUT_DIR" && sha256sum "$(basename "$tar_path")" >"$(basename "$tar_path").sha256")
  fi
}

# ---------- .deb ----------
build_deb() {
  if ! command -v dpkg-deb >/dev/null 2>&1; then
    skip_or_fail "dpkg-deb not installed (apt install dpkg-dev)"
    return 0
  fi
  local deb_root="$OUT_DIR/deb-root"
  local deb_name="barkvisor_${DEB_VERSION}_${DEB_ARCH}.deb"
  rm -rf "$deb_root"
  mkdir -p "$deb_root"
  cp -a "$STAGE_ROOT"/. "$deb_root/"
  install -d "$deb_root/DEBIAN"
  sed \
    -e "s/@VERSION@/${DEB_VERSION}/g" \
    -e "s/@DEB_ARCH@/${DEB_ARCH}/g" \
    "$PKG_META/debian/control.in" >"$deb_root/DEBIAN/control"
  install -m 0755 "$PKG_META/debian/postinst" "$deb_root/DEBIAN/postinst"
  install -m 0755 "$PKG_META/debian/prerm" "$deb_root/DEBIAN/prerm"
  install -m 0755 "$PKG_META/debian/postrm" "$deb_root/DEBIAN/postrm"
  install -m 0644 "$PKG_META/debian/conffiles" "$deb_root/DEBIAN/conffiles"
  # Installed-Size in KiB
  local size_k
  size_k="$(du -sk "$deb_root" | awk '{print $1}')"
  echo "Installed-Size: $size_k" >>"$deb_root/DEBIAN/control"
  dpkg-deb --root-owner-group --build "$deb_root" "$OUT_DIR/$deb_name"
  echo "    wrote $OUT_DIR/$deb_name"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$OUT_DIR" && sha256sum "$deb_name" >"${deb_name}.sha256")
  fi
}

# ---------- .rpm ----------
build_rpm() {
  if ! command -v rpmbuild >/dev/null 2>&1; then
    skip_or_fail "rpmbuild not installed (dnf install rpm-build)"
    return 0
  fi
  local rpm_top="$OUT_DIR/rpmbuild"
  # RPM Version: must not contain '-' ; map 1.0.0+git.abc → 1.0.0+git.abc is ok,
  # but prefer dots only for maximum compatibility: 1.0.0.git.abc
  local ver_rpm
  ver_rpm="$(echo "$VERSION" | tr '-' '.' | sed 's/+/.git./;s/\.\././g')"
  rm -rf "$rpm_top"
  mkdir -p "$rpm_top"/{BUILD,RPMS,SOURCES,SPECS,SRPMS,BUILDROOT}
  mkdir -p "$rpm_top/SOURCES/root"
  cp -a "$STAGE_ROOT"/. "$rpm_top/SOURCES/root/"
  local changelog_date
  changelog_date="$(date '+%a %b %d %Y' 2>/dev/null || echo 'Thu Jan 01 2026')"
  sed \
    -e "s/@VERSION@/${ver_rpm}/g" \
    -e "s/@RPM_ARCH@/${RPM_ARCH}/g" \
    -e "s/@CHANGELOG_DATE@/${changelog_date}/g" \
    "$PKG_META/rpm/barkvisor.spec.in" >"$rpm_top/SPECS/barkvisor.spec"
  rpmbuild \
    --define "_topdir $rpm_top" \
    --define "_sourcedir $rpm_top/SOURCES" \
    --define "_rpmdir $rpm_top/RPMS" \
    --define "_builddir $rpm_top/BUILD" \
    --define "_buildrootdir $rpm_top/BUILDROOT" \
    --define "_srcrpmdir $rpm_top/SRPMS" \
    -bb "$rpm_top/SPECS/barkvisor.spec"
  local built
  built="$(find "$rpm_top/RPMS" -name 'barkvisor-*.rpm' -type f | head -1)"
  if [[ -z "$built" ]]; then
    skip_or_fail "rpmbuild produced no rpm"
    return 0
  fi
  cp -a "$built" "$OUT_DIR/"
  echo "    wrote $OUT_DIR/$(basename "$built")"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$OUT_DIR" && sha256sum "$(basename "$built")" >"$(basename "$built").sha256")
  fi
}

# ---------- Arch PKGBUILD + optional makepkg ----------
build_arch() {
  local arch_dir="$OUT_DIR/arch"
  rm -rf "$arch_dir"
  mkdir -p "$arch_dir/src/root"
  cp -a "$STAGE_ROOT"/. "$arch_dir/src/root/"
  # makepkg expects sources; we use a local tree via PKGBUILD package()
  # Provide a source tarball for integrity
  tar -C "$arch_dir/src" -czf "$arch_dir/barkvisor-root.tar.gz" root
  sed \
    -e "s/@VERSION@/${VERSION%%+*}/g" \
    -e "s/@ARCH_ARCH@/${ARCH_ARCH}/g" \
    "$PKG_META/arch/PKGBUILD.in" >"$arch_dir/PKGBUILD"
  # Embed no external source — package from pre-extracted src/root
  # Rewrite PKGBUILD to not need download
  cat >"$arch_dir/PKGBUILD" <<EOF
pkgname=barkvisor
pkgver=$(echo "${VERSION}" | sed -E 's/[^0-9A-Za-z.+_]+/./g' | sed 's/^\.//;s/\.$//')
pkgrel=1
pkgdesc="Headless QEMU VM manager with web UI"
arch=('${ARCH_ARCH}')
url="https://github.com/pmdroid/barkvisor"
license=('MIT')
depends=('glibc' 'curl' 'libxml2' 'sqlite' 'ncurses' 'zstd' 'libedit' 'zlib')
optdepends=(
  'qemu-base: run guests'
  'edk2-ovmf: UEFI firmware (x86_64)'
  'cdrtools: cloud-init seed ISO (mkisofs)'
  'usbutils: USB passthrough device list'
)
options=('!strip' '!debug')
install=barkvisor.install

package() {
  cp -a "\${startdir}/src/root/." "\${pkgdir}/"
}
EOF
  install -m 0644 "$PKG_META/arch/barkvisor.install" "$arch_dir/barkvisor.install"
  echo "    wrote $arch_dir/PKGBUILD"

  if command -v makepkg >/dev/null 2>&1; then
    (cd "$arch_dir" && makepkg -f --nodeps 2>&1 | tail -20) || {
      skip_or_fail "makepkg failed"
      return 0
    }
    local pkg
    pkg="$(find "$arch_dir" -maxdepth 1 -name 'barkvisor-*.pkg.tar*' -type f | head -1)"
    if [[ -n "$pkg" ]]; then
      cp -a "$pkg" "$OUT_DIR/"
      echo "    wrote $OUT_DIR/$(basename "$pkg")"
    fi
  else
    echo "    note: makepkg not available — PKGBUILD left in $arch_dir for Arch hosts"
  fi
}

# --- run formats ---
if want_format tar; then
  echo "==> tar.gz"
  build_tar
fi
if want_format deb; then
  echo "==> deb"
  build_deb
fi
if want_format rpm; then
  echo "==> rpm"
  build_rpm
fi
if want_format arch; then
  echo "==> arch"
  build_arch
fi

# Manifest
{
  echo "version=$VERSION"
  echo "host_arch=$HOST_ARCH"
  echo "binary=$BIN_SRC"
  echo "frontend=${FRONTEND_SRC:-}"
  echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
  echo "artifacts:"
  find "$OUT_DIR" -maxdepth 1 -type f \( -name 'barkvisor*' -o -name '*.sha256' \) | sort | sed 's/^/  /'
} | tee "$OUT_DIR/MANIFEST.txt"

echo
echo "Done. Artifacts in $OUT_DIR"
echo "Install examples:"
echo "  sudo dpkg -i $OUT_DIR/barkvisor_*.deb"
echo "  sudo rpm -Uvh $OUT_DIR/barkvisor-*.rpm"
echo "  sudo tar xzf $OUT_DIR/barkvisor-*-linux-*.tar.gz && cd barkvisor-* && sudo ./install.sh"
