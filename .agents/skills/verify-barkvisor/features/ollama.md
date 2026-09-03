# Ollama

## Sub-features

- Per-Device picker (runtime status) + inspect pane
- Pull-by-name, catalog table, Start/Stop, completions URL, **Export JSON**
- Inference-role users are locked to this page (`/models`); `/chat` redirects to Dashboard

## How to get to it (user POV)

Sidebar **Ollama** → `/models`.

## Driving it with Playwright

```sh
bun helpers/shot.mjs --base "$URL" --token "$TOKEN" \
  --route /models --out "evidence/run-ollama/ollama.png"
```

Assertions:

- `h1` is Ollama
- Device picker lists this Device
- Seeded instance typically has no pulled models — empty/catalog state is expected
- Do not click Start/Pull unless you want a real Ollama install/pull on the host

## Gotchas

- Start/Pull mutate the host (installs or pulls models). Screenshots + `GET /api/ollama/status` (or the page's own status chip) are enough for a map proof.
- Completions URL is per the Device that already has the model.
