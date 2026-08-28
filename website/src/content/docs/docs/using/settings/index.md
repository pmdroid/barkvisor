---
title: "Settings"
description: "The eight Settings tabs and what each one controls."
---
**Settings** is one page with eight tabs. Each tab has its own doc page:

| Tab | What it controls |
|-----|------------------|
| Home | Device facts, remote access, advertise URL — [Settings: Home](/docs/using/settings/home/) |
| Pairing | Pairing QR to add Devices, phone sign-in — [Settings: Pairing](/docs/using/settings/pairing/) |
| Library | Library path — [Settings: Library](/docs/using/settings/library/) |
| Disks | Default VM disk directory — [Settings: Disks](/docs/using/settings/disks/) |
| API Keys | API keys for scripts and inference clients — [Settings: API Keys](/docs/using/settings/api-keys/) |
| SSH Keys | SSH keys injected into guests — [Settings: SSH Keys](/docs/using/settings/ssh-keys/) |
| Passkeys | WebAuthn passkeys for web sign-in — [Settings: Passkeys](/docs/using/settings/passkeys/) |
| Audit Log | Who did what, when — [Settings: Audit Log](/docs/using/settings/audit-log/) |

Settings is admin-only; the **inference** role does not see it.

![Settings page on the default API Keys tab](/docs-img/settings-api-keys.png)

## Deep links

Tabs are addressable with `?tab=` using the ids `home`, `pairing`, `library`, `disks`, `apikeys`, `sshkeys`, `passkeys`, `audit` — e.g. `/settings?tab=pairing`. Several pages in this app (like **Add a {Device}**) link straight into a tab that way. Without a query you land on **API Keys**, the default tab.

## Related

- [Using the web UI](/docs/using/)
- [Home and pairing](/docs/guides/home-and-pairing/)
