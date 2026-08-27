# Settings: Passkeys

The **Passkeys** tab stores WebAuthn credentials for this user. The web console signs in with a passkey only — no username or password.

Passkeys need a WebAuthn-capable browser in a secure context: **https** or **localhost**, and a hostname (MagicDNS or a DNS name). A raw IP is rejected, including `http://127.0.0.1`. Tailscale MagicDNS over **http** is not enough — terminate TLS (`tailscale serve --bg 7777`) and open `https://<magicdns>`. A passkey is bound to that hostname; one registered on localhost will not sign in on the tailnet name.

First-run setup registers the first passkey. Add more here.

## Add a passkey

1. Open **Settings → Passkeys** (`?tab=passkeys`).
2. Optionally name it, then click **Add passkey**.
3. Confirm with the platform prompt (Touch ID, Windows Hello, a password manager).

## Managing passkeys

- **Delete** asks for confirm. You cannot delete the last passkey. Already-issued sessions stay until they expire.

Sign in later with **Sign in with passkey** on the login page. The native Console app stays password-only (headless setup still sets a password for scripts).

## Related

- [Settings: API Keys](settings-api-keys.md)
- [Using the web UI](using-overview.md)
