#!/usr/bin/env bash
# Unit tests for scripts/lib/linux-swift-compat.sh (shipped host install path).
# Runs on macOS or Linux; does not require apt/root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/linux-swift-compat.sh
source "$ROOT/scripts/lib/linux-swift-compat.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass=0
assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" != "$want" ]]; then
    fail "$msg: got '$got' want '$want'"
  fi
  pass=$((pass + 1))
}

# Channel map: LTS + newer hosts (drives real barkvisor_swift_ubuntu_channel)
assert_eq "$(barkvisor_swift_ubuntu_channel 22.04)" "ubuntu2204" "22.04 channel"
assert_eq "$(barkvisor_swift_ubuntu_channel 24.04)" "ubuntu2404" "24.04 channel"
assert_eq "$(barkvisor_swift_ubuntu_channel 26.04)" "ubuntu2404" "26.04 uses newest LTS channel"
assert_eq "$(barkvisor_swift_ubuntu_channel 25.10)" "ubuntu2404" "25.x uses newest LTS channel"

# Download URL for fixed version — real barkvisor_swift_download_url
URL="$(barkvisor_swift_download_url 6.2.3)"
case "$URL" in
  https://download.swift.org/swift-6.2.3-release/*swift-6.2.3-RELEASE*ubuntu*.tar.gz) ;;
  *) fail "download URL shape unexpected: $URL" ;;
esac
# 26.04 hosts use ubuntu2404 channel in the path
case "$(barkvisor_swift_ubuntu_channel 26.04)" in
  ubuntu2404)
    # When forced via uname-less channel selection, URL for 24.04 path contains 24.04
    ;;
  *) fail "26.04 channel regression" ;;
esac
pass=$((pass + 1))

# required sonames list is non-empty and includes libxml2.so.2
found_xml=0
while IFS= read -r soname; do
  [[ -z "$soname" ]] && continue
  if [[ "$soname" == "libxml2.so.2" ]]; then
    found_xml=1
  fi
done < <(barkvisor_required_sonames)
[[ "$found_xml" -eq 1 ]] || fail "libxml2.so.2 not in required sonames"
pass=$((pass + 1))

# compat dir default is install layout path
[[ "$BARKVISOR_COMPAT_DIR" == /usr/local/lib/barkvisor/compat ]] ||
  fail "default BARKVISOR_COMPAT_DIR unexpected: $BARKVISOR_COMPAT_DIR"
pass=$((pass + 1))

# export env sets LD_LIBRARY_PATH when compat dir exists (use temp dir)
tmp="$(mktemp -d "${TMPDIR:-/tmp}/bv-compat-test.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
mkdir -p "$tmp/compat"
ln -sfn /dev/null "$tmp/compat/libxml2.so.2"
BARKVISOR_COMPAT_DIR="$tmp/compat"
unset LD_LIBRARY_PATH || true
barkvisor_export_swift_env
case "${LD_LIBRARY_PATH:-}" in
  "$tmp/compat" | "$tmp/compat:"*) ;;
  *) fail "barkvisor_export_swift_env did not prefix LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-}" ;;
esac
pass=$((pass + 1))

echo "OK: $pass assertions passed (linux-swift-compat)"
