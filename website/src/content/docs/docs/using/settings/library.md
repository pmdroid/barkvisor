---
title: "Settings: Library"
description: "Library path, capacity, reset, and the depot Device."
---
The **Library** tab points this Device at its image store and explains the depot.

## Library path

- Current Library directory with a **Browse** folder picker (overlay dialog)
- Capacity readout — used/free on the volume holding that path (the same bar as on [Images](/docs/using/images/))
- **Reset to default** to return to the stock location

Moving the path does not move existing files for you; plan a copy when changing it.

## Library depot

One Device can act as the **depot**: others fetch verified image bytes from it over the agent plane instead of re-downloading from the internet. The depot select lives here; an offline depot shows an explicit empty/error state on consumers, never silent zeros.

## Related

- [Images](/docs/using/images/)
- [Repositories](/docs/using/repositories/)
- [Settings: Disks](/docs/using/settings/disks/) — where VM disks go, not images
