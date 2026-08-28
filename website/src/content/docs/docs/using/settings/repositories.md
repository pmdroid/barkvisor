---
title: "Settings: Repositories"
description: "Catalog URLs and per-Device sync for templates and images."
---
The **Repositories** tab lists catalog URLs each Device in this Home syncs. Templates and images from those catalogs show up in [Create VM](/docs/guides/create-workload/). Member catalog errors show on this page, not only when Create VM fails.

![Settings Repositories tab: catalog URLs and sync](/docs-img/settings-repositories.png)

## Catalog URLs

Each row is a source:

- Name, type (`images` or `templates`), and the catalog URL
- Sync status per Device on built-in catalogs — idle, syncing, synced, or error, including `lastError`
- **Sync** pulls the catalog on Home and fans out to reachable members
- **Remove** on sources you added (built-in catalogs stay)

**Add repository** asks for the type and a catalog URL. That still lives on Home Settings, not on a member UI.

Built-in catalogs sync on startup. Use **Sync** when a catalog changed and you want it now.

## Related

- [Create a Workload](/docs/guides/create-workload/)
- [Images](/docs/using/images/)
- [Settings: Library](/docs/using/settings/library/)
