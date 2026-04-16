#!/bin/bash
set -euo pipefail

# =============================================================================
# BarkVisor Release Build Script
# =============================================================================
# Builds all dependencies from source, assembles the .app bundle, bundles
# dylibs, code signs, and creates a DMG.
#
# Usage:
#   ./scripts/build-release.sh                  # Full build
#   ./scripts/build-release.sh --skip-deps      # Skip dep builds (use cached)
#   ./scripts/build-release.sh --no-sign        # Skip code signing
#   ./scripts/build-release.sh --no-pkg         # Skip installer pkg creation
#   ./scripts/build-release.sh --require-notarize  # Fail if notarization credentials missing
#
# Checksum verification (optional, set via env):
#   QEMU_SHA256="abc123..." XZ_SHA256="def456..." ./scripts/build-release.sh
#
# Prerequisites (build host only):
#   brew install meson ninja pkg-config glib pixman dylibbundler \
#     gnutls jpeg-turbo libpng libssh libusb zstd lzo snappy \
#     autoconf automake libtool json-glib cdrtools
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source .env if present (values can still be overridden via env vars)
if [ -f "$PROJECT_DIR/.env" ]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
fi
APP_NAME="BarkVisor"
# Derive version from git tag (v1.2.3 → 1.2.3), fall back to env or default
if [ -z "${BARKVISOR_VERSION:-}" ]; then
    GIT_TAG="$(git -C "$PROJECT_DIR" describe --tags --exact-match 2>/dev/null || true)"
    if [[ "$GIT_TAG" =~ ^v([0-9]+\.[0-9]+\.[0-9]+.*)$ ]]; then
        VERSION="${BASH_REMATCH[1]}"
    else
        VERSION="0.0.0-dev"
    fi
else
    VERSION="$BARKVISOR_VERSION"
fi
NCPU="$(sysctl -n hw.ncpu)"

# Directories
BUILD_DIR="$PROJECT_DIR/build"
DEPS_DIR="$BUILD_DIR/deps"
DEPS_SRC="$DEPS_DIR/src"
DEPS_PREFIX="$DEPS_DIR/install"

# Staging directory mirrors the install layout under /usr/local
STAGE_DIR="$BUILD_DIR/stage"
STAGE_BIN="$STAGE_DIR/usr/local/bin"
STAGE_LIBEXEC="$STAGE_DIR/usr/local/libexec/barkvisor"
STAGE_LIB="$STAGE_DIR/usr/local/lib/barkvisor"
STAGE_SHARE="$STAGE_DIR/usr/local/share/barkvisor"
STAGE_QEMU="$STAGE_SHARE/qemu"
STAGE_FRONTEND="$STAGE_SHARE/frontend/dist"
STAGE_HELPER="$STAGE_DIR/Library/PrivilegedHelperTools"
STAGE_LAUNCHD="$STAGE_DIR/Library/LaunchDaemons"

# Legacy variables kept for dep build steps that reference them
BUNDLE_DIR="$BUILD_DIR/${APP_NAME}.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
HELPERS_DIR="$CONTENTS_DIR/Helpers"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
QEMU_RESOURCES="$RESOURCES_DIR/qemu"

# Dependency versions (pinned for reproducible builds)
QEMU_VERSION="${QEMU_VERSION:-10.2.2}"
XZ_VERSION="${XZ_VERSION:-5.8.2}"
LIBTPMS_VERSION="${LIBTPMS_VERSION:-v0.10.2}"
SWTPM_VERSION="${SWTPM_VERSION:-v0.10.1}"
SOCKET_VMNET_VERSION="${SOCKET_VMNET_VERSION:-v1.2.2}"
AAVMF_DEB_VERSION="${AAVMF_DEB_VERSION:-2025.11-3ubuntu7}"

# Options
SKIP_DEPS=false
NO_SIGN=false
NO_PKG=false
REQUIRE_NOTARIZE=false
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"    # e.g. "Developer ID Application: Your Name (TEAMID)"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"  # e.g. "Developer ID Installer: Your Name (TEAMID)"

for arg in "$@"; do
    case "$arg" in
        --skip-deps)          SKIP_DEPS=true ;;
        --no-sign)            NO_SIGN=true ;;
        --no-pkg)             NO_PKG=true ;;
        --require-notarize)   REQUIRE_NOTARIZE=true ;;
    esac
