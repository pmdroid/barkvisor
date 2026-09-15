#!/bin/sh
set -e
src=/usr/local/share/barkvisor/udev/99-barkvisor-vfio.rules
dst=/usr/lib/udev/rules.d/99-barkvisor-vfio.rules
[ -f "$src" ] || exit 0
[ -d /usr/lib/udev/rules.d ] || exit 0
cp -f "$src" "$dst" || exit 0
if command -v udevadm >/dev/null 2>&1; then
  udevadm control --reload || true
  udevadm trigger --subsystem-match=vfio || true
fi
exit 0
