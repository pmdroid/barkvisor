# Building releases

This guide is for contributors building packages. To install BarkVisor, use a release package from the [macOS](getting-started-installation.md), [Linux](getting-started-linux.md), or [Windows](getting-started-windows.md) guide.

## macOS package

Use the Swift toolchain pinned in `mise.toml`, Bun, and the packaging tools:

```sh
brew install dylibbundler xz cdrtools
./scripts/build-release.sh --no-sign
```

Run the script from the repository root. It builds the frontend and Swift daemon, stages the install layout, bundles supporting libraries, and creates a package for local use.

The default package includes `xz` and `mkisofs`. It does not build or bundle QEMU, swtpm, or socket_vmnet. Install those separately with Homebrew on the destination Mac.

### Version and output

Set `BARKVISOR_VERSION` to choose the version. Otherwise, the script uses an exact `v*` tag on the current commit, or `0.0.0-dev`. It embeds the version in the daemon and frontend.

Output:

- `build/stage/`, the install layout.
- `build/BarkVisor-<version>-standalone.tar.gz`.
- `build/BarkVisor-<version>.pkg` and its `.sha256` checksum.

### Signing and notarization

Distribution builds need both signing identities and the `barkvisor-notarize` Keychain profile:

```sh
export SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export INSTALLER_IDENTITY="Developer ID Installer: Your Name (TEAMID)"
./scripts/build-release.sh --require-notarize
```

The script signs the binaries and installer, submits the `.pkg` through `xcrun notarytool`, and staples the ticket. It does not create a DMG. Configure the Keychain profile with valid notarization credentials before running the script.

| Flag | Effect |
|------|--------|
| `--skip-deps` | Reuse cached source dependency builds when bundling them |
| `--no-sign` | Skip executable and library signing |
| `--skip-notarize` | Skip notarization of a signed package |
| `--no-pkg` | Skip installer creation, subject to the limitation below |
| `--require-notarize` | Require signing identities and a working Keychain profile |

The script currently writes a package checksum even with `--no-pkg`. On a clean build that final step fails, although the standalone archive has been created.

The script sources `.env` if present. Assignments there can replace exported values. Keep version and signing configuration consistent.

### Optional bundled runtime

Set `BUNDLE_HYPERVISOR_DEPS=true` to build the older bundled runtime path. It builds QEMU, xz, libtpms, swtpm, socket_vmnet, and firmware from the pinned sources.

This path also needs `uv` and native build tools:

```sh
brew install meson ninja pkg-config glib pixman dylibbundler \
  gnutls jpeg-turbo libpng libssh libusb zstd lzo snappy \
  autoconf automake libtool json-glib gawk cdrtools uv
BUNDLE_HYPERVISOR_DEPS=true ./scripts/build-release.sh --no-sign
```

Version and checksum overrides are defined near the top of `scripts/build-release.sh`.

## Linux packages

On a Linux build host with Swift and the packaging tools:

```sh
swift build -c release --product BarkVisorApp
./scripts/linux-frontend-serve.sh
./scripts/build-linux-packages.sh
```

Or use Docker, including from macOS:

```sh
./scripts/build-linux-packages.sh --docker
```

Artifacts go to `build/linux-packages/`.

| Format | Use |
|--------|-----|
| `.deb` | Ubuntu and Debian installation and in-app updates |
| `.rpm` | Builder output for Fedora, Rocky, Alma, and RHEL |
| `.tar.gz` | Portable installation on compatible glibc hosts |
| Arch `PKGBUILD` | Arch packaging |

Packages include the daemon, frontend, and Swift runtime. QEMU and firmware come from the distribution.

The **Linux Packages** workflow builds amd64 and arm64 packages on `v*` tags or manual dispatch. Tag builds attach release assets; manual runs upload CI artifacts. The workflow and Docker build inject the release version before Swift compilation. Changing package metadata alone does not change an already-built binary.

See [Linux packaging](../packaging/linux/README.md) for layout and dependencies.

## Windows zip

The **Windows Package** workflow builds `barkvisor-windows-amd64.zip` and `barkvisor-windows-arm64.zip` on `v*` tags or manual dispatch.

The zip contains `BarkVisor.exe`, Swift and VC runtime DLLs, and frontend assets. QEMU is installed separately. Local build instructions are in [Development](getting-started-development.md#windows-packages).

## Test a local package update

Build a package with a newer version than the test Device, then serve it with:

```sh
scripts/serve-local-updates.sh --dir build/linux-packages --tag v9.9.9
```

For macOS, use `--dir build`. The script prints a loopback `BARKVISOR_UPDATE_URL` for a GitHub-shaped release feed.

Set that variable in the test Device's service environment and restart it. Linux uses `/etc/barkvisor/barkvisor.env`; macOS uses `EnvironmentVariables` in `/Library/LaunchDaemons/dev.barkvisor.plist`. Development builds also offer **Test update URL** in Settings → Updates.

The feed listens on loopback. Run it on the test Device, or tunnel the port so the Device's loopback address reaches it. Remove the override after testing to return to GitHub Releases.
