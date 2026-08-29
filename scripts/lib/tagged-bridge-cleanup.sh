#!/bin/sh
# Remove BarkVisor-tagged host-bridge files only.
# Shared by scripts/uninstall.sh. Debian postrm inlines the same logic
# (package files are already gone when postrm runs).
#
# Never deletes a shared br0. --purge / --revert may offer --remove-bridge;
# that flag is the only way to drop a BarkVisor-created bridge.
#
# Paths are overridable for tests via BARKVISOR_HOST_ROOT and the
# BARKVISOR_BRIDGE_* variables. Host address on the bridge is Device
# config (#378), not guest addressing (#385).
#
# Usage:
#   . scripts/lib/tagged-bridge-cleanup.sh
#   barkvisor_strip_tagged_acl
#   barkvisor_remove_tagged_host_files
#   barkvisor_offer_bridge_removal
#   barkvisor_maybe_remove_bridge
# Or:
#   scripts/lib/tagged-bridge-cleanup.sh --strip-tagged
#   scripts/lib/tagged-bridge-cleanup.sh --offer
#   scripts/lib/tagged-bridge-cleanup.sh --remove-bridge

# Same tokens as LinuxHostBridgeApply.aclMarker / netplanYAML.
BARKVISOR_ACL_MARKER="# barkvisor:allow-br0"
BARKVISOR_MANAGED_MARKER="# managed-by: barkvisor"

barkvisor_bridge_name() { printf '%s' "${BARKVISOR_BRIDGE:-br0}"; }

barkvisor_host_root() { printf '%s' "${BARKVISOR_HOST_ROOT:-}"; }

barkvisor_acl_path() {
  if [ -n "${BARKVISOR_BRIDGE_ACL:-}" ]; then
    printf '%s' "$BARKVISOR_BRIDGE_ACL"
    return
  fi
  printf '%s/etc/qemu/bridge.conf' "$(barkvisor_host_root)"
}

barkvisor_netplan_dir() {
  if [ -n "${BARKVISOR_NETPLAN_DIR:-}" ]; then
    printf '%s' "$BARKVISOR_NETPLAN_DIR"
    return
  fi
  printf '%s/etc/netplan' "$(barkvisor_host_root)"
}

barkvisor_networkd_dir() {
  if [ -n "${BARKVISOR_NETWORKD_DIR:-}" ]; then
    printf '%s' "$BARKVISOR_NETWORKD_DIR"
    return
  fi
  printf '%s/etc/systemd/network' "$(barkvisor_host_root)"
}

barkvisor_nm_dir() {
  if [ -n "${BARKVISOR_NM_DIR:-}" ]; then
    printf '%s' "$BARKVISOR_NM_DIR"
    return
  fi
  printf '%s/etc/NetworkManager/system-connections' "$(barkvisor_host_root)"
}

barkvisor_data_dir() {
  if [ -n "${BARKVISOR_DATA_DIR:-}" ]; then
    printf '%s' "$BARKVISOR_DATA_DIR"
    return
  fi
  printf '%s/var/lib/barkvisor' "$(barkvisor_host_root)"
}

barkvisor_owner_marker_path() {
  printf '%s/host-bridge-%s.json' "$(barkvisor_data_dir)" "$(barkvisor_bridge_name)"
}

barkvisor_file_is_tagged() {
  [ -f "$1" ] || return 1
  grep -q "^${BARKVISOR_MANAGED_MARKER}$" "$1"
}

# Filename is itself a BarkVisor tag (apply writes 90-barkvisor-* / barkvisor-*).
barkvisor_name_is_ours() {
  case "$(basename "$1")" in
    90-barkvisor-*|barkvisor-*) return 0 ;;
    *) return 1 ;;
  esac
}

barkvisor_strip_tagged_acl() {
  acl="$(barkvisor_acl_path)"
  bridge="$(barkvisor_bridge_name)"
  [ -f "$acl" ] || return 0
  tmp="${acl}.barkvisor-strip.$$"
  awk -v marker="$BARKVISOR_ACL_MARKER" -v allow="allow ${bridge}" '
    $0==marker { skip=1; next }
    skip==1 && $0==allow { skip=0; next }
    { skip=0; print }
  ' "$acl" >"$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$acl"
}

