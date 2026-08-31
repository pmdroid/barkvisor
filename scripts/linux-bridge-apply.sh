#!/usr/bin/env bash
# Persist br0 via NetworkManager / netplan / systemd-networkd.
# Audit/CI surface for the same policy as LinuxHostBridgeApply (root daemon / UI).
#
# Usage:
#   sudo ./scripts/linux-bridge-apply.sh --apply --nic eth0 --dhcp
#   sudo ./scripts/linux-bridge-apply.sh --apply --nic eth0 --static --address 192.168.1.10/24 --gateway 192.168.1.1 --dns 1.1.1.1 --confirm
#   ./scripts/linux-bridge-apply.sh --dry-run --nic eth0
#   ./scripts/linux-bridge-apply.sh --check
#   sudo ./scripts/linux-bridge-apply.sh --revert
#   sudo ./scripts/linux-bridge-apply.sh --commit
#
# Host address flags are for the Device on br0, not the guest (that is cloud-init).
# After --apply, run --commit within ROLLBACK_SEC or the host auto-reverts.
# Never default-deletes a shared br0.
set -euo pipefail

ACL_MARKER="# barkvisor:allow-br0"
ACL_PATH="${BARKVISOR_BRIDGE_ACL:-/etc/qemu/bridge.conf}"
BRIDGE="${BARKVISOR_BRIDGE:-br0}"
NETPLAN_PATH="/etc/netplan/90-barkvisor-br0.yaml"
PENDING_PATH="/run/barkvisor/${BRIDGE}-pending.json"
COMMIT_STAMP="/run/barkvisor/${BRIDGE}-commit"
ROLLBACK_SEC=120
ACTION=""
NIC=""
ADDRESSING="dhcp"
ADDRESS=""
ADDRESSES=()
GATEWAY=""
DNS=""
CONFIRM=0
DELETE_BRIDGE=0

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) ACTION=apply ;;
    --check) ACTION=check ;;
    --commit) ACTION=commit ;;
    --dry-run) ACTION=dry-run ;;
    --revert) ACTION=revert ;;
    --nic) NIC="${2:-}"; shift ;;
    --bridge) BRIDGE="${2:-}"; shift ;;
    --dhcp) ADDRESSING=dhcp ;;
    --static) ADDRESSING=static ;;
    --address) ADDRESSES+=("${2:-}"); shift ;;
    --gateway) GATEWAY="${2:-}"; shift ;;
    --dns) DNS="${2:-}"; shift ;;
    --confirm) CONFIRM=1 ;;
    --delete-bridge) DELETE_BRIDGE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown flag $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ -z "$ACTION" ]]; then
  echo "error: pass --apply, --check, --dry-run, or --revert" >&2
  exit 2
fi

detect_backend() {
  if [[ -n "${BARKVISOR_BRIDGE_BACKEND:-}" ]]; then
    echo "$BARKVISOR_BRIDGE_BACKEND"
    return
  fi
  if [[ -d /etc/netplan ]]; then
    echo netplan
  elif command -v nmcli >/dev/null 2>&1; then
    echo network-manager
  elif [[ -d /run/systemd/netif ]]; then
    echo systemd-networkd
  elif [[ -f /etc/network/interfaces ]]; then
    echo ifupdown
  else
    echo unknown
  fi
}

is_wifi() {
  local nic="$1"
  local sys="${BARKVISOR_BRIDGE_SYSFS:-/sys/class/net}"
  [[ -d "${sys}/${nic}/wireless" ]]
}

print_changes() {
  local backend="$1" nic="$2"
  echo "CHANGE persist ${BRIDGE} via ${backend} (Device addresses on ${BRIDGE}, not guest)"
  if [[ "$ADDRESSING" == "dhcp" ]]; then
    echo "CHANGE Device IPv4: DHCP (primary)"
  fi
  if [[ ${#ADDRESSES[@]} -gt 0 ]]; then
    for addr in "${ADDRESSES[@]}"; do
      if [[ "$ADDRESSING" == "dhcp" ]]; then
        echo "CHANGE Device static alias ${addr} on ${BRIDGE}"
      else
        echo "CHANGE Device static address ${addr} on ${BRIDGE}"
      fi
    done
  fi
  if [[ -n "$GATEWAY" ]]; then
    echo "CHANGE default route gateway ${GATEWAY} on ${BRIDGE}"
  fi
  if [[ -n "$DNS" ]]; then
    echo "CHANGE nameservers ${DNS} on ${BRIDGE}"
  fi
  echo "CHANGE marker-tagged allow ${BRIDGE} in ${ACL_PATH} (${ACL_MARKER})"
  echo "CHANGE setuid qemu-bridge-helper on known paths"
  case "$backend" in
    netplan)
      echo "CHANGE write ${NETPLAN_PATH} then netplan try --timeout ${ROLLBACK_SEC}"
      ;;
    network-manager)
      echo "CHANGE nmcli bridge barkvisor-${BRIDGE} + systemd-run ${ROLLBACK_SEC}s revert"
      ;;
    systemd-networkd)
      echo "CHANGE write 90-barkvisor-${BRIDGE}.netdev + systemd-run ${ROLLBACK_SEC}s revert"
      ;;
  esac
  echo "CMD sudo linux-bridge-apply.sh --apply --nic ${nic} --${ADDRESSING} --confirm"
}

