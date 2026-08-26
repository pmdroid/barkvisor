---
title: "Settings: SSH Keys"
description: "Public keys injected into guests, defaults, and deletion."
---
The **SSH Keys** tab stores public keys that get injected into guests, so you can `ssh` into Workloads without password games.

![Settings SSH Keys tab](/docs-img/settings-ssh-keys.png)

## Add a key

1. Click add.
2. Give it a **name** and paste the **public key** (the `ssh-ed25519 …`/`ssh-rsa …` line from your `~/.ssh/*.pub`).
3. Save — the key lands in the table.

## Managing keys

- **Set Default** — marks the key new Workloads receive
- **Delete** — removes it from the store; already-provisioned guests keep their copy until reprovisioned

For secret-less API access instead of shell access, use [API Keys](/docs/using/settings/api-keys/).

## Related

- [Settings: API Keys](/docs/using/settings/api-keys/)
- [Workload details](/docs/using/vm-details/)
