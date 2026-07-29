#!/usr/bin/env bash
set -euo pipefail
BIN_SRC="${1:-}"
if [[ -z "$BIN_SRC" ]]; then
  if [[ -x ".build/release/BarkVisorApp" ]]; then BIN_SRC=".build/release/BarkVisorApp"
  elif [[ -x ".build/debug/BarkVisorApp" ]]; then BIN_SRC=".build/debug/BarkVisorApp"
  else echo "Usage: $0 /path/to/BarkVisorApp" >&2; exit 1; fi
fi
[[ "$(id -u)" -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
install -d /usr/local/bin /var/lib/barkvisor /var/run/barkvisor /usr/local/lib/systemd/system
install -m 0755 "$BIN_SRC" /usr/local/bin/barkvisor
id barkvisor &>/dev/null || useradd --system --home /var/lib/barkvisor --shell /usr/sbin/nologin barkvisor
getent group kvm &>/dev/null && usermod -aG kvm barkvisor || true
chown -R barkvisor:barkvisor /var/lib/barkvisor /var/run/barkvisor
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
install -m 0644 "$SCRIPT_DIR/../Resources/barkvisor.service" /usr/local/lib/systemd/system/barkvisor.service
systemctl daemon-reload
systemctl enable --now barkvisor.service
systemctl --no-pager --full status barkvisor.service || true
echo "UI: http://$(hostname -I 2>/dev/null | awk \"{print \$1}\"):7777"

# --- SPA (optional) ---
# If you built the frontend (./scripts/linux-frontend-serve.sh), serve it with:
#   export BARKVISOR_FRONTEND_DIR=/path/to/frontend/dist
# Or copy into the package layout under share/frontend/dist before install.
