#!/usr/bin/env bash
# Start/stop/verify socket_vmnet from the root Device daemon.
# Audit/CI surface for the same policy as SocketVmnetApply (Networks UI).
#
# Usage:
#   ./scripts/macos-socket-vmnet.sh --check
#   sudo ./scripts/macos-socket-vmnet.sh --setup --interface en0
#   sudo ./scripts/macos-socket-vmnet.sh --start --interface en0
#   sudo ./scripts/macos-socket-vmnet.sh --stop --interface en0
#
# Never install the formula as root into /opt/homebrew. Never a privileged helper.
# Does not enslave the Mac LAN NIC. NAT Workloads work with the service down.
set -euo pipefail

ACTION=""
IFACE="${BARKVISOR_SOCKET_VMNET_IFACE:-en0}"
OWNED_PREFIX="dev.barkvisor.socket-vmnet"
BREW_LABEL="homebrew.mxcl.socket_vmnet"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --setup) ACTION=setup ;;
    --start) ACTION=start ;;
    --stop) ACTION=stop ;;
    --check) ACTION=check ;;
    --interface|--iface) IFACE="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown flag $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ -z "$ACTION" ]]; then
  echo "error: pass --setup, --start, --stop, or --check" >&2
  exit 2
fi

if [[ "$IFACE" == *[!A-Za-z0-9._-]* || -z "$IFACE" ]]; then
  echo "error: invalid interface '$IFACE'" >&2
  exit 2
fi

OWNED_LABEL="${OWNED_PREFIX}.${IFACE}"
OWNED_PLIST="/Library/LaunchDaemons/${OWNED_LABEL}.plist"
OWNED_SOCK="/var/run/socket_vmnet.bridged.${IFACE}"

socket_paths() {
  printf '%s\n' \
    "/opt/homebrew/var/run/socket_vmnet.bridged.${IFACE}" \
    "/usr/local/var/run/socket_vmnet.bridged.${IFACE}" \
    "$OWNED_SOCK" \
    "/opt/homebrew/var/run/socket_vmnet" \
    "/usr/local/var/run/socket_vmnet" \
    "/var/run/socket_vmnet"
}

binary_candidates() {
  printf '%s\n' \
    "/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet" \
    "/opt/homebrew/bin/socket_vmnet" \
    "/usr/local/opt/socket_vmnet/bin/socket_vmnet" \
    "/usr/local/bin/socket_vmnet" \
    "/opt/socket_vmnet/bin/socket_vmnet"
}

brew_plist_candidates() {
  printf '%s\n' \
    "/Library/LaunchDaemons/${BREW_LABEL}.plist" \
    "/opt/homebrew/opt/socket_vmnet/homebrew.mxcl.socket_vmnet.plist" \
    "/usr/local/opt/socket_vmnet/homebrew.mxcl.socket_vmnet.plist"
}

brew_binaries() {
  printf '%s\n' /opt/homebrew/bin/brew /usr/local/bin/brew
}

first_existing() {
  local path
  while IFS= read -r path; do
    if [[ -e "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

service_loaded() {
  local label="$1"
  if [[ "$(uname -s)" != Darwin ]]; then
    return 1
  fi
  launchctl print "system/${label}" >/dev/null 2>&1
}

report_check() {
  local path present=0 loaded_owned=0 loaded_brew=0 backend=none
  while IFS= read -r path; do
    if [[ -e "$path" ]]; then
      echo "socket=${path} present=yes"
      present=1
    else
      echo "socket=${path} present=no"
    fi
  done < <(socket_paths)
  if service_loaded "$OWNED_LABEL"; then
    echo "service=${OWNED_LABEL} loaded=yes"
    loaded_owned=1
  else
    echo "service=${OWNED_LABEL} loaded=no"
  fi
  if service_loaded "$BREW_LABEL"; then
    echo "service=${BREW_LABEL} loaded=yes"
    loaded_brew=1
  else
    echo "service=${BREW_LABEL} loaded=no"
  fi
  if [[ "$loaded_owned" -eq 1 ]]; then
    backend=owned-launchd
  elif [[ "$loaded_brew" -eq 1 ]]; then
    backend=homebrew-service
  fi
  echo "backend=${backend}"
  if [[ "$present" -eq 1 && ( "$loaded_owned" -eq 1 || "$loaded_brew" -eq 1 ) ]]; then
    echo "socket present; service running"
  elif [[ "$present" -eq 1 ]]; then
    echo "socket present; service not loaded"
  elif [[ "$loaded_owned" -eq 1 || "$loaded_brew" -eq 1 ]]; then
    echo "service running; socket missing"
  else
    echo "socket missing; service not loaded"
  fi
}

refuse_brew_install() {
  echo "error: never install the formula as root. Install as your user: brew install socket_vmnet" >&2
  exit 6
}

start_owned() {
  local binary
  binary="$(binary_candidates | first_existing)" || {
    echo "error: socket_vmnet binary not found. brew install socket_vmnet (as your user, never as root)" >&2
    exit 5
  }
  cat >"$OWNED_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${OWNED_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${binary}</string>
        <string>--vmnet-mode=bridged</string>
        <string>--vmnet-interface=${IFACE}</string>
        <string>${OWNED_SOCK}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
  launchctl bootout "system/${OWNED_LABEL}" 2>/dev/null || true
  launchctl bootstrap system "$OWNED_PLIST"
  echo "started owned-launchd ${OWNED_LABEL}"
}

start_brew() {
  local plist brew
  if plist="$(brew_plist_candidates | first_existing)"; then
    launchctl bootout "system/${BREW_LABEL}" 2>/dev/null || true
    launchctl bootstrap system "$plist"
    echo "started homebrew-service ${BREW_LABEL}"
    return
  fi
  brew="$(brew_binaries | first_existing)" || {
    echo "error: socket_vmnet is not installed. brew install socket_vmnet (as your user, never as root)" >&2
    exit 5
  }
  "$brew" services start socket_vmnet
  echo "started homebrew-service via brew services"
}

stop_all() {
  launchctl bootout "system/${OWNED_LABEL}" 2>/dev/null || true
  launchctl bootout "system/${BREW_LABEL}" 2>/dev/null || true
  if brew="$(brew_binaries | first_existing)"; then
    "$brew" services stop socket_vmnet 2>/dev/null || true
  fi
  echo "stopped socket_vmnet"
}

case "$ACTION" in
  check)
    report_check
    ;;
  setup|start)
    if [[ "$(uname -s)" != Darwin ]]; then
      echo "error: socket_vmnet start runs on macOS" >&2
      exit 3
    fi
    if binary_candidates | first_existing >/dev/null && [[ -w /Library/LaunchDaemons || -f "$OWNED_PLIST" ]]; then
      start_owned
    elif brew_plist_candidates | first_existing >/dev/null || brew_binaries | first_existing >/dev/null; then
      start_brew
    else
      refuse_brew_install
    fi
    ;;
  stop)
    if [[ "$(uname -s)" != Darwin ]]; then
      echo "error: socket_vmnet stop runs on macOS" >&2
      exit 3
    fi
    stop_all
    ;;
esac
