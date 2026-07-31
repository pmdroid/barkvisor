# Linux packaging

Metadata and helpers for multi-format BarkVisor packages (**arm64** and **amd64**).

## Formats

| Artifact | Distros |
|----------|---------|
| `barkvisor_*_{amd64,arm64}.deb` | Ubuntu, Debian |
| `barkvisor-*-1.*.{x86_64,aarch64}.rpm` | Fedora, Rocky, Alma, RHEL |
| `barkvisor-*-linux-{x86_64,aarch64}.tar.gz` | Any glibc host (+ `install.sh`) |
| `arch/PKGBUILD` | Arch / Arch ARM (`makepkg`) |

Alpine is **not** packaged as `.apk` (musl; no official Swift toolchain). Use a
glibc binary tarball only if you know what you are doing, or Docker.

## Layout (all formats)

```
/usr/local/bin/barkvisor
/usr/local/share/barkvisor/frontend/dist/   # SPA
/usr/local/lib/barkvisor/swift/             # bundled Swift runtime
/usr/local/lib/barkvisor/compat/            # optional SONAME shims
/usr/lib/systemd/system/barkvisor.service
/etc/barkvisor/barkvisor.env
/var/lib/barkvisor                          # created by maintainer scripts
```

QEMU, OVMF/AAVMF, and genisoimage/xorriso are **Recommends / optdepends** — install
from the distro.

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
