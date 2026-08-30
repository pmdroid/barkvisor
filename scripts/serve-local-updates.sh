#!/usr/bin/env bash
# Serve a GitHub-shaped releases feed from a directory of built packages so
# Settings → Updates Apply can be tested without publishing a GitHub release.
#
# Production Devices keep using api.github.com. This server binds 127.0.0.1 only.
#
# Usage:
#   scripts/serve-local-updates.sh --dir dist [--port 8765] [--tag v9.9.9] [--prerelease]
#   scripts/serve-local-updates.sh --dir dist --dry-run
#
# --dir must contain at least one barkvisor_<ver>_{amd64,arm64}.deb or *.pkg
# (not .sha256, not bottle). A matching <filename>.sha256 is required; missing
# sidecars are written with `shasum -a 256`.
set -euo pipefail

DIR=""
PORT=8765
TAG=""
PRERELEASE=0
DRY_RUN=0

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)
      DIR="${2:?--dir needs a directory}"
      shift 2
      ;;
    --port)
      PORT="${2:?--port needs a number}"
      shift 2
      ;;
    --tag)
      TAG="${2:?--tag needs a tag}"
      shift 2
      ;;
    --prerelease)
      PRERELEASE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

[[ -n "$DIR" ]] || die "missing --dir"
[[ "$PORT" =~ ^[0-9]+$ ]] && [[ "$PORT" -ge 1 && "$PORT" -le 65535 ]] || die "invalid --port: $PORT"
[[ -d "$DIR" ]] || die "directory not found: $DIR"
DIR="$(cd "$DIR" && pwd)"

command -v python3 >/dev/null 2>&1 || die "python3 is required"

is_package() {
  local base="$1"
  local lower
  lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.sha256) return 1 ;;
    *bottle*) return 1 ;;
    *homebrew*) return 1 ;;
    barkvisor_*_amd64.deb | barkvisor_*_arm64.deb) return 0 ;;
    *.pkg) return 0 ;;
    *) return 1 ;;
  esac
}

infer_tag() {
  local name="$1"
  if [[ "$name" =~ ^barkvisor_(.+)_amd64\.deb$ || "$name" =~ ^barkvisor_(.+)_arm64\.deb$ ]]; then
    printf 'v%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$name" =~ ^BarkVisor-(.+)\.pkg$ ]]; then
    printf 'v%s\n' "${BASH_REMATCH[1]}"
  elif [[ "$name" =~ ^(.+)\.pkg$ ]]; then
    printf 'v%s\n' "${BASH_REMATCH[1]}"
  else
    printf 'v0.0.0-local\n'
  fi
}

ensure_sha() {
  local pkg="$1"
  local sha="$pkg.sha256"
  if [[ -f "$sha" ]]; then
    local token
    token="$(awk '{print $1; exit}' "$sha")"
    [[ "$token" =~ ^[0-9a-fA-F]{64}$ ]] || die "invalid sha256 sidecar (need 64 hex): $sha"
    return 0
  fi
  command -v shasum >/dev/null 2>&1 || die "shasum is required to write $sha"
  (cd "$DIR" && shasum -a 256 "$(basename "$pkg")" >"$(basename "$sha")")
}

