# Ollama

The **Ollama** nav item (route `/models`) manages local model runtimes across the Home. It is visible to admins and to users with the **inference** role.

![Ollama page with per-Device status and model list](img/ollama.png)

## Picking a Device

The left rail lists Devices with their Ollama reach state and pulled-model counts. Selecting one scopes the inspect pane.

## Status and models

The right pane shows:

- A status chip with a **Recheck** button to re-detect the runtime now
- The **Completions** endpoint for this Home (`/v1/chat/completions`) with **Copy**
- **Pull by name** as a fallback when you already know the model slug
- **Filter catalog** to match names already pulled on the Home
- The model table on that Device (Model · Size · Device · State) with per-row **Start**; starting a model that lives on several Devices offers a Device picker limited to Devices that have it

For installing Ollama itself, pulling models, and how completions route through the Home, read the [Ollama guide](ollama.md).

## Completions

The inspect pane shows the Home completions URL (`/v1/chat/completions`). Inference keys live under Settings → API Keys.

## Export

The **More** menu holds **Export JSON**, which dumps the current `ollama ps` output. It is hidden when no Device is reachable.

## Related

- [Settings: API Keys](settings-api-keys.md)
