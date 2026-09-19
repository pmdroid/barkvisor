# Settings

## Sub-features

| Tab id (`?tab=`) | Controls |
|---|---|
| `home` | Device URL picker + advertised hosts; **Save changes** |
| `pairing` | **Add a Device** issues a pairing offer (short code + `barkvisor://` URI, not a pairing QR). Phone sign-in QR is separate. Re-pair paste box |
| `library` | Library path + Browse folder picker, capacity |
| `repositories` | Catalog URLs, **Add repository** / **Sync** / **Remove**, per-Device `deviceSyncs` status |
| `security` | Sign-in mode: **Require sign-in** / **Skip sign-in on this computer** / **Skip sign-in for my whole network** (`GET/PUT /api/settings/security`) |
| `apikeys` (default) | Create/show-once/revoke API keys |
| `sshkeys` | **Add Key**, Set Default/Delete |
| `passkeys` | Add/delete WebAuthn passkeys for this user |
| `audit` | Audit entries filtered by action |
| `updates` | Check/install in-app updates when the feature is on; otherwise **In-app updates unavailable** |

`?tab=disks` is not a Settings tab — the router sends you to **Devices**. Default VM disk directory lives on Device detail. Disk inventory is sidebar **Disks** (`/disks`). Tab clicks do not rewrite `?tab=` in the URL. When the front door is bypassed, `apikeys` and `passkeys` remap to **Security** and those two tab buttons hide.

## How to get to it (user POV)

Sidebar **Settings** → `/settings`. Tabs are deep-linkable: `/settings?tab=pairing` etc. Without a query you land on **API Keys** (or **Security** if sign-in is off).

## Driving it with Playwright

The proven end-to-end flow is the API-key create modal:

```sh
bun helpers/api-key-flow.mjs --base "$URL" --user admin --pass "$PASS" \
  --key-name "verify-proof" --dir "evidence/run-apikeys"
```

It logs in via `POST /api/auth/login` (JWT inject), opens `?tab=apikeys`, clicks **Create Key**, fills the placeholder input, submits, screenshots the show-once secret, closes with **Done**, then asserts `GET /api/auth/keys` contains the new row. Exit code 0 = proof complete.

Plain tab screenshots:

```sh
bun helpers/shot.mjs --base "$URL" --user admin --pass "$PASS" \
  --route "/settings?tab=audit" --out "evidence/run-settings/audit.png"
```

## Gotchas

- The show-once secret exists only in the create response; if you miss the screenshot you cannot recover it — revoke and re-create instead.
- Pairing tab starts empty (no active offer). **Add a Device** issues a real pairing offer (code + URI) — fine on throwaway instances, never on the user's Home. The QR on this tab is **phone sign-in**, not pairing.
- Prefer `shot.mjs --token` after one login; `POST /api/auth/login` is rate-limited and will 429 if every helper logs in separately.
- Library Browse opens a FolderPicker overlay backed by `GET /api/system/browse`; on macOS it lists real directories of the machine running the daemon.
- Audit Log rows exist only after auditable actions (seed's key/SSH-key creates already produce some).
