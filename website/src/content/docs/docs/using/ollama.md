---
title: "Ollama"
description: "Model runtime status per Device, pulling models, and API access."
---
The **Ollama** page manages local model runtimes across the Home. It is visible to admins and to users with the **inference** role.

## Picking a Device

The left rail lists Devices with their Ollama reach state; **This Device** tags the machine you are browsing from. Selecting one scopes the inspect pane.

## Status and models

The right pane shows:

- A status chip with a **Recheck** button to re-detect the runtime now
- The model list on that Device, with pull management for adding more

For installing Ollama itself, pulling models, and how completions route through the Home, read the [Ollama guide](/docs/guides/ollama/).

## Use this API

Collapsible panel for pointing other tools at the models:

- The LAN completions URL (`http://<device>:7777/v1`)
- Ready-made `curl` and environment-variable snippets with copy buttons
- Minting of an inference API key, shown exactly once — copy it immediately, then find it (masked, revocable) under [Settings → API Keys](/docs/using/settings/api-keys/)

## Export

Toolbar overflow menu → **More → Export JSON** dumps the current model inventory.

## Related

- [Chat](/docs/using/chat/) — talk to these models
- [Settings: API Keys](/docs/using/settings/api-keys/)
