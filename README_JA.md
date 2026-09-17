[English](README.md)

# Apple Intelligence API for VS Code

> [!WARNING]
> **26/09時点でappleのオンデバイスモデルは性能が低く，実用性は低い．**

Apple Intelligenceのオンデバイスモデルを、localhost限定のOpenAI互換API HTTPサーバーとして起動する非公式VSCode拡張です。
外部へ何も送信しません。

## 必要環境

- Apple Silicon搭載Mac
- macOS 26以降

## できること

| モデル         | API                         | 用途                         |
| -------------- | --------------------------- | ---------------------------- |
| `apple-inline` | `POST /v1/completions`      | FIM形式のinline補完          |
| `apple-nes`    | `POST /v1/chat/completions` | Copilot Completions形式のNES |

`GET /v1/models`、`GET /health`、JSON応答、SSEに対応します。サーバーは`127.0.0.1:8765`だけで待ち受けます。

## 重要: 公式GitHub Copilotの制限

このサーバーを使うには、endpointとモデル名を任意指定できる補完拡張が必要です。現時点で補完とNESの両方にデファクトスタンダードはありません。

**2026年9月現在、VS CodeのBYOK／Custom Endpointで指定できるローカルモデルはChatとutility task向けです。公式GitHub Copilotのinline補完とNESのバックエンドを、このサーバーへ差し替えることはできません。** `GitHub Copilot: Change Completions Model`に表示されるのもGitHub側が提供するモデルです。

## Copilot Completionsで使う

[Copilot Completions](https://marketplace.visualstudio.com/items?itemName=young-triangle.copilot-completions) v1.2.4で動作確認しています。

`settings.json`へ次を追加します。

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

Copilot CompletionsのステータスメニューでGHOSTとNESを有効、NCPを無効にします。他のinline/NESプロバイダーと同時に有効にすると提案が競合します。

## プロンプト設定

- `appleIntelligenceApi.inline.instructions` / `appleIntelligenceApi.nes.instructions`: 通常の指示プロンプト
- `appleIntelligenceApi.inline.languageInstructions` / `appleIntelligenceApi.nes.languageInstructions`: 言語ID別の指示プロンプト
- `appleIntelligenceApi.inline.promptTemplate` / `appleIntelligenceApi.nes.promptTemplate`: 入力テンプレート
- `appleIntelligenceApi.inline.languagePromptTemplates` / `appleIntelligenceApi.nes.languagePromptTemplates`: 言語ID別の入力テンプレート
- `appleIntelligenceApi.nes.renameHintTemplate` / `appleIntelligenceApi.nes.languageRenameHintTemplates`: rename指示テンプレート

### プレースホルダー

- inlineテンプレート: `{before}`と`{after}`を各1回
- NESテンプレート: `{recentEdits}`、`{beforeTarget}`、`{afterTarget}`、`{target}`を各1回
- rename指示テンプレート: `{old}`と`{new}`を各1回
- 不正な設定は通知とステータスバーに表示され、補完APIは`invalid_prompt_configuration`を返します。

## ライセンス

MIT。依存パッケージの通知は[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)と配布VSIX内の`dist/licenses`を参照してください。
