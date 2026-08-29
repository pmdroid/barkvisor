#!/usr/bin/env bash
# Bootstrap a BarkVisor Device from a GitHub release .deb or .pkg.
#
# Supported now: Ubuntu, Debian, macOS Apple Silicon. Not rpm/Fedora.
# Does not install via Homebrew. App updates after first install are the UI
# path (#387). The Homebrew keg (#381) is not this channel.
#
# Inspect-then-run (do not pipe blindly):
#   curl -fsSL https://raw.githubusercontent.com/pmdroid/barkvisor/main/scripts/get-barkvisor.sh -o get-barkvisor.sh
#   less get-barkvisor.sh
#   sudo bash get-barkvisor.sh
#
# SSH / non-interactive:
#   sudo bash get-barkvisor.sh --yes
#
# Options:
#   --yes           skip the confirm prompt (required when stdin is not a TTY)
#   --version TAG   pin a release (v1.2.3 or 1.2.3)
#   --dry-run       print actions only
#   --port N        /api/health port (default 7777)
#   -h, --help      this text
set -euo pipefail

REPO="${BARKVISOR_GITHUB_REPO:-pmdroid/barkvisor}"
API_ROOT="${BARKVISOR_GITHUB_API:-https://api.github.com}"
YES=0
DRY_RUN="${DRY_RUN:-0}"
PORT="${BARKVISOR_PORT:-7777}"
VERSION_TAG="${BARKVISOR_VERSION:-}"
SKIP_INSTALL="${BARKVISOR_BOOTSTRAP_SKIP_INSTALL:-0}"
SKIP_HEALTH="${BARKVISOR_BOOTSTRAP_SKIP_HEALTH:-0}"
HEALTH_ATTEMPTS="${BARKVISOR_HEALTH_ATTEMPTS:-60}"
HEALTH_SLEEP="${BARKVISOR_HEALTH_SLEEP:-1}"

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes | -y) YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --version)
      VERSION_TAG="${2:?--version needs a tag}"
      shift 2
      ;;
    --port)
      PORT="${2:?--port needs a number}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      die "unexpected argument: $1"
      ;;
  esac
done

host_os() {
  echo "${BARKVISOR_BOOTSTRAP_OS:-$(uname -s)}"
}

host_arch() {
  echo "${BARKVISOR_BOOTSTRAP_ARCH:-$(uname -m)}"
}

normalize_arch() {
  case "$1" in
    x86_64 | amd64) echo "x86_64" ;;
    aarch64 | arm64) echo "arm64" ;;
    *) echo "$1" ;;
  esac
}

deb_arch() {
  case "$(normalize_arch "$(host_arch)")" in
    x86_64) echo "amd64" ;;
    arm64) echo "arm64" ;;
    *) return 1 ;;
  esac
}

linux_distro_id() {
  if [[ -n "${BARKVISOR_BOOTSTRAP_DISTRO:-}" ]]; then
    echo "$BARKVISOR_BOOTSTRAP_DISTRO"
    return
  fi
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    echo "${ID:-unknown}"
    return
  fi
  echo "unknown"
}

linux_distro_like() {
  if [[ -n "${BARKVISOR_BOOTSTRAP_DISTRO_LIKE:-}" ]]; then
    echo "$BARKVISOR_BOOTSTRAP_DISTRO_LIKE"
    return
  fi
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    echo "${ID_LIKE:-}"
    return
  fi
}

is_debian_family() {
  local id like
  id="$(linux_distro_id)"
  like=" $(linux_distro_like) "
  case "$id" in
    debian | ubuntu) return 0 ;;
  esac
  case "$like" in
    *" debian "* | *" ubuntu "*) return 0 ;;
  esac
  return 1
}

normalize_tag() {
  local t="$1"
  [[ "$t" == v* ]] && echo "$t" || echo "v$t"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "need $1 on PATH"
}

as_root() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN: $*"
    return 0
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "root or sudo is required to install the Device package"
  fi
}

