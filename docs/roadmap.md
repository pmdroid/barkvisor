# Roadmap

These are product ideas, not release commitments. See the [changelog](changelog.md) for release notes.

## Available now

BarkVisor supports paired Devices with a shared Home login, VMs on a chosen Device, Docker Compose apps from catalogs, per-Device image Libraries, and Ollama integration.

Create VM starts with a gallery before asking where to run the guest. Linux and Windows guest profiles support arm64 and x86_64. The dashboard shows which Device owns each workload. Each Device keeps running its local workloads when another Device is offline.

## Availability and moving workloads

- Restart a workload on another Device after a failure.
- Move a stopped workload between compatible Devices.
- Migrate a running VM between compatible Devices.
- Coordinate failover so a workload cannot accidentally start twice.
- Provide a dedicated Linux appliance image.

## Storage and backups

- Share workload storage between Devices.
- Deduplicate Library images by content hash.
- Add more ZFS snapshot and replication support.
- Schedule workload backups, verify them, and restore them as new workloads.
- Export a workload and its data for another Device.

Current database backups cover BarkVisor's database, not a complete backup of VM disks or App volumes.

## Apps, networking, and access

- Make Apps and their data portable between Devices.
- Add update policies and automatic rollback for workloads.
- Add private networking across Devices and friendly service URLs.
- Extend remote-access setup beyond detecting an existing Tailscale installation.
- Suggest workload placement based on energy use.

The [product ideas board](https://linear.app/kyku/project/barkvisor-product-ideas-66fdcb2cf979) tracks further proposals.
