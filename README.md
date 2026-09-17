# Apple Intelligence API for VS Code

> [!WARNING]
> **性能は実験的で、現時点ではかなり微妙です。** Appleのオンデバイスモデルは小さく、複雑なコード補完、広範囲の次編集予測、厳密なMarkdown編集では不正確・不安定な結果を返します。GitHub Copilot等の商用補完を置き換える品質は期待しないでください。提案は必ず確認してから採用してください。

Apple IntelligenceのFoundation Modelsを、localhost限定のOpenAI互換APIとして起動する非公式VS Code拡張です。拡張がサーバーの起動・停止とステータス表示を担当し、補完UIは任意の対応拡張を選べます。プロンプト、入力、生成結果、利用統計を外部へ送信しません。

Apple、GitHub、OpenAIとは提携していません。

## 必要環境

- Apple Silicon搭載Mac
- macOS 26以降
- Apple Intelligenceが有効で、モデルのダウンロードが完了していること
- VS Code 1.110以降

配布物は`darwin-arm64`専用です。Windows、Linux、Intel Mac、VS Code Webでは動作しません。

## できること

| モデル | API | 用途 |
| --- | --- | --- |
| `apple-inline` | `POST /v1/completions` | FIM形式のinline補完 |
| `apple-nes` | `POST /v1/chat/completions` | Copilot Completions形式のNES |

`GET /v1/models`、`GET /health`、JSON応答、SSEに対応します。サーバーは`127.0.0.1:8765`だけで待ち受けます。

`apple-nes`のChat Completions形式はNESのタグ付き編集プロトコル用であり、汎用チャットモデルではありません。

## 重要: 公式GitHub Copilotの制限

**2026年9月現在、VS CodeのBYOK／Custom Endpointで指定できるローカルモデルはChatとutility task向けです。公式GitHub Copilotのinline補完とNESのバックエンドを、このサーバーへ差し替えることはできません。** `GitHub Copilot: Change Completions Model`に表示されるのもGitHub側が提供するモデルです。

参考: [VS Code — AI language models](https://code.visualstudio.com/docs/agent-customization/language-models)

このサーバーを使うには、endpointとモデル名を任意指定できる補完拡張が必要です。現時点で補完とNESの両方にデファクトスタンダードはありません。

## Copilot Completionsで使う

[Copilot Completions](https://marketplace.visualstudio.com/items?itemName=young-triangle.copilot-completions) v1.2.4で動作確認しています。提案APIを使うためVS Code Insidersが必要です。

`settings.json`へ次を追加します。

```json
{
  "cc-completion.ghost.baseUrl": "http://127.0.0.1:8765/v1",
  "cc-completion.ghost.apiKey": "local",
  "cc-completion.ghost.model": "apple-inline",
  "cc-completion.ghost.endpoint": "completions",
  "cc-completion.ghost.promptTemplate": "<|fim_prefix|>{prefix}<|fim_suffix|>{suffix}<|fim_middle|>",
  "cc-completion.ghost.capabilities.limits.max_output_tokens": 256,
  "cc-completion.ghost.capabilities.limits.max_context_window_tokens": 4096,
  "cc-completion.ghost.capabilities.limits.delay": 300,
  "cc-completion.ghost.presencePenalty": 0,
  "cc-completion.ghost.frequencyPenalty": 0,
  "cc-completion.ghost.stream": true,
  "cc-completion.nes.baseUrl": "http://127.0.0.1:8765/v1",
  "cc-completion.nes.apiKey": "local",
  "cc-completion.nes.model": "apple-nes",
  "cc-completion.nes.endpoint": "chat/completions",
  "cc-completion.nes.family": "standard",
  "cc-completion.nes.capabilities.limits.max_output_tokens": 768,
  "cc-completion.nes.capabilities.limits.max_context_window_tokens": 4096,
  "cc-completion.nes.capabilities.supports.thinking": false,
  "cc-completion.nes.presencePenalty": 0,
  "cc-completion.nes.frequencyPenalty": 0
}
```

Insidersの`argv.json`には次を追加し、Insidersを再起動します。

```json
"enable-proposed-api": ["young-triangle.copilot-completions"]
```

Copilot CompletionsのステータスメニューでGHOSTとNESを有効、NCPを無効にします。他のinline/NESプロバイダーと同時に有効にすると提案が競合します。

別のUIを使う場合は、上表のendpoint、モデル名、入力形式を設定してください。OpenAI互換というだけではNES形式まで共通ではないため、UI固有アダプターが必要になる場合があります。

## 状態と設定

ステータスバーは、待機、inline/NES推論中、待ち件数、モデル利用不可、再起動、ポート競合、無効状態を表示します。

ステータスバーをクリックすると有効・無効を切り替えます。選択はユーザー設定`appleIntelligenceApi.enabled`へ保存され、VS Code再起動後も維持されます。既定は有効です。無効時はSwiftサーバーと状態通知を終了してメモリを解放するため、補完・NESは接続エラーになります。再クリックするとサーバーを起動します。

状態表示は250msポーリングではなく`GET /health/events`のSSEを利用します。推論状態の変化時と30秒ごとだけ通知するため、待機中のCPU消費を抑えます。完了・キャンセル・失敗件数はCommand Paletteの`Apple Intelligence API: 状態を表示`で確認できます。

Command Paletteから以下を実行できます。

- `Apple Intelligence API: サーバーを開始／停止／再起動`
- `Apple Intelligence API: 有効／無効を切り替え`
- `Apple Intelligence API: 設定を開く`
- `Apple Intelligence API: プロンプトを表示`
- `Apple Intelligence API: ログを表示`
- `Apple Intelligence API: 設定とプロンプトを初期化`

設定とプロンプトはVS Codeのglobal storageへ初回だけコピーされます。保存後、次のリクエストから反映されます。更新時に編集済みファイルは上書きしません。

Markdownはコードと別のプロンプトを使います。inlineでは見出し・番号の重複を抑え、NESでは全文再生成ではなく最大3件の構造化された検索・置換を検証してから適用します。

## 開発とパッケージ

依存管理にはBunを使います。

```sh
bun install
bun run package
bun run test:package
```

実機Appleモデルを通すE2Eは、起動済みサーバーに対して実行します。

```sh
bun run test:server
```

生成物は`.artifacts/vscode-apple-intelligence-api-darwin-arm64.vsix`です。Marketplaceへ公開する場合はpublisher `hkrhd`を用意し、最新の`vsce`で`darwin-arm64` packageを公開してください。

## ライセンス

MIT。依存パッケージの通知は[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)と配布VSIX内の`dist/licenses`を参照してください。