local_source() {
  local url="$1"
  if [[ "$url" == file://* ]]; then
    echo "${url#file://}"
    return 0
  fi
  if [[ "$url" == /* ]]; then
    echo "$url"
    return 0
  fi
  return 1
}

fetch() {
  local url="$1"
  local dest="${2:-}"
  local local_path=""
  if local_path="$(local_source "$url")"; then
    [[ -e "$local_path" ]] || die "local file not found: $local_path"
    if [[ -n "$dest" ]]; then
      cp "$local_path" "$dest"
    else
      cat "$local_path"
    fi
    return 0
  fi
  local args=(-fsSL --proto '=https' --tlsv1.2)
  if [[ -n "${GITHUB_TOKEN:-${GH_TOKEN:-}}" && "$url" == https://api.github.com/* ]]; then
    args+=(-H "Authorization: Bearer ${GITHUB_TOKEN:-$GH_TOKEN}")
  fi
  if [[ "$url" == https://api.github.com/* ]]; then
    args+=(-H "Accept: application/vnd.github+json")
  fi
  if [[ -n "$dest" ]]; then
    curl "${args[@]}" -o "$dest" "$url"
  else
    curl "${args[@]}" "$url"
  fi
}

file_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

verify_checksum() {
  local file="$1"
  local checksum_file="$2"
  local expected actual
  expected="$(awk 'NF { print $1; exit }' "$checksum_file")"
  [[ ${#expected} -eq 64 ]] || die "checksum file is not a SHA-256 digest: $checksum_file"
  actual="$(file_sha256 "$file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: checksum mismatch for $(basename "$file")" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
  log "checksum OK $(basename "$file")"
}

# Prints five lines: tag, asset name, asset url, checksum name, checksum url.
pick_release_asset() {
  local want_suffix="$1"
  local json
  if [[ -n "${BARKVISOR_ASSET_URL:-}" ]]; then
    local tag name chk
    tag="${BARKVISOR_RELEASE_TAG:-pinned}"
    name="${BARKVISOR_ASSET_NAME:-$(basename "${BARKVISOR_ASSET_URL}")}"
    chk="${BARKVISOR_CHECKSUM_URL:-}"
    [[ -n "$chk" ]] || die "BARKVISOR_CHECKSUM_URL is required when BARKVISOR_ASSET_URL is set"
    printf '%s\n' "$tag" "$name" "$BARKVISOR_ASSET_URL" "$(basename "$chk")" "$chk"
    return 0
  fi

  need_cmd python3
  if [[ -n "${BARKVISOR_RELEASES_URL:-}" ]]; then
    json="$(fetch "$BARKVISOR_RELEASES_URL")"
  elif [[ -n "$VERSION_TAG" ]]; then
    json="$(fetch "${API_ROOT}/repos/${REPO}/releases/tags/$(normalize_tag "$VERSION_TAG")")"
  else
    # /releases/latest ignores prereleases. Current tags are alpha.
    json="$(fetch "${API_ROOT}/repos/${REPO}/releases?per_page=20")"
  fi

  python3 -c '
import json, sys
raw = sys.stdin.read()
data = json.loads(raw)
releases = data if isinstance(data, list) else [data]
suffix = sys.argv[1]
for rel in releases:
    assets = rel.get("assets") or []
    pkg = None
    chk = None
    for a in assets:
        n = a.get("name") or ""
        u = a.get("browser_download_url") or ""
        if n.endswith(suffix) and not n.endswith(".sha256"):
            pkg = (n, u)
        if n.endswith(suffix + ".sha256"):
            chk = (n, u)
    if pkg and chk:
        print(rel.get("tag_name") or "")
        print(pkg[0]); print(pkg[1])
        print(chk[0]); print(chk[1])
        sys.exit(0)
    if pkg and not chk:
        sys.stderr.write("error: release %s has %s but no %s.sha256\n" % (rel.get("tag_name"), pkg[0], pkg[0]))
        sys.exit(3)
sys.exit(2)
' "$want_suffix" <<<"$json"
}

detect_channel() {
  local os arch
  os="$(host_os)"
  arch="$(normalize_arch "$(host_arch)")"

  case "$os" in
    Darwin)
      [[ "$arch" == "arm64" ]] || die "macOS Apple Silicon only (need arm64, host is $(host_arch))"
      CHANNEL="macos"
      ASSET_SUFFIX=".pkg"
      ;;
    Linux)
      is_debian_family || die "Ubuntu/Debian .deb only for now (host is $(linux_distro_id); rpm/Fedora is not this milestone)"
      local darch
      darch="$(deb_arch)" || die "unsupported Linux arch $(host_arch) (need amd64 or arm64)"
      CHANNEL="linux"
      ASSET_SUFFIX="_${darch}.deb"
      ;;
    *)
      die "unsupported OS $(host_os) — Ubuntu, Debian, or macOS Apple Silicon"
      ;;
  esac
}

confirm_or_die() {
  if [[ "$DRY_RUN" == "1" || "$YES" == "1" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "This installer is inspect-then-run." >&2
    echo >&2
    echo "  curl -fsSL https://raw.githubusercontent.com/pmdroid/barkvisor/main/scripts/get-barkvisor.sh -o get-barkvisor.sh" >&2
    echo "  less get-barkvisor.sh" >&2
    echo "  sudo bash get-barkvisor.sh --yes" >&2
    echo >&2
    echo "Use --yes for SSH / non-interactive installs." >&2
    exit 1
  fi
  echo "About to install BarkVisor on this Device (${CHANNEL}, $(host_arch))."
  local ans=""
  read -r -p "Continue? [y/N] " ans || true
  case "$ans" in
    y | Y | yes | YES) ;;
    *)
      echo "aborted"
      exit 1
      ;;
  esac
}

qemu_hint_needed() {
  if [[ "${BARKVISOR_BOOTSTRAP_QEMU:-}" == "0" ]]; then
    return 0
  fi
  if [[ "${BARKVISOR_BOOTSTRAP_QEMU:-}" == "1" ]]; then
    return 1
  fi
  command -v qemu-system-aarch64 >/dev/null 2>&1 || command -v qemu-system-x86_64 >/dev/null 2>&1 || return 0
  command -v swtpm >/dev/null 2>&1 || return 0
  return 1
}

print_macos_runtime_hint() {
  if qemu_hint_needed; then
    echo
    echo "Workloads need QEMU and swtpm from Homebrew. Run as your user, never sudo brew install:"
    echo "  brew install qemu swtpm"
  fi
}

install_linux() {
  local pkg="$1"
  if [[ "$SKIP_INSTALL" == "1" ]]; then
    echo "SKIP_INSTALL: dpkg -i $pkg"
    echo "SKIP_INSTALL: systemctl enable --now barkvisor.service"
    return 0
  fi
  as_root dpkg -i "$pkg" || as_root apt-get install -f -y
  as_root systemctl enable --now barkvisor.service
}

install_macos() {
  local pkg="$1"
  if [[ "$SKIP_INSTALL" == "1" ]]; then
    echo "SKIP_INSTALL: installer -pkg $pkg -target /"
    print_macos_runtime_hint
    return 0
  fi
  as_root installer -pkg "$pkg" -target /
  print_macos_runtime_hint
}

poll_health() {
  local url="http://127.0.0.1:${PORT}/api/health"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN: poll ${url}"
    return 0
  fi
  if [[ "$SKIP_HEALTH" == "1" ]]; then
    echo "SKIP_HEALTH: ${url}"
    return 0
  fi
  need_cmd curl
  local i
  log "waiting for ${url}"
  for i in $(seq 1 "$HEALTH_ATTEMPTS"); do
    if curl -sf --connect-timeout 1 --max-time 2 "$url" >/dev/null 2>&1; then
      log "health OK ${url}"
      return 0
    fi
    sleep "$HEALTH_SLEEP"
  done
  die "Device did not answer ${url} after ${HEALTH_ATTEMPTS} attempts"
}

CHANNEL=""
ASSET_SUFFIX=""

need_cmd curl
need_cmd uname
detect_channel
confirm_or_die

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN: channel=${CHANNEL} arch=$(host_arch) suffix=${ASSET_SUFFIX}"
  if [[ "$CHANNEL" == "linux" ]]; then
    echo "DRY_RUN: dpkg -i <release-deb>"
    echo "DRY_RUN: systemctl enable --now barkvisor.service"
  else
    echo "DRY_RUN: installer -pkg <release-pkg> -target /"
    print_macos_runtime_hint
  fi
  echo "DRY_RUN: poll http://127.0.0.1:${PORT}/api/health"
  echo "DRY_RUN OK"
  exit 0
fi

picked="$(pick_release_asset "$ASSET_SUFFIX")" || {
  status=$?
  if [[ "$status" -eq 2 ]]; then
    die "no GitHub release asset matching *${ASSET_SUFFIX} with a .sha256 sidecar"
  fi
  exit "$status"
}

TAG="$(sed -n '1p' <<<"$picked")"
ASSET_NAME="$(sed -n '2p' <<<"$picked")"
ASSET_URL="$(sed -n '3p' <<<"$picked")"
CHECKSUM_NAME="$(sed -n '4p' <<<"$picked")"
CHECKSUM_URL="$(sed -n '5p' <<<"$picked")"

log "release ${TAG}  ${ASSET_NAME}"

WORKDIR="${BARKVISOR_BOOTSTRAP_TMPDIR:-$(mktemp -d "${TMPDIR:-/tmp}/get-barkvisor.XXXXXX")}"
mkdir -p "$WORKDIR"
cleanup() {
  if [[ -z "${BARKVISOR_BOOTSTRAP_TMPDIR:-}" ]]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

fetch "$ASSET_URL" "$WORKDIR/$ASSET_NAME"
fetch "$CHECKSUM_URL" "$WORKDIR/$CHECKSUM_NAME"
verify_checksum "$WORKDIR/$ASSET_NAME" "$WORKDIR/$CHECKSUM_NAME"

case "$CHANNEL" in
  linux) install_linux "$WORKDIR/$ASSET_NAME" ;;
  macos) install_macos "$WORKDIR/$ASSET_NAME" ;;
esac

poll_health

echo
echo "BarkVisor is installed on this Device."
echo "Open http://127.0.0.1:${PORT} to finish setup."
