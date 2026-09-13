# Settings: Repositories

The **Repositories** tab lists catalog URLs each Device in this Home syncs. Templates and images from those catalogs show up in [Create VM](create-workload.md). Member catalog errors show on this page, not only when Create VM fails.

![Settings Repositories tab: catalog URLs and sync](img/settings-repositories.png)

## Catalog URLs

Each row is a source:

- Name, type (`images`, `templates`, or `apps`), and the catalog URL
- Sync status per Device on built-in catalogs — idle, syncing, synced, or error, including `lastError`
- Last synced timestamp under each status badge (or `never` if the catalog has not synced)
- **Sync** pulls the catalog on Home and fans out to reachable members
- **Remove** on sources you added (built-in catalogs stay)

**Add repository** asks for the type and a catalog URL. That still lives on Home Settings, not on a member UI.

Built-in catalogs sync on startup. Use **Sync** when a catalog changed and you want it now.

## Built-in catalog URLs

Shipped catalogs have one membership-independent identity that never changes
between Home and members:

| Catalog | URL | Fetch backing |
|---|---|---|
| Big Bear Universal Apps | `barkvisor://builtin/bigbear` | GitHub zipball (https) |
| LinuxServer.io | `barkvisor://builtin/linuxserver` | manifests bundled in the binary |

The `barkvisor://` scheme is reserved: the server seeds these rows itself and
the API rejects them when you try to add them (**Add repository** only accepts
`http://` or `https://` URLs). The name segment is a single lowercase slug.
Which built-ins exist, and how each one is materialised (embedded manifests vs
the public zipball), is decided by the built-in catalog registry, not by the
database row — so the same URL behaves right on Home and on members (members
that have catalog fetching disabled fall back to the last catalog that synced).

Legacy databases may still hold the pre-builtin Big Bear rows (the GitHub
repository URL, or the member `barkvisor://home/catalog/apps` origin); the
`M021` migration rewrites unflipped built-in GitHub rows onto
`barkvisor://builtin/bigbear`, and rows that had already flipped to the member
origin keep receiving the catalog fanned out from Home.

App images and templates keep their regular https / member catalog URLs — the
built-in scheme covers app catalogs only.

## Related

- [Create a Workload](create-workload.md)
- [Images](using-images.md)
- [Settings: Library](settings-library.md)
