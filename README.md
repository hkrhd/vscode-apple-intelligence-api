[日本語](README_JA.md)

# Apple Intelligence API for VS Code

> [!WARNING]
> **As of Sep 2026, Apple's on-device model performs poorly and has limited practical use.**

An unofficial VS Code extension that exposes Apple Intelligence Foundation Models as a localhost-only OpenAI-compatible API.
Prompts, inputs, generations, and usage statistics are never sent externally.

## Requirements

- Mac with Apple Silicon
- macOS 26 or later
- Apple Intelligence enabled with the model download completed
- VS Code 1.110 or later

## What it can do

| Model          | API                         | Purpose                           |
| -------------- | --------------------------- | --------------------------------- |
| `apple-inline` | `POST /v1/completions`      | FIM-style inline completion       |
| `apple-nes`    | `POST /v1/chat/completions` | Copilot Completions-style NES     |

Supports `GET /v1/models`, `GET /health`, JSON responses, and SSE. The server listens only on `127.0.0.1:8765`.

The `apple-nes` Chat Completions format is for the NES tagged-edit protocol, not a general-purpose chat model.

## Important: official GitHub Copilot limitation

**As of September 2026, local models selectable via VS Code BYOK / Custom Endpoint are for Chat and utility tasks. The official GitHub Copilot inline completion and NES backends cannot be replaced with this server.** The models shown in `GitHub Copilot: Change Completions Model` are provided by GitHub.

See: [VS Code — AI language models](https://code.visualstudio.com/docs/agent-customization/language-models)

To use this server, you need a completion extension that lets you specify an arbitrary endpoint and model name. There is currently no de facto standard covering both completion and NES.

## Using with Copilot Completions

Verified with [Copilot Completions](https://marketplace.visualstudio.com/items?itemName=young-triangle.copilot-completions) v1.2.4.

Add the following to `settings.json`:

```json
{
  "cc-completion.ghost.baseUrl": "http://127.0.0.1:8765/v1",
  "cc-completion.ghost.model": "apple-inline",
  "cc-completion.ghost.presencePenalty": 0,
  "cc-completion.ghost.frequencyPenalty": 0,
  "cc-completion.nes.baseUrl": "http://127.0.0.1:8765/v1",
  "cc-completion.nes.model": "apple-nes",
  "cc-completion.nes.presencePenalty": 0,
  "cc-completion.nes.frequencyPenalty": 0
}
```

In the Copilot Completions status menu, enable GHOST and NES and disable NCP. Enabling other inline/NES providers at the same time causes competing suggestions.

## Prompt settings

From the Command Palette, `Apple Intelligence API: Open Prompt Settings` lets you change all prompts passed to the model as user settings. Settings are shared across all VS Code windows. After saving, changes apply from the next request without a restart.

- `appleIntelligenceApi.inline.instructions` / `appleIntelligenceApi.nes.instructions`: default instruction prompts
- `appleIntelligenceApi.inline.languageInstructions` / `appleIntelligenceApi.nes.languageInstructions`: per-language-ID instruction prompts
- `appleIntelligenceApi.inline.promptTemplate` / `appleIntelligenceApi.nes.promptTemplate`: input templates
- `appleIntelligenceApi.inline.languagePromptTemplates` / `appleIntelligenceApi.nes.languagePromptTemplates`: per-language-ID input templates
- `appleIntelligenceApi.nes.renameHintTemplate` / `appleIntelligenceApi.nes.languageRenameHintTemplates`: rename hint templates

When a per-language setting exists, it fully replaces the default setting. Inline templates must contain `{before}` and `{after}` once each, NES templates must contain `{recentEdits}`, `{beforeTarget}`, `{afterTarget}`, and `{target}` once each, and rename hints must contain `{old}` and `{new}` once each. Invalid settings are shown in a notification and the status bar, and completion APIs return `invalid_prompt_configuration`.

`prompts/*.md` in global storage edited with older versions is no longer referenced. Prompt bodies are still never sent externally.

## License

MIT. For dependency notices, see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and `dist/licenses` inside the distributed VSIX.