emit_netplan() {
  if [[ "$ADDRESSING" == "dhcp" && ${#ADDRESSES[@]} -eq 0 ]]; then
    cat <<EOF
# managed-by: barkvisor
network:
  version: 2
  renderer: networkd
  ethernets:
    ${NIC}:
      dhcp4: false
  bridges:
    ${BRIDGE}:
      interfaces: [${NIC}]
      dhcp4: true
EOF
    return
  fi
  cat <<EOF
# managed-by: barkvisor
network:
  version: 2
  renderer: networkd
  ethernets:
    ${NIC}:
      dhcp4: false
  bridges:
    ${BRIDGE}:
      interfaces: [${NIC}]
EOF
  if [[ "$ADDRESSING" == "dhcp" ]]; then
    echo "      dhcp4: true"
  fi
  if [[ ${#ADDRESSES[@]} -gt 0 ]]; then
    if [[ ${#ADDRESSES[@]} -eq 1 ]]; then
      echo "      addresses: [${ADDRESSES[0]}]"
    else
      echo "      addresses:"
      for addr in "${ADDRESSES[@]}"; do
        echo "        - ${addr}"
      done
    fi
  elif [[ -n "$ADDRESS" ]]; then
    echo "      addresses: [${ADDRESS}]"
  fi
  if [[ -n "$GATEWAY" && "$ADDRESSING" != "dhcp" ]]; then
    cat <<EOF
      routes:
        - to: default
          via: ${GATEWAY}
EOF
  fi
  if [[ -n "$DNS" ]]; then
    local dns_list
    dns_list="$(printf '%s' "$DNS" | sed 's/, */, /g')"
    cat <<EOF
      nameservers:
        addresses: [${dns_list}]
EOF
  fi
}

BACKEND="$(detect_backend)"
echo "backend=${BACKEND}"

if [[ "$BACKEND" == "ifupdown" || "$BACKEND" == "unknown" ]]; then
  echo "error: refuse ${BACKEND}. Persist br0 with NetworkManager, netplan, or systemd-networkd." >&2
  exit 3
fi

if [[ "$ACTION" == "revert" ]]; then
  if [[ "$DELETE_BRIDGE" -eq 1 ]]; then
    echo "error: refuse default-delete of ${BRIDGE}. Revert restores the uplink and removes BarkVisor files only." >&2
    exit 4
  fi
  MARKER="${BARKVISOR_DATA_DIR:-/var/lib/barkvisor}/host-bridge-${BRIDGE}.json"
  if [[ ! -f "$MARKER" && -z "${BARKVISOR_BRIDGE_OWNED:-}" ]]; then
    echo "error: no BarkVisor marker for ${BRIDGE}. Will not delete a shared bridge." >&2
    exit 5
  fi
  echo "CHANGE remove BarkVisor ${BRIDGE} files; keep ${BRIDGE} if shared"
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ok: revert planned (never default-deletes ${BRIDGE})"
    exit 0
  fi
  rm -f "$NETPLAN_PATH" \
    "/etc/systemd/network/90-barkvisor-${BRIDGE}.netdev" \
    "/etc/systemd/network/90-barkvisor-${BRIDGE}.network" || true
  if command -v nmcli >/dev/null 2>&1; then
    nmcli connection delete "barkvisor-${BRIDGE}" >/dev/null 2>&1 || true
  fi
  if [[ -f "$ACL_PATH" ]]; then
    tmp="$(mktemp)"
    awk -v marker="$ACL_MARKER" -v allow="allow ${BRIDGE}" '
      $0==marker { skip=1; next }
      skip==1 && $0==allow { skip=0; next }
      { skip=0; print }
    ' "$ACL_PATH" >"$tmp"
    mv "$tmp" "$ACL_PATH"
  fi
  rm -f "$MARKER" "$PENDING_PATH" "$COMMIT_STAMP"
  echo "ok: reverted BarkVisor files; ${BRIDGE} was not deleted"
  exit 0
fi

if [[ "$ACTION" == "commit" ]]; then
  if [[ ! -f "$PENDING_PATH" ]]; then
    echo "error: no pending host network apply for ${BRIDGE}" >&2
    exit 11
  fi
  echo "CHANGE commit pending ${BRIDGE} host network changes"
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "ok: commit planned"
    exit 0
  fi
  mkdir -p /run/barkvisor
  : >"$COMMIT_STAMP"
  np_pid=""
  if command -v python3 >/dev/null 2>&1; then
    np_pid="$(python3 -c "import json; print(json.load(open('${PENDING_PATH}')).get('netplanPid') or '')" 2>/dev/null || true)"
  fi
  if [[ -n "$np_pid" ]]; then
    kill -USR1 "$np_pid" 2>/dev/null || true
  fi
  rm -f "$PENDING_PATH"
  systemctl stop "barkvisor-${BRIDGE}-rollback.timer" 2>/dev/null || true
  systemctl stop "barkvisor-${BRIDGE}-rollback.service" 2>/dev/null || true
  echo "ok: kept host network changes for ${BRIDGE}"
  exit 0
fi

if [[ -z "$NIC" ]]; then
  NIC="${BARKVISOR_BRIDGE_NIC:-}"
fi
if [[ -z "$NIC" && -r /proc/net/route ]]; then
  NIC="$(awk '$2=="00000000" { print $1; exit }' /proc/net/route || true)"
fi
if [[ -z "$NIC" ]]; then
  echo "error: no wired uplink. Pass --nic or have a default route." >&2
  exit 6
fi
if is_wifi "$NIC"; then
  echo "error: refuse Wi-Fi uplink '${NIC}'. Bridge a wired NIC." >&2
  exit 7
fi
if [[ ${#ADDRESSES[@]} -eq 0 && -n "$ADDRESS" ]]; then
  ADDRESSES+=("$ADDRESS")
fi
if [[ "$ADDRESSING" == "static" && ${#ADDRESSES[@]} -eq 0 ]]; then
  echo "error: static host address on ${BRIDGE} needs --address (Device, not guest)." >&2
  exit 8
fi
if [[ "$ADDRESSING" == "static" && -z "$GATEWAY" ]]; then
  echo "error: static host address on ${BRIDGE} needs --gateway (Device, not guest)." >&2
  exit 8
fi

SESSION_RISK="${BARKVISOR_BRIDGE_SESSION_RISK:-}"
if [[ -z "$SESSION_RISK" ]]; then
  if [[ -r /proc/net/tcp ]] && grep -Eq '[[:space:]]0A[[:space:]]' /proc/net/tcp; then
    # LISTEN rows exist; treat default-route NIC as carrying the SPA/SSH if ports 0016 (22) or 1E61 (7777) appear.
    if grep -Eq ':0016[[:space:]]|:1E61[[:space:]]' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
      SESSION_RISK=1
    fi
  fi
fi

if [[ "$SESSION_RISK" == "1" && "$CONFIRM" -ne 1 && "$ACTION" != "check" ]]; then
  echo "WARN ${NIC} may carry SSH or the SPA session. Pass --confirm."
  echo "WARN after --apply, run --commit within ${ROLLBACK_SEC}s or the host auto-reverts."
  print_changes "$BACKEND" "$NIC"
  echo "needsConfirm=true"
  exit 9
fi

print_changes "$BACKEND" "$NIC"

if [[ "$ACTION" == "check" || "$ACTION" == "dry-run" ]]; then
  if [[ "$ACTION" == "dry-run" && "$BACKEND" == "netplan" ]]; then
    emit_netplan
  fi
  echo "ok: ${ACTION} (${BRIDGE} via ${BACKEND} on ${NIC})"
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: --apply/--revert need root (or use --dry-run)" >&2
  exit 10
fi

DATA_DIR="${BARKVISOR_DATA_DIR:-/var/lib/barkvisor}"
mkdir -p "$DATA_DIR" "$(dirname "$ACL_PATH")" /run/barkvisor
rollback_helper="/run/barkvisor/${BRIDGE}-rollback.sh"
cat >"$rollback_helper" <<EOF
#!/bin/sh
if [ -f $COMMIT_STAMP ]; then exit 0; fi
rm -f $NETPLAN_PATH || true
/usr/sbin/netplan apply >/dev/null 2>&1 || true
/usr/bin/nmcli connection delete barkvisor-${BRIDGE} >/dev/null 2>&1 || true
rm -f /etc/systemd/network/90-barkvisor-${BRIDGE}.netdev /etc/systemd/network/90-barkvisor-${BRIDGE}.network || true
/usr/bin/networkctl reload >/dev/null 2>&1 || true
rm -f ${DATA_DIR}/host-bridge-${BRIDGE}.json $PENDING_PATH || true
EOF
chmod 0755 "$rollback_helper" || true

case "$BACKEND" in
  netplan)
    emit_netplan >"$NETPLAN_PATH"
    if command -v netplan >/dev/null 2>&1; then
      netplan try --timeout "$ROLLBACK_SEC" &
      np_pid=$!
      deadline="$(date -u -d "@$(($(date +%s) + ROLLBACK_SEC))" +%Y-%m-%dT%H:%M:%SZ)"
      printf '{"target":"%s","commitDeadline":"%s","rollbackSeconds":%s,"netplanPid":%s}\n' \
        "$BRIDGE" "$deadline" "$ROLLBACK_SEC" "$np_pid" >"$PENDING_PATH"
    fi
    ;;
  network-manager)
    addr_joined=""
    if [[ ${#ADDRESSES[@]} -gt 0 ]]; then
      addr_joined="$(IFS=,; echo "${ADDRESSES[*]}")"
    elif [[ -n "$ADDRESS" ]]; then
      addr_joined="$ADDRESS"
    fi
    if [[ "$ADDRESSING" == "static" ]]; then
      if [[ -n "$DNS" ]]; then
        nmcli connection add type bridge ifname "$BRIDGE" con-name "barkvisor-${BRIDGE}" \
          ipv4.method manual ipv4.addresses "$addr_joined" ipv4.gateway "$GATEWAY" \
          ipv4.dns "$DNS" || true
      else
        nmcli connection add type bridge ifname "$BRIDGE" con-name "barkvisor-${BRIDGE}" \
          ipv4.method manual ipv4.addresses "$addr_joined" ipv4.gateway "$GATEWAY" || true
      fi
    elif [[ -n "$addr_joined" ]]; then
      nmcli connection add type bridge ifname "$BRIDGE" con-name "barkvisor-${BRIDGE}" \
        ipv4.method auto ipv4.addresses "$addr_joined" || true
    else
      nmcli connection add type bridge ifname "$BRIDGE" con-name "barkvisor-${BRIDGE}" \
        ipv4.method auto || true
    fi
    ;;
  systemd-networkd)
    cat >"/etc/systemd/network/90-barkvisor-${BRIDGE}.netdev" <<EOF
# managed-by: barkvisor
[NetDev]
Name=${BRIDGE}
Kind=bridge
EOF
    {
      echo "# managed-by: barkvisor"
      echo "[Match]"
      echo "Name=${BRIDGE}"
      echo
      echo "[Network]"
      if [[ "$ADDRESSING" == "dhcp" ]]; then
        echo "DHCP=yes"
      fi
      if [[ ${#ADDRESSES[@]} -gt 0 ]]; then
        for addr in "${ADDRESSES[@]}"; do
          echo "Address=${addr}"
        done
      elif [[ -n "$ADDRESS" ]]; then
        echo "Address=${ADDRESS}"
      fi
      if [[ -n "$GATEWAY" && "$ADDRESSING" != "dhcp" ]]; then
        echo "Gateway=${GATEWAY}"
      fi
      if [[ -n "$DNS" ]]; then
        IFS=',' read -ra _dns <<< "$DNS"
        for d in "${_dns[@]}"; do
          echo "DNS=${d// /}"
        done
      fi
    } >"/etc/systemd/network/90-barkvisor-${BRIDGE}.network"
    ;;
esac

if [[ "$BACKEND" != "netplan" ]]; then
  deadline="$(date -u -d "@$(($(date +%s) + ROLLBACK_SEC))" +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"target":"%s","commitDeadline":"%s","rollbackSeconds":%s}\n' \
    "$BRIDGE" "$deadline" "$ROLLBACK_SEC" >"$PENDING_PATH"
fi

systemctl stop "barkvisor-${BRIDGE}-rollback.timer" 2>/dev/null || true
systemd-run --on-active="${ROLLBACK_SEC}s" --unit="barkvisor-${BRIDGE}-rollback" \
  "$rollback_helper" >/dev/null 2>&1 || true

{
  echo "$ACL_MARKER"
  echo "allow ${BRIDGE}"
} >>"$ACL_PATH"

for helper in \
  /usr/lib/qemu/qemu-bridge-helper \
  /usr/libexec/qemu-bridge-helper \
  /usr/local/libexec/qemu/qemu-bridge-helper
do
  if [[ -x "$helper" ]]; then
    chmod u+s "$helper" || true
  fi
done

printf '{"bridge":"%s","createdBridge":true}\n' "$BRIDGE" >"${DATA_DIR}/host-bridge-${BRIDGE}.json"
echo "ok: applied ${BRIDGE} via ${BACKEND} on ${NIC} (pending commit; run --commit within ${ROLLBACK_SEC}s)"
exit 0
