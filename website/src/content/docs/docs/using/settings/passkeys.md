---
title: "Settings: Passkeys"
description: "WebAuthn passkeys for passwordless web sign-in."
---
The **Passkeys** tab stores WebAuthn credentials for this user so you can sign in to the web UI without a password. Password login stays.

Passkeys need a WebAuthn-capable browser in a secure context: **https** or **localhost**, and a hostname (MagicDNS or a DNS name). A raw IP is rejected, including `http://127.0.0.1` — use `http://localhost` instead.

## Add a passkey

1. Open **Settings → Passkeys** (`?tab=passkeys`).
2. Optionally name it, then click **Add passkey**.
3. Confirm with the platform prompt (Touch ID, Windows Hello, a password manager).

## Managing passkeys

- **Delete** asks for confirm. The credential is gone for this Home; already-issued sessions stay until they expire.

Sign in later with **Sign in with passkey** on the login page (discoverable, no username). The native Console app stays password-only.

## Related

- [Settings: API Keys](/docs/using/settings/api-keys/)
- [Using the web UI](/docs/using/)