done

log() { echo "==> $1"; }
log_sub() { echo "    $1"; }

# Verify SHA256 checksum of a downloaded file
verify_checksum() {
    local file="$1"
    local expected="$2"
    local actual
    actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: Checksum mismatch for $file"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        rm -f "$file"
        exit 1
    fi
    log_sub "Checksum verified: $(basename "$file")"
}

# Known checksums for dependencies
QEMU_SHA256="${QEMU_SHA256:-}"  # Set via env to verify, or leave empty to skip
XZ_SHA256="${XZ_SHA256:-}"

# =============================================================================
# Step 0: Verify build prerequisites
# =============================================================================
log "Checking build prerequisites..."

MISSING_DEPS=()
for cmd in meson ninja pkg-config dylibbundler autoconf automake glibtoolize gawk mkisofs; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING_DEPS+=("$cmd")
    fi
done
if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "ERROR: Missing build tools: ${MISSING_DEPS[*]}"
    echo "Install via: brew install ${MISSING_DEPS[*]}"
    exit 1
fi

# Set up Python venv with distlib (needed by swtpm/libtpms build)
VENV_DIR="$DEPS_DIR/venv"
if [ ! -d "$VENV_DIR" ]; then
    log "Creating Python venv with distlib..."
    uv venv "$VENV_DIR"
    uv add distlib
fi
export PATH="$VENV_DIR/bin:$PATH"

mkdir -p "$DEPS_SRC" "$DEPS_PREFIX"/{bin,lib,share,include}

# =============================================================================
# Step 1: Build QEMU from source
# =============================================================================
QEMU_STAMP="$DEPS_PREFIX/.qemu-${QEMU_VERSION}-done"

if [ "$SKIP_DEPS" = false ] || [ ! -f "$QEMU_STAMP" ]; then
    log "Building QEMU ${QEMU_VERSION}..."

    QEMU_SRC="$DEPS_SRC/qemu-${QEMU_VERSION}"
    if [ ! -d "$QEMU_SRC" ]; then
        log_sub "Downloading QEMU source..."
        curl -fSL "https://download.qemu.org/qemu-${QEMU_VERSION}.tar.xz" \
            -o "$DEPS_SRC/qemu-${QEMU_VERSION}.tar.xz"
        if [ -n "$QEMU_SHA256" ]; then
            verify_checksum "$DEPS_SRC/qemu-${QEMU_VERSION}.tar.xz" "$QEMU_SHA256"
        fi
        tar xf "$DEPS_SRC/qemu-${QEMU_VERSION}.tar.xz" -C "$DEPS_SRC"
    fi

    QEMU_BUILD="$QEMU_SRC/build"
    rm -rf "$QEMU_BUILD"
    mkdir -p "$QEMU_BUILD"
    cd "$QEMU_BUILD"

    log_sub "Configuring QEMU (headless, HVF, VNC)..."
    HOMEBREW_PREFIX="$(brew --prefix)"

    # Collect include/lib/pkgconfig paths for all keg-only Homebrew deps
    BREW_PKGS=(snappy lzo gnutls jpeg-turbo libpng libssh libusb zstd)
    EXTRA_CFLAGS="-O2"
    EXTRA_LDFLAGS=""
    EXTRA_PKG_CONFIG="$HOMEBREW_PREFIX/lib/pkgconfig"
    for pkg in "${BREW_PKGS[@]}"; do
        pkg_prefix="$HOMEBREW_PREFIX/opt/$pkg"
        if [ -d "$pkg_prefix/include" ]; then
            EXTRA_CFLAGS="$EXTRA_CFLAGS -I$pkg_prefix/include"
        fi
        if [ -d "$pkg_prefix/lib" ]; then
            EXTRA_LDFLAGS="$EXTRA_LDFLAGS -L$pkg_prefix/lib"
        fi
        if [ -d "$pkg_prefix/lib/pkgconfig" ]; then
            EXTRA_PKG_CONFIG="$EXTRA_PKG_CONFIG:$pkg_prefix/lib/pkgconfig"
        fi
    done

    PKG_CONFIG_PATH="$EXTRA_PKG_CONFIG:${PKG_CONFIG_PATH:-}" \
    ../configure \
        --prefix="$DEPS_PREFIX" \
        --target-list=aarch64-softmmu \
        --enable-hvf --enable-slirp --enable-vnc \
        --enable-vnc-jpeg --enable-png \
        --enable-zstd --enable-lzo --enable-snappy \
        --enable-libssh --enable-libusb --enable-tools --enable-strip \
        --disable-sdl --disable-gtk --disable-cocoa --disable-opengl \
        --disable-spice --disable-xen --disable-brlapi --disable-curl \
        --disable-docs --disable-guest-agent --disable-debug-info \
        --extra-cflags="$EXTRA_CFLAGS" \
        --extra-ldflags="$EXTRA_LDFLAGS"

    log_sub "Compiling QEMU (${NCPU} cores)..."
    make -j"$NCPU"
    make install

    touch "$QEMU_STAMP"
    cd "$PROJECT_DIR"