barkvisor_remove_tagged_in_dir() {
  dir="$1"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    if barkvisor_file_is_tagged "$f" || barkvisor_name_is_ours "$f"; then
      rm -f "$f"
    fi
  done
}

barkvisor_remove_tagged_host_files() {
  bridge="$(barkvisor_bridge_name)"
  barkvisor_remove_tagged_in_dir "$(barkvisor_netplan_dir)"
  barkvisor_remove_tagged_in_dir "$(barkvisor_networkd_dir)"
  barkvisor_remove_tagged_in_dir "$(barkvisor_nm_dir)"

  # Well-known apply paths from #378, even if the dir scan missed them.
  rm -f "$(barkvisor_netplan_dir)/90-barkvisor-${bridge}.yaml"
  rm -f "$(barkvisor_networkd_dir)/90-barkvisor-${bridge}.netdev"
  rm -f "$(barkvisor_networkd_dir)/90-barkvisor-${bridge}.network"

  if command -v nmcli >/dev/null 2>&1 && [ -z "${BARKVISOR_SKIP_NMCLI:-}" ]; then
    nmcli connection delete "barkvisor-${bridge}" >/dev/null 2>&1 || true
  fi

  marker="$(barkvisor_owner_marker_path)"
  rm -f "$marker"
}

barkvisor_offer_bridge_removal() {
  bridge="$(barkvisor_bridge_name)"
  printf '%s\n' "Tagged BarkVisor files were removed. ${bridge} was left in place (shared bridges are never default-deleted)."
  printf '%s\n' "To also delete a BarkVisor-created ${bridge}, re-run with --remove-bridge (only if we created it)."
}

# Snapshot before we delete host-bridge-*.json during file cleanup.
_barkvisor_created_bridge=""

barkvisor_snapshot_created_marker() {
  if [ -n "${BARKVISOR_BRIDGE_CREATED:-}" ]; then
    _barkvisor_created_bridge="$BARKVISOR_BRIDGE_CREATED"
    return
  fi
  marker="$(barkvisor_owner_marker_path)"
  if [ -f "$marker" ] && grep -q '"createdBridge"[[:space:]]*:[[:space:]]*true' "$marker"; then
    _barkvisor_created_bridge=1
  else
    _barkvisor_created_bridge=0
  fi
}

barkvisor_has_created_marker() {
  if [ -z "${_barkvisor_created_bridge}" ]; then
    barkvisor_snapshot_created_marker
  fi
  [ "$_barkvisor_created_bridge" = "1" ]
}

barkvisor_maybe_remove_bridge() {
  bridge="$(barkvisor_bridge_name)"
  if [ "${BARKVISOR_REMOVE_BRIDGE:-0}" != "1" ]; then
    return 0
  fi
  if ! barkvisor_has_created_marker; then
    printf '%s\n' "error: no BarkVisor created-bridge marker for ${bridge}. Will not delete a shared bridge." >&2
    return 5
  fi
  if [ "${BARKVISOR_DRY_RUN:-0}" = "1" ]; then
    printf '%s\n' "dry-run: would ip link delete ${bridge}"
    return 0
  fi
  if command -v ip >/dev/null 2>&1; then
    ip link delete "$bridge" >/dev/null 2>&1 || true
  fi
}

barkvisor_cleanup_tagged_bridge() {
  barkvisor_snapshot_created_marker
  barkvisor_strip_tagged_acl
  barkvisor_remove_tagged_host_files
}

# When executed (not sourced), dispatch on the first argument.
if [ "${0##*/}" = "tagged-bridge-cleanup.sh" ]; then
  action="${1:-}"
  [ -n "$action" ] || action="--strip-tagged"
  case "$action" in
    --strip-tagged)
      barkvisor_cleanup_tagged_bridge
      ;;
    --offer)
      barkvisor_cleanup_tagged_bridge
      barkvisor_offer_bridge_removal
      ;;
    --remove-bridge)
      BARKVISOR_REMOVE_BRIDGE=1
      barkvisor_cleanup_tagged_bridge
      barkvisor_maybe_remove_bridge
      ;;
    -h|--help)
      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
      ;;
    *)
      printf '%s\n' "error: unknown action $action (use --strip-tagged, --offer, or --remove-bridge)" >&2
      exit 2
      ;;
  esac
fi
