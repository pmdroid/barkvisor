# Settings and pairing

Settings is the signed-in control surface for this Home: remote access, pairing offers, Library path, API keys, SSH keys, and the audit log.

## Sub-features

- `settings-tabs` shows Home, Pairing, Library, API Keys, SSH Keys, and Audit Log.
- `settings-home` shows the Home / remote-access copy on the default tab.
- `settings-pairing-issue` creates an offer via `Add a Device` (`barkvisor://pair/v1?…`).
- `settings-pairing-revoke` removes the offer with `Revoke`.
- `settings-apikey-mint` creates a key and shows the secret once.
- `settings-apikey-cancel` closes the create modal without a key.

## How to get to it (user POV)

- Choose `Settings` in the sidebar, or open `/settings`.
- Choose the Pairing tab, then `Add a Device`.
- Choose the API Keys tab, then `Create Key`.

## Driving it with drive.ts

Preconditions:

- Setup complete; signed in as admin.
- No leftover pairing offer or key named `verify-key` (revoke / delete if reusing an instance).

- **Tabs.** Run `bun .agents/skills/verify-barkvisor/drive.ts open /settings --label settings`. Heading `Settings` is visible. Buttons `Home`, `Pairing`, `Library`, `API Keys`, `SSH Keys`, `Audit Log` are visible. Home is active. Capture `settings-home`.
- **Pairing issue.** Choose `Pairing`. Choose `Add a Device`. An offer appears: short code, QR, and a `pre` payload starting with `barkvisor://pair/v1`. Capture `settings-pairing`. Confirm the payload is still present after reload of `/settings` and re-opening Pairing.
- **Pairing revoke.** Choose `Revoke`. Empty copy `No pairing code yet` returns.
- **API key modal.** Choose `API Keys`. Choose `Create Key`. Heading `Create API Key` is visible. `Create` is disabled until a name is entered. Choose `Cancel`. Modal closes.
- **API key mint.** Open `Create Key`, fill a name (`verify-key`), choose `Create`. Heading `API Key Created` and copy `Copy this key now` are visible. Capture `settings-apikey`. Close the modal. A row named `verify-key` remains on the list after reload.

## Gotchas

- Cypress settings specs still expect three tabs (API Keys, SSH Keys, Audit Log). The UI now has six, with Home first. Drive the six.
- The pairing offer is the full `barkvisor://` URI, not the short printed code. Join on another Device fails with only the short code.
- Minting a key shows the secret once. A list row with a masked key is not proof of `settings-apikey-mint` unless the created-secret dialog was captured.
- Pairing issue hits `/api/pairing/codes` as the signed-in admin. Do not POST that from curl and then screenshot Settings as the user path.
- Revoke before cleanup if the instance will be reused; deleting the data dir on `cleanup` is enough for an isolated run.
