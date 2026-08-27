# Settings

## Sub-features

| Tab id (`?tab=`) | Controls |
|---|---|
| `home` | Device facts, Tailscale/WireGuard detection, Advertise URL picker, require-tailnet toggle |
| `pairing` | Add-a-Device QR + expiry countdown, advertise-host picker, phone sign-in QR, Re-pair |
| `library` | Library path + Browse folder picker, capacity |
| `disks` | Default VM disk directory |
| `apikeys` (default) | Create/show-once/revoke API keys |
| `sshkeys` | Add SSH key, Set Default/Delete |
| `audit` | Audit entries filtered by resource group |

## How to get to it (user POV)

Sidebar **Settings** → `/settings`. Tabs are deep-linkable: `/settings?tab=pairing` etc. Without a query you land on **API Keys**.

## Driving it with Playwright

The proven end-to-end flow is the API-key create modal:

```sh
bun helpers/api-key-flow.mjs --base "$URL" --user admin --pass "$PASS" \
  --key-name "verify-proof" --dir "evidence/run-apikeys"
```

It logs in via the form, opens `?tab=apikeys`, clicks **Create Key**, fills the placeholder input, submits, screenshots the show-once secret, closes with **Done**, then asserts `GET /api/auth/keys` contains the new row. Exit code 0 = proof complete.

Plain tab screenshots:

```sh
bun helpers/shot.mjs --base "$URL" --user admin --pass "$PASS" \
  --route "/settings?tab=audit" --out "evidence/run-settings/audit.png"
```

## Gotchas

- The show-once secret exists only in the create response; if you miss the screenshot you cannot recover it — revoke and re-create instead.
- Pairing tab starts empty (no active offer); the QR appears after clicking the add button, which issues a real pairing offer — fine on throwaway instances, never on the user's Home.
- Library Browse opens a FolderPicker overlay backed by `GET /api/system/browse`; on macOS it lists real directories of the machine running the daemon.
- Audit Log rows exist only after auditable actions (seed's key/SSH-key creates already produce some).
