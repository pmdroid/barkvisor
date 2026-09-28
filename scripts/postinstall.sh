#!/bin/bash
set -euo pipefail

if [ -z "${BARKVISOR_HOST_ROOT:-}" ] && [ "$(id -u)" -ne 0 ]; then
  echo "BarkVisor package postinstall must run as root." >&2
  exit 1
fi

if [ -z "${BARKVISOR_HOST_ROOT:-}" ]; then
  for bin in /usr/local/libexec/barkvisor/*; do
    [ -x "$bin" ] || continue
    install_name_tool -add_rpath /usr/local/lib/barkvisor "$bin" 2>/dev/null || true
  done

  launchctl bootout system/dev.barkvisor.helper 2>/dev/null || true
  rm -f /Library/LaunchDaemons/dev.barkvisor.helper.plist
  rm -f /Library/PrivilegedHelperTools/dev.barkvisor.helper
  rm -f /usr/local/libexec/dev.barkvisor.helper
  rm -f /usr/local/libexec/barkvisor/dev.barkvisor.helper
  rm -f /usr/local/libexec/BarkVisorHelper
  rm -f /usr/local/libexec/barkvisor/BarkVisorHelper
fi

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
if [ -f "$here/pkg-service-handoff.sh" ]; then
  bash "$here/pkg-service-handoff.sh"
else
  bash /usr/local/libexec/barkvisor/pkg-service-handoff.sh
fi

echo ""
echo "========================================="
echo "  BarkVisor installed successfully!"
echo "  BarkDaemon and BarkServer are running."
echo "  Open http://localhost:7777 to complete setup."
echo "========================================="