else
    log "QEMU ${QEMU_VERSION}: using cached build"
fi

# =============================================================================
# Step 2: Build xz-utils from source
# =============================================================================
XZ_STAMP="$DEPS_PREFIX/.xz-${XZ_VERSION}-done"

if [ "$SKIP_DEPS" = false ] || [ ! -f "$XZ_STAMP" ]; then
    log "Building xz-utils ${XZ_VERSION}..."

    XZ_SRC="$DEPS_SRC/xz-${XZ_VERSION}"
    if [ ! -d "$XZ_SRC" ]; then
        log_sub "Downloading xz source..."
        curl -fSL "https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.gz" \
            -o "$DEPS_SRC/xz-${XZ_VERSION}.tar.gz"
        if [ -n "$XZ_SHA256" ]; then
            verify_checksum "$DEPS_SRC/xz-${XZ_VERSION}.tar.gz" "$XZ_SHA256"
        fi
        tar xf "$DEPS_SRC/xz-${XZ_VERSION}.tar.gz" -C "$DEPS_SRC"
    fi

    cd "$XZ_SRC"
    log_sub "Configuring xz..."
    ./configure --prefix="$DEPS_PREFIX" --disable-shared --enable-static \
        --disable-doc --disable-nls --disable-scripts
    log_sub "Compiling xz..."
    make -j"$NCPU"
    make install

    touch "$XZ_STAMP"
    cd "$PROJECT_DIR"
else
    log "xz-utils ${XZ_VERSION}: using cached build"
fi

# =============================================================================
# Step 3: Build libtpms + swtpm
# =============================================================================
SWTPM_STAMP="$DEPS_PREFIX/.swtpm-${LIBTPMS_VERSION}-${SWTPM_VERSION}-done"

if [ "$SKIP_DEPS" = false ] || [ ! -f "$SWTPM_STAMP" ]; then
    log "Building libtpms ${LIBTPMS_VERSION}..."

    # Ensure autoreconf can find Homebrew libtool m4 macros
    HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-$(brew --prefix)}"
    export ACLOCAL_PATH="$HOMEBREW_PREFIX/share/aclocal:${ACLOCAL_PATH:-}"

    # OpenSSL is keg-only on Homebrew — export paths for libtpms/swtpm
    OPENSSL_PREFIX="$HOMEBREW_PREFIX/opt/openssl@3"
    export PKG_CONFIG_PATH="$OPENSSL_PREFIX/lib/pkgconfig:$DEPS_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LDFLAGS="-L$OPENSSL_PREFIX/lib ${LDFLAGS:-}"
    export CPPFLAGS="-I$OPENSSL_PREFIX/include ${CPPFLAGS:-}"

    LIBTPMS_SRC="$DEPS_SRC/libtpms"
    if [ ! -d "$LIBTPMS_SRC" ]; then
        git clone --branch "$LIBTPMS_VERSION" --depth 1 https://github.com/stefanberger/libtpms.git "$LIBTPMS_SRC"
    fi
    cd "$LIBTPMS_SRC"
    # Clean stale autotools artifacts and regenerate
    git clean -fdx
    autoreconf --install --force
    ./configure --with-openssl --with-tpm2 --prefix="$DEPS_PREFIX"
    make -j"$NCPU"
    make install

    log "Building swtpm ${SWTPM_VERSION}..."
    SWTPM_SRC="$DEPS_SRC/swtpm"
    if [ ! -d "$SWTPM_SRC" ]; then
        git clone --branch "$SWTPM_VERSION" --depth 1 https://github.com/stefanberger/swtpm.git "$SWTPM_SRC"
    fi
    cd "$SWTPM_SRC"
    git clean -fdx
    # Patch SOCK_CLOEXEC which doesn't exist on macOS
    sed -i '' 's/SOCK_CLOEXEC/0/g' src/swtpm/sd-notify.c || true
    autoreconf --install --force
    ./configure --prefix="$DEPS_PREFIX" \
        CPPFLAGS="-I$DEPS_PREFIX/include $CPPFLAGS" \
        LDFLAGS="-L$DEPS_PREFIX/lib $LDFLAGS"
    make -j"$NCPU"
    make install

    touch "$SWTPM_STAMP"
    cd "$PROJECT_DIR"
