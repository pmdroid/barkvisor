# Linux packaging

Metadata and helpers for multi-format BarkVisor packages (**arm64** and **amd64**).

## Formats

| Artifact | Distros |
|----------|---------|
| `barkvisor_*_{amd64,arm64}.deb` | Ubuntu, Debian |
| `barkvisor-*-1.*.{x86_64,aarch64}.rpm` | Fedora, Rocky, Alma, RHEL |
| `barkvisor-*-linux-{x86_64,aarch64}.tar.gz` | Any glibc host (+ `install.sh`) |
| `arch/PKGBUILD` | Arch / Arch ARM (`makepkg`) |

The appliance channel for operators is **Ubuntu / Debian `.deb`**. rpm / tarball / Arch
are still produced for builders. They are not the getting-started path.

## Layout (all formats)

```
/usr/local/bin/barkvisor
/usr/local/bin/barkvisor-agent              # symlink; API-only Device (no SPA)
/usr/local/share/barkvisor/frontend/dist/   # SPA (packages still bundle this by default)
/usr/local/lib/barkvisor/swift/             # bundled Swift runtime
/usr/local/lib/barkvisor/compat/            # optional SONAME shims
/usr/lib/systemd/system/barkvisor.service
/usr/lib/systemd/system/barkvisor-agent.service
/etc/barkvisor/barkvisor.env
/var/lib/barkvisor                          # created by maintainer scripts
```

QEMU, OVMF/AAVMF, ISO tools (genisoimage/xorriso/cdrtools), and **usbutils** are
**hard dependencies** (`Depends` / `Requires` / `depends`). Installing the BarkVisor
package pulls them from the distro package manager. They are not bundled inside
the BarkVisor payload.

## Build

```bash
# Linux host with Swift + dpkg-dev (and optionally rpm-build)
swift build -c release --product BarkVisorApp
./scripts/linux-frontend-serve.sh
./scripts/build-linux-packages.sh

# Docker (works from macOS)
./scripts/build-linux-packages.sh --docker
```

See `scripts/build-linux-packages.sh` and `docs/getting-started-linux.md`.

## GitHub Releases

On a version tag (`v*`), the **Linux Packages** workflow builds packages and
**attaches** `.deb` / `.rpm` / `.tar.gz` / `.sha256` to that tag’s GitHub
Release (creating the release if needed). Manual `workflow_dispatch` runs only
upload CI artifacts — they do not mutate Releases.

macOS `.pkg` assets from the separate release process keep different filenames
and are not removed when Linux assets are re-uploaded (`gh release upload
--clobber` only replaces matching names).

arm64 package jobs are currently commented out in the workflow matrix (amd64
GitHub-hosted runners only); build arm64 via
`./scripts/build-linux-packages.sh --docker` on an arm64 host until runners are
enabled.
