#!/usr/bin/env zsh
set -euo pipefail
project_root="${0:A:h:h}"
archive="$project_root/.artifacts/vscode-apple-intelligence-api-darwin-arm64.vsix"
[[ -f "$archive" ]]
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
unzip -q "$archive" -d "$temporary"
binary="$temporary/extension/bin/apple-intelligence-api"
[[ -x "$binary" ]]
file "$binary" | grep -q 'Mach-O 64-bit executable arm64'
grep -q 'TargetPlatform="darwin-arm64"' "$temporary/extension.vsixmanifest"
grep -q 'オンデバイスモデルは性能が低く' "$temporary/extension/README.md"
[[ ! -d "$temporary/extension/resources/defaults/prompts" ]]
[[ -z "$(find "$temporary/extension" -name '.env' -o -name '.env.*')" ]]
[[ ! -f "$temporary/extension/release.config.mjs" ]]
bun -e '
const manifest = await Bun.file(process.argv[1]).json();
const properties = manifest.contributes.configuration.properties;
const keys = ["inline.instructions", "inline.languageInstructions", "inline.promptTemplate", "inline.languagePromptTemplates", "nes.instructions", "nes.languageInstructions", "nes.promptTemplate", "nes.languagePromptTemplates", "nes.renameHintTemplate", "nes.languageRenameHintTemplates"];
for (const key of keys) {
  const setting = properties[`appleIntelligenceApi.${key}`];
  if (!setting || setting.scope !== "application") throw new Error(`設定が不正です: ${key}`);
}
' "$temporary/extension/package.json"
codesign --verify "$binary"