else
    log "swtpm ${SWTPM_VERSION}: using cached build"
fi

# =============================================================================
# Step 4: Build socket_vmnet
# =============================================================================
VMNET_STAMP="$DEPS_PREFIX/.socket_vmnet-${SOCKET_VMNET_VERSION}-done"

if [ "$SKIP_DEPS" = false ] || [ ! -f "$VMNET_STAMP" ]; then
    log "Building socket_vmnet ${SOCKET_VMNET_VERSION}..."

    VMNET_SRC="$DEPS_SRC/socket_vmnet"
    if [ ! -d "$VMNET_SRC" ]; then
        git clone --branch "$SOCKET_VMNET_VERSION" --depth 1 https://github.com/lima-vm/socket_vmnet.git "$VMNET_SRC"
    fi
    cd "$VMNET_SRC"
    make clean || true
    make PREFIX="$DEPS_PREFIX"
    cp socket_vmnet socket_vmnet_client "$DEPS_PREFIX/bin/"

    touch "$VMNET_STAMP"
    cd "$PROJECT_DIR"
else
    log "socket_vmnet ${SOCKET_VMNET_VERSION}: using cached build"
fi

# =============================================================================
# Step 5: Download AAVMF secure boot firmware
# =============================================================================
AAVMF_FW="$DEPS_PREFIX/share/qemu/AAVMF_CODE.secboot.fd"

if [ ! -f "$AAVMF_FW" ]; then
    log "Downloading AAVMF secure boot firmware from Ubuntu..."
    AAVMF_TMP="$(mktemp -d)"
    trap "rm -rf $AAVMF_TMP" EXIT

    DEB_URL="https://mirrors.edge.kernel.org/ubuntu/pool/main/e/edk2/qemu-efi-aarch64_${AAVMF_DEB_VERSION}_all.deb"
    curl -fsSL -o "$AAVMF_TMP/qemu-efi.deb" "$DEB_URL"
    cd "$AAVMF_TMP"
    ar x qemu-efi.deb
    tar xf data.tar.* --include="*/AAVMF_CODE.secboot.fd"

    EXTRACTED=$(find . -name "AAVMF_CODE.secboot.fd" -type f | head -1)
    if [ -z "$EXTRACTED" ]; then
        echo "ERROR: AAVMF_CODE.secboot.fd not found in deb"
        exit 1
    fi
    mkdir -p "$DEPS_PREFIX/share/qemu"
    cp "$EXTRACTED" "$AAVMF_FW"
    cd "$PROJECT_DIR"

    trap - EXIT
    rm -rf "$AAVMF_TMP"
else
    log "AAVMF firmware: already present"
fi

# =============================================================================
# Step 6: Build frontend
# =============================================================================
log "Building frontend..."
cd "$PROJECT_DIR/frontend"
bun install
VITE_APP_VERSION="$VERSION" bun run build
cd "$PROJECT_DIR"

# =============================================================================
# Step 7: Build Swift app (release)
# =============================================================================
log "Building Swift app (release)..."

# Inject the real Apple Team ID into the helper protocol for release builds.
HELPER_PROTO="$PROJECT_DIR/Sources/BarkVisorHelperProtocol/HelperProtocol.swift"
if [ -z "${APPLE_TEAM_ID:-}" ]; then
    echo "ERROR: APPLE_TEAM_ID must be set for release builds (XPC code-signing verification)"
    exit 1
