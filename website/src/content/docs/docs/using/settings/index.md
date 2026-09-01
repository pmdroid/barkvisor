---
title: "Settings"
description: "The Settings tabs, including Updates on a root appliance."
---
**Settings** is one page with tabs. Each tab has its own doc page:

| Tab | What it controls |
|-----|------------------|
| Home | Device facts and Device URL — [Settings: Home](/docs/using/settings/home/) |
| Pairing | Pairing QR to add Devices, phone sign-in — [Settings: Pairing](/docs/using/settings/pairing/) |
| Library | Library path — [Settings: Library](/docs/using/settings/library/) |
| Repositories | Catalog URLs and per-Device sync — [Settings: Repositories](/docs/using/settings/repositories/) |
| Updates | Appliance `.deb` / `.pkg` apply on a root Device — [Settings: Updates](/docs/using/settings/updates/) |
| API Keys | API keys for scripts and inference clients — [Settings: API Keys](/docs/using/settings/api-keys/) |
| SSH Keys | SSH keys injected into guests — [Settings: SSH Keys](/docs/using/settings/ssh-keys/) |
| Passkeys | WebAuthn passkeys for web sign-in — [Settings: Passkeys](/docs/using/settings/passkeys/) |
| Audit Log | Who did what, when — [Settings: Audit Log](/docs/using/settings/audit-log/) |

Settings is admin-only; the **inference** role does not see it.

![Settings page on the default API Keys tab](/docs-img/settings-api-keys.png)

## Deep links

Tabs are addressable with `?tab=` using the ids `home`, `pairing`, `library`, `repositories`, `updates`, `apikeys`, `sshkeys`, `passkeys`, `audit`. Example: `/settings?tab=updates`. Several pages in this app (like **Add a {Device}**) link straight into a tab that way. Without a query you land on **API Keys**, the default tab. `/registry` redirects here at `?tab=repositories`. `/settings?tab=disks` redirects to **Devices**; the default VM disk directory is on the Device page.

## Related

- [Using the web UI](/docs/using/)
- [Home and pairing](/docs/guides/home-and-pairing/)
