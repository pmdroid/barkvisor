---
title: "Images"
description: "The OS image library on this Device — upload, download, free space."
---
**Images** is the OS image library on this Device: ISOs and cloud images that [Create VM](/docs/guides/create-workload/) offers as boot media.

![Images library with capacity bar](/docs-img/images.png)

## Library capacity

The capacity bar shows used/free space for the Library path's volume. That volume can differ from the data directory; the same numbers appear under [Settings → Library](/docs/using/settings/library/). When this Device fetches from a depot Device that is offline, you see an explicit empty/error state — not zeros.

## Upload and download

- **Upload** opens a split-rail wizard modal: pick a file (or paste a URL), review name/arch, and confirm. Archives are decompressed automatically.
- **Download** pulls an image from a configured catalog — see [Repositories](/docs/using/repositories/).

Catalog downloads follow this Device's architecture by default; you can still download the other arch when it will deploy on a matching Device.

## The table

Name · Type · Arch · Size · Status, with a delete action per row. Deleting frees library space but breaks nothing that already booted from it.

## Related

- [Repositories](/docs/using/repositories/)
- [Settings: Library](/docs/using/settings/library/)
- [Virtual Machines](/docs/using/vms/)