fi
log_sub "Injecting APPLE_TEAM_ID into HelperProtocol.swift"
cp "$HELPER_PROTO" "$HELPER_PROTO.bak"
# Replace the DEVELOPMENT placeholder with the real team ID
sed -i '' \
    -e 's/kHelperTeamID = "DEVELOPMENT"/kHelperTeamID = "'"$APPLE_TEAM_ID"'"/' \
    "$HELPER_PROTO"

# Inject the release version into Config.swift
CONFIG_SWIFT="$PROJECT_DIR/Sources/BarkVisorCore/Config.swift"
log_sub "Injecting VERSION ($VERSION) into Config.swift"
cp "$CONFIG_SWIFT" "$CONFIG_SWIFT.bak"
sed -i '' \
    -e 's/version = "1.0.0-alpha.2"/version = "'"$VERSION"'"/' \
    "$CONFIG_SWIFT"

swift build -c release --package-path "$PROJECT_DIR"

# Restore source files so the working tree stays clean
mv "$HELPER_PROTO.bak" "$HELPER_PROTO"
mv "$CONFIG_SWIFT.bak" "$CONFIG_SWIFT"
EXECUTABLE="$PROJECT_DIR/.build/release/BarkVisorApp"
HELPER_EXECUTABLE="$PROJECT_DIR/.build/release/BarkVisorHelper"

# =============================================================================
# Step 8: Assemble daemon install layout
# =============================================================================
log "Assembling daemon install layout..."

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_BIN" "$STAGE_LIBEXEC" "$STAGE_LIB" "$STAGE_QEMU" "$STAGE_FRONTEND" \
         "$STAGE_HELPER" "$STAGE_LAUNCHD"

# Main server daemon binary
cp "$EXECUTABLE" "$STAGE_BIN/barkvisor"

# Privileged XPC helper
log_sub "Copying BarkVisorHelper..."
cp "$HELPER_EXECUTABLE" "$STAGE_HELPER/dev.barkvisor.helper"

# LaunchDaemon plists
cp "$PROJECT_DIR/Resources/dev.barkvisor.plist" "$STAGE_LAUNCHD/dev.barkvisor.plist"

# Generate helper plist with absolute path (installed location)
cat > "$STAGE_LAUNCHD/dev.barkvisor.helper.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dev.barkvisor.helper</string>
    <key>Program</key>
    <string>/Library/PrivilegedHelperTools/dev.barkvisor.helper</string>
    <key>MachServices</key>
    <dict>
        <key>dev.barkvisor.helper</key>
        <true/>
    </dict>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST

# Helper binaries → /usr/local/libexec/barkvisor/
log_sub "Copying helper binaries..."
for bin in qemu-system-aarch64 qemu-img swtpm \
           socket_vmnet socket_vmnet_client xz; do
    if [ -f "$DEPS_PREFIX/bin/$bin" ]; then
        cp "$DEPS_PREFIX/bin/$bin" "$STAGE_LIBEXEC/$bin"
        log_sub "  $bin (from deps)"
    else
        echo "ERROR: $bin not found in $DEPS_PREFIX/bin — build may have failed"
        exit 1
    fi
done

# mkisofs from cdrtools (Homebrew prerequisite)
MKISOFS_PATH="$(command -v mkisofs 2>/dev/null || true)"
if [ -n "$MKISOFS_PATH" ]; then
    cp "$MKISOFS_PATH" "$STAGE_LIBEXEC/mkisofs"
    chmod u+w "$STAGE_LIBEXEC/mkisofs"
    MKISOFS_VER="$(mkisofs --version 2>&1 | head -1 || true)"
    log_sub "  mkisofs ($MKISOFS_VER)"
else
    echo "ERROR: mkisofs not found — install via: brew install cdrtools"
    exit 1
fi

# QEMU firmware and data files → /usr/local/share/barkvisor/qemu/
log_sub "Copying QEMU firmware and data..."
QEMU_SHARE="$DEPS_PREFIX/share/qemu"

FIRMWARE_FILES=(
    edk2-aarch64-code.fd
    AAVMF_CODE.secboot.fd
    vgabios-ramfb.bin
    vgabios-virtio.bin
    efi-virtio.rom
)

