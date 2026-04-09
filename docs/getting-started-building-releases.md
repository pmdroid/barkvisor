# Building Release Packages

The release build process is driven by `scripts/build-release.sh`. This script compiles all native dependencies from source, builds the Swift application in release mode, assembles the daemon install layout with all helper binaries and firmware, bundles dynamic libraries, code signs everything with the appropriate entitlements, and creates a distributable `.pkg` installer and standalone archive. Optionally, it notarizes the DMG with Apple.

## Prerequisites

### Homebrew packages

Install the required build tools and libraries:

```sh
brew install meson ninja pkg-config glib pixman dylibbundler \
  gnutls jpeg-turbo libpng libssh libusb zstd lzo snappy \
  autoconf automake libtool json-glib
```

The script also checks for `gawk` and `glibtoolize` at runtime and will error with an install suggestion if any are missing.

### Python environment

A Python virtual environment is created automatically using `uv`. The `distlib` package is installed into it (required by the libtpms/swtpm build). You must have `uv` available on your PATH.

### Frontend toolchain

The frontend is built with `bun`. Ensure `bun` is installed before running the script.

### Required environment variable

- `APPLE_TEAM_ID` -- Your Apple Developer Team ID. This is injected into `Sources/BarkVisorHelperProtocol/HelperProtocol.swift` at build time so the XPC privileged helper can verify the code signature of the main app. The script will abort if this is not set.

## Build steps

The script performs the following steps in order:

### Step 0: Verify prerequisites

Checks that all required CLI tools are present (`meson`, `ninja`, `pkg-config`, `dylibbundler`, `autoconf`, `automake`, `glibtoolize`, `gawk`). Creates a Python venv with `distlib` if one does not already exist.

### Step 1: Build QEMU from source

Downloads and compiles QEMU (default version 10.2.2) configured for:

- Target: `aarch64-softmmu` only
- HVF (Hypervisor.framework) acceleration
- VNC with JPEG and PNG support
- Compression: zstd, lzo, snappy
- libssh, libusb, and QEMU tools enabled
- GUI backends disabled (no SDL, GTK, Cocoa, OpenGL, SPICE)
- Docs and guest agent disabled

The build uses all available CPU cores. Homebrew keg-only package paths are automatically collected and passed to the configure step.

### Step 2: Build xz-utils (static)

Downloads and compiles xz-utils (default version 5.8.2) as a static library. This provides the `xz` binary used for decompressing downloaded images.

### Step 3: Build libtpms and swtpm

Clones and builds libtpms (with OpenSSL and TPM2 support) and swtpm from their upstream GitHub repositories. A macOS-specific patch is applied to swtpm to replace `SOCK_CLOEXEC` (which does not exist on macOS) with `0`.

### Step 4: Build socket_vmnet

Clones and builds `socket_vmnet` from the lima-vm project. This provides bridged networking for VMs via the macOS vmnet framework. The built `socket_vmnet` and `socket_vmnet_client` binaries are copied into the deps prefix.

### Step 5: Download AAVMF firmware

Downloads the AAVMF secure boot firmware (`AAVMF_CODE.secboot.fd`) from an Ubuntu `.deb` package. The deb is extracted in a temporary directory and the firmware file is placed in the QEMU share directory.

### Step 6: Build frontend

Runs `bun install` and `bun run build` in the `frontend/` directory to produce the static web UI assets.

### Step 7: Build Swift app (release)

Injects the real `APPLE_TEAM_ID` into `HelperProtocol.swift` (replacing the `DEVELOPMENT` placeholder), then runs `swift build -c release`. The source file is restored to its original state afterward so the working tree stays clean.

This produces two executables:

- `.build/release/BarkVisorApp` -- the main application
- `.build/release/BarkVisorHelper` -- the privileged XPC helper daemon

### Step 8: Assemble daemon install layout

Creates the staged install layout under `build/stage/`:

