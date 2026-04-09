#!/bin/bash
set -euo pipefail

# =============================================================================
# Local Update Test Server
# =============================================================================
# Spins up a local HTTP server that mimics the GitHub Releases API.
#
# Usage:
#   ./scripts/test-update.sh                          # Dummy unsigned PKG (v99.0.0)
#   ./scripts/test-update.sh build/BarkVisor-1.2.0.pkg  # Use a real PKG from build-release.sh
#   ./scripts/test-update.sh /path/to/any.pkg 2.0.0   # Custom PKG + explicit version
# =============================================================================

PORT=9999
TEST_DIR=$(mktemp -d)
PKG_FILE="${1:-}"
VERSION="${2:-}"

if [ -n "$PKG_FILE" ]; then
    # --- Real PKG mode ---
    if [ ! -f "$PKG_FILE" ]; then
        echo "ERROR: PKG file not found: $PKG_FILE"
        exit 1
    fi

    PKG_FILE="$(cd "$(dirname "$PKG_FILE")" && pwd)/$(basename "$PKG_FILE")"

    # Extract version from filename (BarkVisor-1.2.3.pkg → 1.2.3) unless explicitly provided
    if [ -z "$VERSION" ]; then
        BASENAME="$(basename "$PKG_FILE")"
        VERSION="$(echo "$BASENAME" | sed -n 's/^BarkVisor-\(.*\)\.pkg$/\1/p')"
        if [ -z "$VERSION" ]; then
            echo "ERROR: Could not extract version from filename '$BASENAME'."
            echo "       Provide it explicitly: ./scripts/test-update.sh $PKG_FILE 1.2.3"
            exit 1
        fi
    fi

    PKG_NAME="BarkVisor-${VERSION}.pkg"
    cp "$PKG_FILE" "$TEST_DIR/$PKG_NAME"

    # Use existing .sha256 sidecar if present, otherwise generate one
    SIDECAR="${PKG_FILE}.sha256"
    if [ -f "$SIDECAR" ]; then
        cp "$SIDECAR" "$TEST_DIR/${PKG_NAME}.sha256"
    else
        shasum -a 256 "$TEST_DIR/$PKG_NAME" > "$TEST_DIR/${PKG_NAME}.sha256"
    fi

    PKG_LABEL="$(du -h "$TEST_DIR/$PKG_NAME" | cut -f1) (real build)"
else
    # --- Dummy PKG mode ---
    VERSION="99.0.0"
    PKG_NAME="BarkVisor-${VERSION}.pkg"

    pkgbuild --nopayload --identifier "dev.barkvisor.test" --version "$VERSION" \
        "$TEST_DIR/$PKG_NAME"
    shasum -a 256 "$TEST_DIR/$PKG_NAME" > "$TEST_DIR/${PKG_NAME}.sha256"

    PKG_LABEL="$(du -h "$TEST_DIR/$PKG_NAME" | cut -f1) (unsigned dummy)"
fi

# Create fake GitHub Releases API response
cat > "$TEST_DIR/releases.json" <<EOF
[{
  "tag_name": "v${VERSION}",
  "prerelease": false,
  "body": "Test release for local update testing.\n\n- Fixed a bug\n- Added a feature",
  "published_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "assets": [
    {
      "name": "${PKG_NAME}",
      "browser_download_url": "http://localhost:${PORT}/${PKG_NAME}"
    },
    {
      "name": "${PKG_NAME}.sha256",
      "browser_download_url": "http://localhost:${PORT}/${PKG_NAME}.sha256"
    }
  ]
}]
EOF

echo "============================================"
echo "  Update Test Server"
echo "============================================"
echo "  URL:     http://localhost:${PORT}/releases.json"
echo "  Version: ${VERSION}"
echo "  PKG:     ${PKG_LABEL}"
echo ""
echo "  Run BarkVisor with:"
echo "    BARKVISOR_UPDATE_URL=http://localhost:${PORT}/releases.json swift run BarkVisorApp"
echo ""
echo "  Press Ctrl+C to stop."
echo "============================================"

cd "$TEST_DIR"
python3 -m http.server "$PORT"
