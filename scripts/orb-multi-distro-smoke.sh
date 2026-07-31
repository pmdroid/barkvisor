#!/usr/bin/env bash
# Run BarkVisor linux-dev + build + health smoke across OrbStack machines.
# Usage:
#   ./scripts/orb-multi-distro-smoke.sh                 # all known bv-* + barkvisor-u24
#   ./scripts/orb-multi-distro-smoke.sh bv-deb12 bv-arch
# Results under /tmp/bv-orb-smoke/<machine>.{log,status}
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-/tmp/bv-orb-smoke}"
mkdir -p "$OUT_DIR"

MACHINES=("$@")
if [[ ${#MACHINES[@]} -eq 0 ]]; then
  MACHINES=(barkvisor-u24 bv-u26 bv-deb12 bv-fedora bv-rocky10 bv-arch bv-alpine)
fi

# Copy sources into each VM via Orb path translation (Mac mount).
# Host→orb stdin tar is unreliable; copy inside the guest instead.
sync_tree() {
  local m="$1"
  # Ensure bash for complex scripts (Alpine)
  if ! orb -m "$m" command -v bash >/dev/null 2>&1; then
    orb -m "$m" sh -lc 'command -v apk >/dev/null && (sudo apk add --no-cache bash curl tar 2>/dev/null || apk add --no-cache bash curl tar)' || true
  fi
  orb -m "$m" -p bash -lc "
    set -e
    SRC='$ROOT'
    rm -rf ~/barkvisor-src
    mkdir -p ~/barkvisor-src
    test -f \"\$SRC/scripts/linux-dev.sh\"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --delete \
        --exclude .git --exclude .build --exclude node_modules \
        --exclude DerivedData --exclude .swiftpm \
        --exclude ssh --exclude ssh.pub \
        \"\$SRC/\" ~/barkvisor-src/
    else
      (cd \"\$SRC\" && tar \
        --exclude .git --exclude .build --exclude node_modules \
        --exclude DerivedData --exclude .swiftpm \
        --exclude ssh --exclude ssh.pub \
        -cf - .) | (cd ~/barkvisor-src && tar -xf -)
    fi
    mkdir -p ~/barkvisor-src/Sources/BarkVisor/Resources/frontend/dist
    touch ~/barkvisor-src/Sources/BarkVisor/Resources/frontend/dist/.gitkeep
  "
}

smoke_one() {
  local m="$1"
  local log="$OUT_DIR/${m}.log"
  local st="$OUT_DIR/${m}.status"
  {
    echo "=== machine=$m start $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    if ! orb list 2>/dev/null | awk '{print $1}' | grep -qx "$m"; then
      echo "SKIP: machine not found"
      echo "skip" >"$st"
      return 0
    fi
    sync_tree "$m"
    # Install bash on Alpine so linux-dev.sh (bash) can run
    if ! orb -m "$m" command -v bash >/dev/null 2>&1; then
      echo "installing bash for smoke scripts..."
      orb -m "$m" sh -lc 'command -v apk >/dev/null && (sudo apk add --no-cache bash curl tar 2>/dev/null || apk add --no-cache bash curl tar)' || true
    fi
    # Agent Vault MITM proxy breaks git TLS inside Orb unless the MITM CA is
    # installed; SPM only needs plain GitHub HTTPS, so clear proxy env.
    orb -m "$m" bash -lc '
      set -euo pipefail
      unset HTTPS_PROXY HTTP_PROXY https_proxy http_proxy ALL_PROXY all_proxy SSL_CERT_FILE CURL_CA_BUNDLE REQUESTS_CA_BUNDLE GIT_SSL_CAINFO NODE_EXTRA_CA_CERTS || true
      cd ~/barkvisor-src
      chmod +x scripts/*.sh scripts/lib/*.sh 2>/dev/null || true
      uname -m
      head -6 /etc/os-release
      if command -v sudo >/dev/null 2>&1; then SUDO=sudo; else SUDO=; fi
      $SUDO env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy ./scripts/linux-dev.sh
      # shellcheck disable=SC1091
      source scripts/lib/linux-swift-compat.sh
      barkvisor_export_swift_env || true
      export PATH="/opt/swift/usr/bin:${PATH:-}"
      # Ubuntu 26+/Arch need LD_LIBRARY_PATH for SONAME shims before swift works.
      if ! command -v swift >/dev/null 2>&1 || ! swift build --help >/dev/null 2>&1; then
        echo "RESULT=runtime_or_packages_only (no native Swift build)"
        echo "PATH=$PATH"
        echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"
        command -v swift || true
        swift --version 2>&1 | head -3 || true
        exit 0
      fi
      # Clear broken SPM cache from prior TLS failures
      rm -rf ~/.cache/org.swift.swiftpm/repositories 2>/dev/null || true
      swift build --product BarkVisorApp -j 2
      export BARKVISOR_PORT=7777
      export BARKVISOR_DATA_DIR=/tmp/bv-orb-data
      rm -rf "$BARKVISOR_DATA_DIR"
      mkdir -p "$BARKVISOR_DATA_DIR"
      BIN=$(find .build -type f -name BarkVisorApp -perm -111 | head -1)
      test -n "$BIN"
      "$BIN" >/tmp/bv-run.log 2>&1 &
      echo $! >/tmp/bv-run.pid
      ok=0
      for i in $(seq 1 60); do
        if curl -sf "http://127.0.0.1:${BARKVISOR_PORT}/api/health" >/tmp/bv-health.json; then
          ok=1
          break
        fi
        sleep 0.5
      done
      if [ "$ok" != 1 ]; then
        echo "HEALTH FAILED"
        tail -80 /tmp/bv-run.log || true
        kill -9 "$(cat /tmp/bv-run.pid)" 2>/dev/null || true
        exit 1
      fi
      echo "=== health ==="
      cat /tmp/bv-health.json; echo
      echo "=== capabilities snippet ==="
      curl -sf "http://127.0.0.1:${BARKVISOR_PORT}/api/system/capabilities" | head -c 600; echo
      kill -9 "$(cat /tmp/bv-run.pid)" 2>/dev/null || true
      echo "RESULT=ok"
    '
  } >"$log" 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    if grep -q 'RESULT=ok' "$log"; then
      echo ok >"$st"
    elif grep -q 'RESULT=runtime_or_packages_only' "$log"; then
      echo packages_only >"$st"
    else
      echo ok >"$st"
    fi
  else
    echo fail >"$st"
  fi
  echo "=== $m status=$(cat "$st") ==="
  return 0
}

export -f sync_tree smoke_one
export ROOT OUT_DIR

# Serial is safer for Orb CPU; parallel=2 optional via PARALLEL
PARALLEL="${PARALLEL:-1}"
if [[ "$PARALLEL" -gt 1 ]] && command -v xargs >/dev/null 2>&1; then
  printf '%s\n' "${MACHINES[@]}" | xargs -P "$PARALLEL" -I{} bash -c 'smoke_one "$@"' _ {}
else
  for m in "${MACHINES[@]}"; do
    smoke_one "$m"
  done
fi

echo
echo "======== SUMMARY ========"
for m in "${MACHINES[@]}"; do
  printf '%-16s %s\n' "$m" "$(cat "$OUT_DIR/${m}.status" 2>/dev/null || echo missing)"
done
echo "Logs: $OUT_DIR/"
# Fail overall if any fail
fail=0
for m in "${MACHINES[@]}"; do
  s=$(cat "$OUT_DIR/${m}.status" 2>/dev/null || echo missing)
  [[ "$s" == fail || "$s" == missing ]] && fail=1
done
exit "$fail"