```
usr/local/
  bin/
    barkvisor                   (main server daemon)
  libexec/barkvisor/
    qemu-system-aarch64
    qemu-img
    swtpm
    socket_vmnet
    socket_vmnet_client
    xz
    mkisofs
  lib/barkvisor/                (bundled dylibs, populated in step 9)
  share/barkvisor/
    templates.json
    frontend/dist/              (web UI)
    qemu/
      edk2-aarch64-code.fd
      AAVMF_CODE.secboot.fd
      vgabios-ramfb.bin
      vgabios-virtio.bin
      efi-virtio.rom
      keymaps/
Library/
  LaunchDaemons/
    dev.barkvisor.plist
    dev.barkvisor.helper.plist
  PrivilegedHelperTools/
    dev.barkvisor.helper        (XPC helper)
```

### Step 9: Bundle dylibs with dylibbundler

Runs `dylibbundler` against all Mach-O binaries in the staged layout (main executable, helper, and all helper binaries). This copies required dynamic libraries into `lib/barkvisor/` and rewrites load paths. Extended attributes are stripped before and after this step, and duplicate `LC_RPATH` entries are deduplicated.

### Step 10: Code sign with entitlements

If `SIGNING_IDENTITY` is set, performs a full Developer ID code signing pass. If not set and `--no-sign` is not passed, ad-hoc signing is performed instead (sufficient for local use but not for distribution).

The entitlements applied to both the main app and helper binaries are:

- `com.apple.security.hypervisor` -- required for QEMU to use HVF
- `com.apple.security.network.server` -- required for the Vapor HTTP server
- `com.apple.security.network.client` -- required for outbound connections (image downloads, repository sync)

Signing order: shared libraries in `lib/barkvisor/` first, then helper binaries in `libexec/barkvisor/`, then the XPC helper, then the main executable.

### Step 11: Create standalone archive

Creates a compressed tarball at `build/BarkVisor-VERSION-standalone.tar.gz` containing the staged install layout for manual extraction.

### Step 12: Create installer .pkg

Builds a macOS installer package at `build/BarkVisor-VERSION.pkg`. The `.pkg` installs files to their system locations and can be signed with an `INSTALLER_IDENTITY` if provided. If `SIGNING_IDENTITY`, `APPLE_ID`, and `APPLE_TEAM_ID` are all set, the package is submitted for notarization using `xcrun notarytool` with the `barkvisor-notarize` keychain profile, and the notarization ticket is stapled. If credentials are missing and `--require-notarize` is passed, the script fails.

## CLI flags

| Flag                  | Effect                                                  |
|-----------------------|---------------------------------------------------------|
| `--skip-deps`        | Skip dependency builds; use previously cached artifacts |
| `--no-sign`          | Skip all code signing                                   |
| `--no-pkg`           | Skip installer .pkg creation                             |
| `--require-notarize` | Fail if notarization credentials are missing            |

## Environment variables

| Variable             | Required | Default       | Description                                          |
|----------------------|----------|---------------|------------------------------------------------------|
| `APPLE_TEAM_ID`     | Yes      | --            | Apple Developer Team ID for XPC verification         |
| `SIGNING_IDENTITY`  | No       | (empty)       | Developer ID signing identity (e.g. `"Developer ID Application: Name (TEAMID)"`) |
| `APPLE_ID`          | No       | (empty)       | Apple ID email for notarization                      |
| `BARKVISOR_VERSION` | No       | `1.0.0`       | Version string embedded in Info.plist and DMG name   |
| `QEMU_VERSION`      | No       | `10.2.2`      | QEMU source version to download and build            |
| `XZ_VERSION`        | No       | `5.8.2`       | xz-utils source version to download and build        |
| `QEMU_SHA256`       | No       | (empty)       | Expected SHA-256 of the QEMU source tarball          |
| `XZ_SHA256`         | No       | (empty)       | Expected SHA-256 of the xz source tarball            |

Variables can also be placed in a `.env` file at the project root. The script sources it if present, but explicit environment variables take precedence.

## Output

After a successful build, the following artifacts are produced:

- `build/stage/` -- the staged install layout
- `build/BarkVisor-VERSION-standalone.tar.gz` -- standalone archive for manual installation
- `build/BarkVisor-VERSION.pkg` -- macOS installer package (unless `--no-pkg` was passed)

The build summary printed at the end includes the app bundle size, bundled helpers, framework count, and firmware file count.
