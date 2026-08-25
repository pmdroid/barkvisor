# Ollama

Ollama is optional. BarkVisor talks to it on each **Device**. Completions go through **Home** `:7777/v1`, not Device `:11434`.

The **Ollama** nav item stays visible for admin and inference even when no Device can reach Ollama.

## Install (when Ollama is down)

The page shows a multi-step panel and **Recheck**. Commands match the in-app copy. AgentBox and Mac mini are not install targets.

**macOS**

```sh
brew install ollama
brew services start ollama
```

**Linux** — install the distro package, or see [ollama.com/download](https://ollama.com/download).

When Ollama comes up, the page switches to the model list without a full reload.

Live Device stats (CPU, memory, GPU busy percent) are on Device detail, not this page. Occupancy / passthrough is a different number.

## Catalog vs library search

**Filter catalog** matches names already pulled on the Home. That is not a library search.

**Search the Ollama library** looks up names through Home (`GET /api/home/ollama/library/search?q=`). The daemon fetches `https://ollama.com/api/tags` (allowlisted) and filters locally. Empty query, upstream down, and no matches are explicit states. Each result has **Download**, which is the existing pull (`POST /home/ollama/pull`).

**Pull by name** stays as a fallback when you already know the slug.

Pull still needs a **Device** for where the weights land (sidebar Device if one is selected, otherwise any reachable Device).

## Start and Stop

A pulled model can only run on a Device that already has it.

- Sidebar scoped to one Device that has the model: **Start** runs there. No picker.
- Sidebar **All**, one reachable location: **Start** runs there. No picker.
- Several reachable Devices have it: picker lists only those Devices. Always a real Device, never “Any reachable Device.”
- No reachable location: Start is disabled (not on this Device, or only on unreachable Devices).

**Stop** uses the Device that is running the model and does not ask.

## Use this API

The card is collapsed until opened.

OpenAI-compatible completions on this Home:

`http://<home>:7777/v1/chat/completions`

Send `Authorization: Bearer` with an inference key. That is **not** Device `:11434`.

From inside a Workload, Device Ollama is `http://10.0.2.2:11434/v1` (guestfwd).

## Related

- [Product terminology](product-terminology.md)
- [Home and pairing](home-and-pairing.md)
- [Changelog](changelog.md)
