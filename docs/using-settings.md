# Settings

**Settings** is one page with tabs. Each tab has its own doc page:

| Tab | What it controls |
|-----|------------------|
| Home | Device facts and Device URL — [Settings: Home](settings-home.md) |
| Pairing | Pairing QR to add Devices, phone sign-in — [Settings: Pairing](settings-pairing.md) |
| Library | Library path — [Settings: Library](settings-library.md) |
| Repositories | Catalog URLs and per-Device sync — [Settings: Repositories](settings-repositories.md) |
| Security | Require or skip sign-in — [Settings: Security](settings-security.md) |
| Updates | Appliance `.deb` / `.pkg` apply on a root Device — [Settings: Updates](settings-updates.md) |
| API Keys | API keys for scripts and inference clients — [Settings: API Keys](settings-api-keys.md) |
| SSH Keys | SSH keys injected into guests — [Settings: SSH Keys](settings-ssh-keys.md) |
| Passkeys | WebAuthn passkeys for web sign-in — [Settings: Passkeys](settings-passkeys.md) |
| Audit Log | Who did what, when — [Settings: Audit Log](settings-audit-log.md) |

Settings is admin-only; the **inference** role does not see it.

![Settings page on the default API Keys tab](img/settings-api-keys.png)

## Deep links

You can bookmark a tab directly, for example `/settings?tab=updates`. Tab IDs are `home`, `pairing`, `library`, `repositories`, `security`, `updates`, `apikeys`, `sshkeys`, `passkeys`, and `audit`.

Settings normally opens on **API Keys**. Sessions that skip sign-in open on **Security** and hide API Keys and Passkeys. The default VM disk folder is on the Device page.

## Related

- [Using the web UI](using-overview.md)
- [Home and pairing](home-and-pairing.md)
