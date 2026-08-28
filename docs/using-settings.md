# Settings

**Settings** is one page with nine tabs. Each tab has its own doc page:

| Tab | What it controls |
|-----|------------------|
| Home | Device facts and Device URL — [Settings: Home](settings-home.md) |
| Pairing | Pairing QR to add Devices, phone sign-in — [Settings: Pairing](settings-pairing.md) |
| Library | Library path — [Settings: Library](settings-library.md) |
| Repositories | Catalog URLs and per-Device sync — [Settings: Repositories](settings-repositories.md) |
| Disks | Default VM disk directory — [Settings: Disks](settings-disks.md) |
| API Keys | API keys for scripts and inference clients — [Settings: API Keys](settings-api-keys.md) |
| SSH Keys | SSH keys injected into guests — [Settings: SSH Keys](settings-ssh-keys.md) |
| Passkeys | WebAuthn passkeys for web sign-in — [Settings: Passkeys](settings-passkeys.md) |
| Audit Log | Who did what, when — [Settings: Audit Log](settings-audit-log.md) |

Settings is admin-only; the **inference** role does not see it.

![Settings page on the default API Keys tab](img/settings-api-keys.png)

## Deep links

Tabs are addressable with `?tab=` using the ids `home`, `pairing`, `library`, `repositories`, `disks`, `apikeys`, `sshkeys`, `passkeys`, `audit` — e.g. `/settings?tab=pairing`. Several pages in this app (like **Add a {Device}**) link straight into a tab that way. Without a query you land on **API Keys**, the default tab. `/registry` redirects here at `?tab=repositories`.

## Related

- [Using the web UI](using-overview.md)
- [Home and pairing](home-and-pairing.md)