packages=()
for f in "$DIR"/*; do
  [[ -f "$f" ]] || continue
  base="$(basename "$f")"
  if is_package "$base"; then
    packages+=("$base")
  fi
done

[[ ${#packages[@]} -gt 0 ]] || die "no barkvisor_*.deb or *.pkg in $DIR"

assets=()
for base in "${packages[@]}"; do
  ensure_sha "$DIR/$base"
  assets+=("$base" "$base.sha256")
done

if [[ -z "$TAG" ]]; then
  TAG="$(infer_tag "${packages[0]}")"
fi
[[ -n "$TAG" ]] || TAG="v0.0.0-local"

PUBLISHED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BODY="Local update feed for testing Apply."

BV_ASSET_NAMES="$(printf '%s\n' "${assets[@]}")"
FEED="$(
  BV_UPDATE_PORT="$PORT" \
    BV_UPDATE_TAG="$TAG" \
    BV_UPDATE_PRERELEASE="$PRERELEASE" \
    BV_UPDATE_BODY="$BODY" \
    BV_UPDATE_PUBLISHED="$PUBLISHED" \
    BV_ASSET_NAMES="$BV_ASSET_NAMES" \
    python3 - <<'PY'
import json, os, urllib.parse

port = int(os.environ["BV_UPDATE_PORT"])
names = [n for n in os.environ.get("BV_ASSET_NAMES", "").split("\n") if n]
assets = []
for name in names:
    assets.append({
        "name": name,
        "browser_download_url": "http://127.0.0.1:%s/download/%s" % (
            port, urllib.parse.quote(name),
        ),
    })
print(json.dumps([{
    "tag_name": os.environ["BV_UPDATE_TAG"],
    "prerelease": os.environ["BV_UPDATE_PRERELEASE"] == "1",
    "body": os.environ["BV_UPDATE_BODY"],
    "published_at": os.environ["BV_UPDATE_PUBLISHED"],
    "assets": assets,
}], indent=2))
PY
)"

FEED_URL="http://127.0.0.1:${PORT}/repos/pmdroid/barkvisor/releases"

echo "BARKVISOR_UPDATE_URL=${FEED_URL}"
echo
echo "Point a Device at this feed (package tag must be newer than the installed Device):"
echo "  Linux: add the line above to /etc/barkvisor/barkvisor.env, then"
echo "         sudo systemctl restart barkvisor.service"
echo "  macOS: add BARKVISOR_UPDATE_URL under EnvironmentVariables in"
echo "         /Library/LaunchDaemons/dev.barkvisor.plist, then"
echo "         sudo launchctl kickstart -k system/dev.barkvisor"
echo "  Any process: export the line above before start."
echo
echo "Dev builds (version contains \"dev\" or 0.0.0): Settings → Updates → Test update URL."
echo
echo "$FEED"

if [[ "$DRY_RUN" -eq 1 ]]; then
  exit 0
fi

echo
echo "Listening on 127.0.0.1:${PORT} (loopback only). Ctrl-C to stop."

export BV_UPDATE_DIR="$DIR"
export BV_UPDATE_PORT="$PORT"
export BV_UPDATE_FEED="$FEED"
exec python3 - <<'PY'
import os
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = os.environ["BV_UPDATE_DIR"]
PORT = int(os.environ["BV_UPDATE_PORT"])
FEED = os.environ["BV_UPDATE_FEED"].encode("utf-8")
FEED_PATHS = {
    "/repos/pmdroid/barkvisor/releases",
    "/releases",
}


def safe_file(name):
    if not name or name in (".", "..") or "/" in name or "\\" in name:
        return None
    real_dir = os.path.realpath(DIR)
    real_file = os.path.realpath(os.path.join(DIR, name))
    if not real_file.startswith(real_dir + os.sep):
        return None
    if not os.path.isfile(real_file):
        return None
    return real_file


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        if path in FEED_PATHS:
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(FEED)))
            self.end_headers()
            self.wfile.write(FEED)
            return
        prefix = "/download/"
        if path.startswith(prefix):
            name = urllib.parse.unquote(path[len(prefix):])
            full = safe_file(name)
            if full is None:
                self.send_error(404, "Not found")
                return
            size = os.path.getsize(full)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with open(full, "rb") as fh:
                while True:
                    chunk = fh.read(64 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
            return
        self.send_error(404, "Not found")

    def log_message(self, fmt, *args):
        sys_stderr = __import__("sys").stderr
        sys_stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


class Server(ThreadingHTTPServer):
    allow_reuse_address = True


httpd = Server(("127.0.0.1", PORT), Handler)
try:
    httpd.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    httpd.server_close()
PY
