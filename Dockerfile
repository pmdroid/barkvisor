# syntax=docker/dockerfile:1
# Experimental BarkVisor Linux image for local smoke tests.
# Build:  docker build -t barkvisor:dev .
# Run:    docker run --rm -it --device /dev/kvm -p 7777:7777 barkvisor:dev
#
# Note: Ubuntu version should match the Swift Linux toolchain release you use.

ARG SWIFT_VERSION=6.2.3
ARG UBUNTU_VERSION=24.04

FROM swift:${SWIFT_VERSION}-noble AS build

WORKDIR /src
# Copy only package manifests first for better layer caching
COPY Package.swift Package.resolved* ./
COPY Sources ./Sources
COPY Tests ./Tests
COPY Resources ./Resources
COPY repos ./repos

RUN swift build -c release --product BarkVisorApp

FROM ubuntu:${UBUNTU_VERSION}

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    libcurl4 \
    libxml2 \
    libsqlite3-0 \
    libncurses6 \
    libzstd1 \
    libedit2 \
    zlib1g \
    qemu-system-arm \
    qemu-utils \
    && rm -rf /var/lib/apt/lists/*

# Runtime may need Swift shared libraries for the binary
COPY --from=build /usr/lib/swift /usr/lib/swift
COPY --from=build /src/.build/release/BarkVisorApp /usr/local/bin/barkvisor

ENV BARKVISOR_HOME=/var/lib/barkvisor
RUN mkdir -p /var/lib/barkvisor /var/run/barkvisor \
    && useradd --system --home /var/lib/barkvisor --shell /usr/sbin/nologin barkvisor \
    && chown -R barkvisor:barkvisor /var/lib/barkvisor /var/run/barkvisor

USER barkvisor
WORKDIR /var/lib/barkvisor
EXPOSE 7777

# Binary is BarkVisorApp renamed; process detection uses argv[0] path for prefix.
ENTRYPOINT ["/usr/local/bin/barkvisor"]
