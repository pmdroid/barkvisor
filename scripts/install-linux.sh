#!/usr/bin/env bash
# Install BarkVisor as a systemd service on Linux (root).
#
# Usage:
#   sudo ./scripts/install-linux.sh [/path/to/BarkVisorApp]
#   sudo DRY_RUN=1 ./scripts/install-linux.sh              # print actions only
#   sudo SKIP_START=1 ./scripts/install-linux.sh           # install unit, do not enable/start
#   sudo SKIP_FRONTEND=1 ./scripts/install-linux.sh        # API-only; skip SPA even if frontend/dist exists
#   sudo FRONTEND_DIST=./frontend/dist ./scripts/install-linux.sh
#
# Layout (matches Config.prefix when binary is /usr/local/bin/barkvisor):
#   /usr/local/bin/barkvisor
#   /usr/local/share/barkvisor/frontend/dist/   # SPA (optional)
#   /usr/local/lib/systemd/system/barkvisor.service
#   /etc/barkvisor/barkvisor.env                # EnvironmentFile
#   /var/lib/barkvisor  /var/run/barkvisor
#
# Orb / VM dry-run (no root needed for the print path):
#   DRY_RUN=1 ./scripts/install-linux.sh .build/release/BarkVisorApp
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/linux-swift-compat.sh
source "$ROOT/scripts/lib/linux-swift-compat.sh"

DRY_RUN="${DRY_RUN:-0}"
SKIP_START="${SKIP_START:-0}"
SKIP_FRONTEND="${SKIP_FRONTEND:-0}"

PREFIX="${PREFIX:-/usr/local}"
BIN_DST="${PREFIX}/bin/barkvisor"
SHARE_DST="${PREFIX}/share/barkvisor"
FRONTEND_DST="${SHARE_DST}/frontend/dist"
COMPAT_DST="${PREFIX}/lib/barkvisor/compat"
UNIT_DST="/usr/local/lib/systemd/system/barkvisor.service"
ENV_DIR="/etc/barkvisor"
ENV_FILE="${ENV_DIR}/barkvisor.env"
DATA_DIR="/var/lib/barkvisor"
RUN_DIR="/var/run/barkvisor"

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN: $*"
  else
    "$@"
  fi
}

need_root() {
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  [[ "$(id -u)" -eq 0 ]] || {
    echo "error: run as root (or DRY_RUN=1)" >&2
    exit 1
  }
}

# --- resolve binary ---
BIN_SRC="${1:-}"
if [[ -z "$BIN_SRC" ]]; then
  if [[ -x "$ROOT/.build/release/BarkVisorApp" ]]; then
    BIN_SRC="$ROOT/.build/release/BarkVisorApp"
  elif [[ -x "$ROOT/.build/debug/BarkVisorApp" ]]; then
    BIN_SRC="$ROOT/.build/debug/BarkVisorApp"
  else
    echo "Usage: $0 [/path/to/BarkVisorApp]" >&2
    echo "  Build first: swift build -c release --product BarkVisorApp" >&2
    exit 1
  fi
fi
[[ -x "$BIN_SRC" || "$DRY_RUN" == "1" ]] || {
  echo "error: not executable: $BIN_SRC" >&2
  exit 1
}

# --- resolve SPA dist (optional) ---
# SKIP_FRONTEND=1 is API-only even when frontend/dist or FRONTEND_DIST exists.
FRONTEND_SRC=""
if [[ "$SKIP_FRONTEND" != "1" ]]; then
  FRONTEND_SRC="${FRONTEND_DIST:-}"
  if [[ -z "$FRONTEND_SRC" ]]; then
    for cand in \
      "$ROOT/frontend/dist" \
      "$ROOT/Sources/BarkVisor/Resources/frontend/dist" \
      "${BARKVISOR_FRONTEND_DIR:-}"; do
      if [[ -n "$cand" && -f "$cand/index.html" ]]; then
        FRONTEND_SRC="$cand"
        break
      fi
    done
  fi
fi

echo "==> BarkVisor Linux install"
echo "    binary:  $BIN_SRC → $BIN_DST"
echo "    data:    $DATA_DIR"
echo "    unit:    $UNIT_DST"
if [[ -n "$FRONTEND_SRC" ]]; then
  echo "    SPA:     $FRONTEND_SRC → $FRONTEND_DST"
else
  echo "    SPA:     (none — API only; set FRONTEND_DIST= or build frontend/dist)"
fi
[[ "$DRY_RUN" == "1" ]] && echo "    mode:    DRY_RUN (no changes)"

need_root

run install -d "$PREFIX/bin" "$DATA_DIR" "$RUN_DIR" "$(dirname "$UNIT_DST")" "$ENV_DIR" "$COMPAT_DST"
run install -m 0755 "$BIN_SRC" "$BIN_DST"

