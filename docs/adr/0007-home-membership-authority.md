# Home membership has one local authority

Each Device's management daemon is the membership authority for that Device. Pairing admission, active membership, request authorization, certificate renewal, and removal go through one ledger. Local Workloads do not consult it and keep running when other Devices or their ledgers are unreachable.

## Issuer

Each Device keeps its own session signing key (`jwt-secret`) and a separate management key (`authority/management.key`). Pairing copies the Home passkey (the admin record) and does not copy either private key. A person still signs in with that passkey on a Device and manages the Home from that console.

The console proves a member hop with a short-lived credential signed by its Device transport key. The receiving daemon checks that signature against the admitted key, checks the ledger, and only then mints a management credential with `authority/management.key` for the local API. The management private key is not a transport credential.

## What BarkServer may hold

BarkServer terminates public TLS, including Device TLS, so it has to hold this Device's transport certificate and `agent/device.key`, plus the Home CA certificate it uses to verify peers. It does not get `authority/management.key`, `home-ca/ca.key`, `jwt-secret`, the API-key HMAC secret, or the membership ledger.

A compromised BarkServer can terminate or observe public TLS and, while it holds `agent/device.key`, can present this Device's current transport identity to peers. It cannot rewrite the ledger or mint a management credential the local API will accept. The process split in #702 has to keep those authority files out of the BarkServer mount. A caller-supplied identity header is ignored. A peer is authorized only when the presented certificate matches an active ledger record.

## Revocation and offline peers

Removal on a Device is a single ledger update: the member stays in the ledger as removed, the revision increments, and directory and pin rows are dropped in that same update. Removed keys do not authorize certificate, login-token, or proxy requests on that Device. Renewal or key rotation of a removed member does not make them active again. An active member can rotate a key; the new key replaces the old one and the old key stops matching.

Peers learn a removal by importing a signed ledger snapshot. A snapshot from a member this Device has already removed is ignored. A snapshot cannot clear a removal or replace another member's key. It can mark members removed and refresh the sync clock.

`HomeMembershipPolicy.maximumStaleAuthorizationWindow` is 24 hours. The Device that committed a removal denies it immediately. Another Device that has not imported that snapshot may still authorize the member until 24 hours after its last accepted snapshot or local membership commit. After that, peer authorization fails closed until a newer snapshot arrives. Local Workloads are outside that check.

## Existing Homes

On startup the daemon builds the ledger from the current directory and pins when no ledger exists, then rotates `jwt-secret` once if this Device already joined a Home. The passkey record stays. Existing shared-secret tokens stop verifying. The next passkey sign-in is local to this Device, and member hops use the scoped credential above.

## Pairing

An offer binds the exchange id and the joiner's presented key. Admission is pending until the certificate, pin, directory row, and ledger commit all succeed. Pending and aborted exchanges do not authorize. A failed attempt is retried with a new offer. Re-pair after removal is a new exchange; it does not revive the removed record in place.
