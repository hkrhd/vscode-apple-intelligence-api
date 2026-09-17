[日本語](README_JA.md)

# Apple Intelligence API for VS Code

> [!WARNING]
> **As of Sep 2026, Apple's on-device model performs poorly and has limited practical use.**

An unofficial VS Code extension that launches Apple Intelligence on-device models as a localhost-only OpenAI-compatible API HTTP server.
Nothing is sent externally.

## Requirements

- Mac with Apple Silicon
- macOS 26 or later

## What it can do

| Model          | API                         | Purpose                           |
| -------------- | --------------------------- | --------------------------------- |
| `apple-inline` | `POST /v1/completions`      | FIM-style inline completion       |
| `apple-nes`    | `POST /v1/chat/completions` | Copilot Completions-style NES     |

Supports `GET /v1/models`, `GET /health`, JSON responses, and SSE. The server listens only on `127.0.0.1:8765`.

## Important: official GitHub Copilot limitation

To use this server, you need a completion extension that lets you specify an arbitrary endpoint and model name. There is currently no de facto standard covering both completion and NES.

**As of September 2026, local models selectable via VS Code BYOK / Custom Endpoint are for Chat and utility tasks. The official GitHub Copilot inline completion and NES backends cannot be replaced with this server.** The models shown in `GitHub Copilot: Change Completions Model` are provided by GitHub.

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

- `appleIntelligenceApi.inline.instructions` / `appleIntelligenceApi.nes.instructions`: default instruction prompts
- `appleIntelligenceApi.inline.languageInstructions` / `appleIntelligenceApi.nes.languageInstructions`: per-language-ID instruction prompts
- `appleIntelligenceApi.inline.promptTemplate` / `appleIntelligenceApi.nes.promptTemplate`: input templates
- `appleIntelligenceApi.inline.languagePromptTemplates` / `appleIntelligenceApi.nes.languagePromptTemplates`: per-language-ID input templates
- `appleIntelligenceApi.nes.renameHintTemplate` / `appleIntelligenceApi.nes.languageRenameHintTemplates`: rename hint templates

### Placeholders

- Inline templates: `{before}` and `{after}`, once each
- NES templates: `{recentEdits}`, `{beforeTarget}`, `{afterTarget}`, and `{target}`, once each
- Rename hint templates: `{old}` and `{new}`, once each
- Invalid settings are shown in a notification and the status bar, and completion APIs return `invalid_prompt_configuration`.

## License

MIT. For dependency notices, see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and `dist/licenses` inside the distributed VSIX.