if [[ -n "$FRONTEND_SRC" ]]; then
  run install -d "$FRONTEND_DST"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY_RUN: cp -a $FRONTEND_SRC/. $FRONTEND_DST/"
  else
    rm -rf "${FRONTEND_DST:?}/"*
    cp -a "$FRONTEND_SRC"/. "$FRONTEND_DST"/
    # ensure index.html landed
    [[ -f "$FRONTEND_DST/index.html" ]] || {
      echo "error: SPA copy failed (no index.html in $FRONTEND_DST)" >&2
      exit 1
    }
  fi
fi

# SONAME shims (Ubuntu 26+ libxml2.so.16 → libxml2.so.2, etc.)
if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN: install SONAME compat under $COMPAT_DST"
else
  export BARKVISOR_COMPAT_DIR="$COMPAT_DST"
  barkvisor_ensure_swift_compat || true
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN: create system user barkvisor if missing"
  echo "DRY_RUN: usermod -aG kvm barkvisor (if group exists)"
  echo "DRY_RUN: usermod -aG disk barkvisor and write service.d/disk.conf (if group exists)"
  echo "DRY_RUN: chown barkvisor:barkvisor $DATA_DIR $RUN_DIR"
else
  id barkvisor &>/dev/null || useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin barkvisor
  getent group kvm &>/dev/null && usermod -aG kvm barkvisor || true
  if getent group disk &>/dev/null; then
    usermod -aG disk barkvisor || true
    mkdir -p /etc/systemd/system/barkvisor.service.d
    printf '%s\n' '[Service]' 'SupplementaryGroups=disk' \
      >/etc/systemd/system/barkvisor.service.d/disk.conf
  fi
  chown -R barkvisor:barkvisor "$DATA_DIR" "$RUN_DIR"
  if [[ -d "$SHARE_DST" ]]; then
    chown -R root:root "$SHARE_DST"
  fi
  if [[ -d "$COMPAT_DST" ]]; then
    chown -R root:root "$COMPAT_DST"
  fi
fi

# Environment file (override port / data / frontend without editing the unit)
if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN: write $ENV_FILE"
else
  if [[ ! -f "$ENV_FILE" ]]; then
    cat >"$ENV_FILE" <<EOF
# BarkVisor daemon environment (systemd EnvironmentFile)
BARKVISOR_PORT=7777
BARKVISOR_DATA_DIR=${DATA_DIR}
BARKVISOR_SOCKET_DIR=${RUN_DIR}
# SPA is resolved via Config.frontendDir (${FRONTEND_DST}) when installed under ${PREFIX}.
# Uncomment to force a custom dist path:
# BARKVISOR_FRONTEND_DIR=${FRONTEND_DST}
# Optional first-boot join (pairing offer from the other Device). Ignored after setup.
# BARKVISOR_JOIN_CODE=
HOME=${DATA_DIR}
# SONAME shims for hosts newer than the Swift LTS toolchain (see scripts/lib/linux-swift-compat.sh).
LD_LIBRARY_PATH=${COMPAT_DST}
EOF
    chmod 0644 "$ENV_FILE"
  else
    # Ensure LD_LIBRARY_PATH is present on upgrades of older installs.
    if ! grep -qE '^LD_LIBRARY_PATH=' "$ENV_FILE" 2>/dev/null; then
      echo "LD_LIBRARY_PATH=${COMPAT_DST}" >>"$ENV_FILE"
    fi
  fi
fi

run install -m 0644 "$ROOT/Resources/barkvisor.service" "$UNIT_DST"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN: systemctl daemon-reload"
  if [[ "$SKIP_START" != "1" ]]; then
    echo "DRY_RUN: systemctl enable --now barkvisor.service"
    echo "DRY_RUN: systemctl status barkvisor.service"
  else
    echo "DRY_RUN: SKIP_START=1 — would not enable/start"
  fi
else
  systemctl daemon-reload
  if systemctl is-active --quiet barkvisor.service; then
    systemctl try-restart barkvisor.service || true
  elif [[ "$SKIP_START" != "1" ]]; then
    systemctl enable --now barkvisor.service
    systemctl --no-pager --full status barkvisor.service || true
  else
    systemctl enable barkvisor.service
    echo "Installed unit (not started). Start with: systemctl start barkvisor.service"
  fi
fi

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
echo
echo "UI: http://${HOST_IP:-127.0.0.1}:7777"
echo "Env: $ENV_FILE"
echo "Logs: journalctl -u barkvisor.service -f"
if [[ -z "$FRONTEND_SRC" ]]; then
  echo
  echo "Note: no SPA installed (API-only Device)."
  echo "Join a Home from this Device after the daemon is up:"
  echo "  barkvisor join --code 'barkvisor://pair/v1?…'"
  echo "Or set BARKVISOR_JOIN_CODE in $ENV_FILE before first boot."
  echo "To add the SPA later:"
  echo "  ./scripts/linux-frontend-serve.sh"
  echo "  sudo FRONTEND_DIST=./frontend/dist $0 $BIN_SRC"
fi
[[ "$DRY_RUN" == "1" ]] && echo && echo "linux install DRY_RUN: OK"
