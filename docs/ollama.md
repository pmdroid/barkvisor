# Run models with Ollama

Ollama is optional. Install it on a Device to run local models, then use BarkVisor to manage those models and connect inference clients.

## 1. Install Ollama

Open **Ollama** in BarkVisor. If the runtime is unavailable, the page shows installation instructions and a **Recheck** button.

On macOS:

```sh
brew install ollama
brew services start ollama
```

For other platforms, follow [Ollama's download instructions](https://ollama.com/download). After it starts, click **Recheck**.

## 2. Download a model

Choose the Device where the model should be stored.

Use **Search the Ollama library** to find models and click **Download**, or use **Pull by name** if you already know the model name. **Filter catalog** searches models already downloaded in your Home.

Model files stay on the Device that downloads them. Choose a model that fits that Device's available memory.

## 3. Start or stop a model

Click **Start** beside a downloaded model. If several reachable Devices have it, choose one. With only one eligible Device, BarkVisor uses it directly.

A model cannot start on a Device that does not have its files. **Stop** unloads it from the Device running it and asks for confirmation.

## 4. Connect a client

Copy the **Completions** URL from the Ollama page. BarkVisor exposes an OpenAI-compatible endpoint through the Home console:

```text
http://<device-address>:7777/v1/chat/completions
```

Use the displayed HTTPS address if you configured HTTPS access. Clients that ask for a base URL use the address ending in `/v1`.

Create an **inference** key under [Settings → API Keys](settings-api-keys.md) and enter it in your client. API requests send it as an `Authorization: Bearer <key>` header.

Use BarkVisor's endpoint to route requests across the Home. Connecting directly to Ollama's port `11434` bypasses that routing.

## Related

- [Ollama page](using-ollama.md)
- [API Keys](settings-api-keys.md)
- [Devices](using-devices.md)
