# syntax=docker/dockerfile:1
# BarkVisor Linux image (daemon + SPA) for local smoke / headless deploys.
#
# Build:
#   docker build -t barkvisor:dev .
# Run (KVM when available):
#   docker run --rm -it --device /dev/kvm -p 7777:7777 barkvisor:dev
# Run without KVM (TCG, slow):
#   docker run --rm -it -p 7777:7777 barkvisor:dev
#
# Align Ubuntu major with the official Swift Linux toolchain you use locally
# (Ubuntu 24.04 / noble recommended). Override tags:
#   docker build --build-arg SWIFT_VERSION=6.2.3 --build-arg UBUNTU_VERSION=24.04 .

ARG SWIFT_VERSION=6.2.3
ARG UBUNTU_VERSION=24.04
ARG BUN_VERSION=1.2.5
# Optional: bake product version into Config.swift (e.g. 1.2.3). Default leaves 0.0.0-dev.
ARG BARKVISOR_VERSION=

# ---------------------------------------------------------------------------
# Stage 1 — Vue SPA (bun preferred; layout matches install-linux share path)
# ---------------------------------------------------------------------------
FROM oven/bun:${BUN_VERSION}-alpine AS frontend
WORKDIR /frontend
COPY frontend/package.json frontend/bun.lock* frontend/package-lock.json* ./
# Prefer frozen lock when present; fall back for first-time lockfiles.
RUN if [ -f bun.lock ]; then bun install --frozen-lockfile; \
    elif [ -f package-lock.json ]; then bun install; \
    else bun install; fi
COPY frontend/ ./
RUN bun run build \
    && test -f dist/index.html

# ---------------------------------------------------------------------------
# Stage 2 — Swift release binary
# ---------------------------------------------------------------------------
FROM swift:${SWIFT_VERSION}-noble AS build
ARG BARKVISOR_VERSION=
WORKDIR /src
# Manifests first for better layer cache
COPY Package.swift Package.resolved* .swift-version* ./
COPY Sources ./Sources
COPY Tests ./Tests
COPY Resources ./Resources
COPY repos ./repos
COPY scripts/lib/inject-version.sh ./scripts/lib/inject-version.sh
# Embed SPA for findFrontendDist / Resources probes during build tests if needed
COPY --from=frontend /frontend/dist ./Sources/BarkVisor/Resources/frontend/dist
RUN set -euo pipefail \
    && if [ -n "${BARKVISOR_VERSION}" ]; then \
         . ./scripts/lib/inject-version.sh \
         && barkvisor_inject_config_version "${BARKVISOR_VERSION}"; \
       fi \
    && swift build -c release --product BarkVisorApp \
    && install -d /out \
    && cp -a .build/release/BarkVisorApp /out/barkvisor

# ---------------------------------------------------------------------------
# Stage 3 — Runtime (matches install-linux layout under /usr/local)
# ---------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION}

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libcurl4 \
    libxml2 \
    libsqlite3-0 \
    libncurses6 \
    libzstd1 \
    libedit2 \
    zlib1g \
    qemu-system-arm \
    qemu-system-x86 \
    qemu-utils \
    qemu-efi-aarch64 \
    ovmf \
    genisoimage \
    && rm -rf /var/lib/apt/lists/*

# Swift runtime libs (dynamic link from release binary)
COPY --from=build /usr/lib/swift /usr/lib/swift

# Install layout: /usr/local/bin/barkvisor + /usr/local/share/barkvisor/frontend/dist
RUN mkdir -p /usr/local/bin /usr/local/share/barkvisor/frontend/dist \
    /var/lib/barkvisor /var/run/barkvisor \
    && useradd --system --home /var/lib/barkvisor --shell /usr/sbin/nologin barkvisor \
    && chown -R barkvisor:barkvisor /var/lib/barkvisor /var/run/barkvisor

COPY --from=build /out/barkvisor /usr/local/bin/barkvisor
COPY --from=frontend /frontend/dist/ /usr/local/share/barkvisor/frontend/dist/

# Daemon defaults (override at run time)
ENV BARKVISOR_HOME=/var/lib/barkvisor \
    BARKVISOR_DATA_DIR=/var/lib/barkvisor \
    BARKVISOR_PORT=7777 \
    HOME=/var/lib/barkvisor

USER barkvisor
WORKDIR /var/lib/barkvisor
EXPOSE 7777

# argv[0] under /usr/local/bin so Config.prefix resolves to /usr/local (SPA via Config.frontendDir)
ENTRYPOINT ["/usr/local/bin/barkvisor"]