for fw in "${FIRMWARE_FILES[@]}"; do
    if [ -f "$QEMU_SHARE/$fw" ]; then
        cp "$QEMU_SHARE/$fw" "$STAGE_QEMU/$fw"
    else
        echo "WARNING: firmware $fw not found — skipping"
    fi
done

# Keymaps directory
if [ -d "$QEMU_SHARE/keymaps" ]; then
    cp -r "$QEMU_SHARE/keymaps" "$STAGE_QEMU/keymaps"
fi

# Frontend dist → /usr/local/share/barkvisor/frontend/dist/
cp -r "$PROJECT_DIR/frontend/dist/"* "$STAGE_FRONTEND/"

# Server resources
cp "$PROJECT_DIR/Sources/BarkVisor/Server/Resources/templates.json" "$STAGE_SHARE/templates.json"

# =============================================================================
# Step 9: Bundle shared libraries with dylibbundler
# =============================================================================
log "Bundling shared libraries..."

# Strip extended attributes (resource forks, etc.) that break code signing
log_sub "Stripping extended attributes..."
xattr -cr "$STAGE_DIR"

DYLIB_ARGS=()
for bin in "$STAGE_LIBEXEC"/*; do
    if [ -x "$bin" ] && file "$bin" | grep -q "Mach-O"; then
        DYLIB_ARGS+=(-x "$bin")
    fi
done
# Also process the main daemon binary and XPC helper
DYLIB_ARGS+=(-x "$STAGE_BIN/barkvisor")
DYLIB_ARGS+=(-x "$STAGE_HELPER/dev.barkvisor.helper")

# dylibbundler rewrites load commands to use the rpath prefix
# At runtime, binaries will find dylibs via /usr/local/lib/barkvisor/
dylibbundler -od -b \
    "${DYLIB_ARGS[@]}" \
    -d "$STAGE_LIB/" \
    -p @rpath/ \
    -s "$DEPS_PREFIX/lib"

# Strip extended attributes again after dylibbundler copies in new dylibs
xattr -cr "$STAGE_DIR"

# Set rpaths on all Mach-O binaries to find dylibs at /usr/local/lib/barkvisor/
log_sub "Setting rpaths..."
for bin in "$STAGE_BIN/barkvisor" "$STAGE_HELPER/dev.barkvisor.helper" "$STAGE_LIBEXEC"/*; do
    [ -x "$bin" ] && file "$bin" | grep -q "Mach-O" || continue
    # Remove all existing rpaths
    otool -l "$bin" 2>/dev/null | awk '/LC_RPATH/{found=1} found && /path /{print $2; found=0}' | while IFS= read -r rp; do
        [ -z "$rp" ] && continue
        while install_name_tool -delete_rpath "$rp" "$bin" 2>/dev/null; do :; done
    done
    # Add the installed library path
    install_name_tool -add_rpath /usr/local/lib/barkvisor "$bin" 2>/dev/null || true
done

# =============================================================================
# Step 10: Create entitlements and code sign
# =============================================================================

# Server daemon entitlements (network only — hypervisor is on QEMU binary)
cat > "$BUILD_DIR/server.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
ENT

# QEMU/helper entitlements (hypervisor + network)
cat > "$BUILD_DIR/helper.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.hypervisor</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
ENT

sign_binary() {
    local bin="$1"
    local entitlements="$2"
    local identifier="${3:-}"
    if [ -n "$SIGNING_IDENTITY" ]; then
        codesign --force --options runtime \
            --entitlements "$entitlements" \
            ${identifier:+--identifier "$identifier"} \
            --sign "$SIGNING_IDENTITY" "$bin"
    else
        codesign --force \
            --entitlements "$entitlements" \
            ${identifier:+--identifier "$identifier"} \
            --sign - "$bin"
    fi
}

if [ "$NO_SIGN" = false ]; then
    if [ -n "$SIGNING_IDENTITY" ]; then
        log "Code signing with: $SIGNING_IDENTITY"
    else
        log "Ad-hoc code signing (no SIGNING_IDENTITY)..."
    fi

    # 1. Sign shared libraries
    log_sub "Signing shared libraries..."
    for dylib in "$STAGE_LIB"/*.dylib; do
        [ -f "$dylib" ] || continue
        if [ -n "$SIGNING_IDENTITY" ]; then
            codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$dylib"
        else
            codesign --force --sign - "$dylib"
        fi
    done

    # 2. Sign helper binaries (QEMU, swtpm, etc.) with hypervisor entitlements
    log_sub "Signing libexec binaries..."
    for bin in "$STAGE_LIBEXEC"/*; do
        [ -x "$bin" ] && file "$bin" | grep -q "Mach-O" || continue
        sign_binary "$bin" "$BUILD_DIR/helper.entitlements"
    done

    # 3. Sign XPC helper
    log_sub "Signing BarkVisorHelper..."
    sign_binary "$STAGE_HELPER/dev.barkvisor.helper" "$BUILD_DIR/helper.entitlements"

    # 4. Sign main server daemon
    log_sub "Signing barkvisor daemon..."
    sign_binary "$STAGE_BIN/barkvisor" "$BUILD_DIR/server.entitlements" "dev.barkvisor.app"

    log_sub "Verifying signatures..."
    codesign --verify --strict "$STAGE_BIN/barkvisor"
    codesign --verify --strict "$STAGE_HELPER/dev.barkvisor.helper"
else
    log "Code signing SKIPPED (--no-sign)"
fi

# =============================================================================
# Step 11: Create standalone archive
# =============================================================================
if [ "$NO_SIGN" = false ] && [ -n "$SIGNING_IDENTITY" ]; then
    log "Creating standalone archive..."

    STANDALONE_TAR="$BUILD_DIR/BarkVisor-${VERSION}-standalone.tar.gz"

    # The staging directory already has the right layout — archive it
    tar -czf "$STANDALONE_TAR" -C "$STAGE_DIR" .

    STANDALONE_SIZE=$(du -sh "$STANDALONE_TAR" | cut -f1)
    log "Standalone archive: $STANDALONE_TAR ($STANDALONE_SIZE)"
else
    log "Standalone archive SKIPPED (no signing identity)"
fi

# =============================================================================
# Step 12: Create installer .pkg
# =============================================================================
if [ "$NO_PKG" = false ]; then
    log "Creating installer package..."

    PKG_SCRIPTS="$BUILD_DIR/pkg-scripts"
    rm -rf "$PKG_SCRIPTS"

    # Use the postinstall script from the repo
    mkdir -p "$PKG_SCRIPTS"
    cp "$PROJECT_DIR/scripts/postinstall.sh" "$PKG_SCRIPTS/postinstall"
    chmod +x "$PKG_SCRIPTS/postinstall"

    # Build the component package directly from staging directory
    COMPONENT_PKG="$BUILD_DIR/BarkVisor-component.pkg"
    pkgbuild \
        --root "$STAGE_DIR" \
        --scripts "$PKG_SCRIPTS" \
        --identifier "dev.barkvisor" \
        --version "$VERSION" \
        --install-location "/" \
        "$COMPONENT_PKG"

    # Build the distribution (product) package
    PKG_PATH="$BUILD_DIR/BarkVisor-${VERSION}.pkg"

    cat > "$BUILD_DIR/distribution.xml" <<DIST
<?xml version="1.0" encoding="UTF-8"?>
<installer-gui-script minSpecVersion="2">
    <title>BarkVisor ${VERSION}</title>
    <welcome file="welcome.html" />
    <options customize="never" require-scripts="false" hostArchitectures="arm64" />
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true" />
    <choices-outline>
        <line choice="default">
            <line choice="dev.barkvisor"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="dev.barkvisor" visible="false">
        <pkg-ref id="dev.barkvisor"/>
    </choice>
    <pkg-ref id="dev.barkvisor" version="${VERSION}" onConclusion="none">BarkVisor-component.pkg</pkg-ref>
</installer-gui-script>
DIST

    mkdir -p "$BUILD_DIR/pkg-resources"
    cat > "$BUILD_DIR/pkg-resources/welcome.html" <<HTML
<html>
<body>
<h2>BarkVisor ${VERSION}</h2>
<p>This installer will:</p>
<ul>
<li>Install the BarkVisor server daemon</li>
<li>Install QEMU and networking helpers</li>
<li>Create the <code>_barkvisor</code> system user</li>
<li>Start the server as a LaunchDaemon</li>
</ul>
<p>After installation, open <strong>http://localhost:7777</strong> to complete setup.</p>
<p>Can also be installed headlessly via SSH:</p>
<pre>sudo installer -pkg BarkVisor-${VERSION}.pkg -target /</pre>
</body>
</html>
HTML

    productbuild \
        --distribution "$BUILD_DIR/distribution.xml" \
        --resources "$BUILD_DIR/pkg-resources" \
        --package-path "$BUILD_DIR" \
        "$PKG_PATH"

    rm -f "$COMPONENT_PKG"

    # Sign the pkg with the installer identity
    if [ -n "$INSTALLER_IDENTITY" ]; then
        log_sub "Signing pkg with: $INSTALLER_IDENTITY"
        productsign --sign "$INSTALLER_IDENTITY" "$PKG_PATH" "$PKG_PATH.signed"
        mv "$PKG_PATH.signed" "$PKG_PATH"
    elif [ -n "$SIGNING_IDENTITY" ]; then
        echo "ERROR: INSTALLER_IDENTITY not set. A 'Developer ID Installer' certificate is required to sign the .pkg."
        echo "  Create one at https://developer.apple.com/account/resources/certificates"
        echo "  Then set: INSTALLER_IDENTITY=\"Developer ID Installer: Your Name (TEAMID)\""
        exit 1
    fi

    # Notarize the pkg
    if [ "$NO_SIGN" = false ] && [ -n "$SIGNING_IDENTITY" ] && [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
        log_sub "Notarizing pkg..."
        xcrun notarytool submit "$PKG_PATH" \
            --apple-id "$APPLE_ID" \
            --team-id "$APPLE_TEAM_ID" \
            --keychain-profile "barkvisor-notarize" \
            --wait

        log_sub "Stapling notarization ticket..."
        xcrun stapler staple "$PKG_PATH"
    fi

    PKG_SIZE=$(du -sh "$PKG_PATH" | cut -f1)
    log "Installer pkg created: $PKG_PATH ($PKG_SIZE)"
fi

shasum -a 256 build/BarkVisor-${VERSION}.pkg > build/BarkVisor-${VERSION}.pkg.sha256

# =============================================================================
# Summary
# =============================================================================
echo ""
log "Build complete!"
log_sub "Version:    ${VERSION}"
STAGE_SIZE=$(du -sh "$STAGE_DIR" | cut -f1)
log_sub "Stage dir:  $STAGE_DIR ($STAGE_SIZE)"
log_sub "Binaries:   $(ls "$STAGE_LIBEXEC" | tr '\n' ' ')"
log_sub "Libraries:  $(ls "$STAGE_LIB" 2>/dev/null | wc -l | tr -d ' ') dylibs"
log_sub "Firmware:   $(ls "$STAGE_QEMU" 2>/dev/null | wc -l | tr -d ' ') files"
if [ -f "$BUILD_DIR/BarkVisor-${VERSION}-standalone.tar.gz" ]; then
    log_sub "Standalone: $BUILD_DIR/BarkVisor-${VERSION}-standalone.tar.gz"
fi
if [ -f "$BUILD_DIR/BarkVisor-${VERSION}.pkg" ]; then
    log_sub "Installer:  $BUILD_DIR/BarkVisor-${VERSION}.pkg"
fi
echo ""
log "Install layout:"
log_sub "/usr/local/bin/barkvisor                          (server daemon)"
log_sub "/usr/local/libexec/barkvisor/                     (QEMU, swtpm, etc.)"
log_sub "/usr/local/lib/barkvisor/                         (shared libraries)"
log_sub "/usr/local/share/barkvisor/                       (frontend, firmware)"
log_sub "/Library/PrivilegedHelperTools/dev.barkvisor.helper"
log_sub "/Library/LaunchDaemons/dev.barkvisor.plist"
log_sub "/Library/LaunchDaemons/dev.barkvisor.helper.plist"
echo ""
log "Dependency versions:"
log_sub "QEMU:          ${QEMU_VERSION}"
log_sub "xz-utils:      ${XZ_VERSION}"
log_sub "libtpms:       ${LIBTPMS_VERSION}"
log_sub "swtpm:         ${SWTPM_VERSION}"
log_sub "socket_vmnet:  ${SOCKET_VMNET_VERSION}"
log_sub "AAVMF:         ${AAVMF_DEB_VERSION}"
log_sub "mkisofs:       $(mkisofs --version 2>&1 | head -1 || echo 'unknown')"
