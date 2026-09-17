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
grep -q 'performs poorly' "$temporary/extension/README.md"
grep -q 'オンデバイスモデルは性能が低く' "$temporary/extension/README_JA.md"
[[ -f "$temporary/extension/package.nls.json" ]]
[[ -f "$temporary/extension/package.nls.ja.json" ]]
[[ -f "$temporary/extension/l10n/bundle.l10n.json" ]]
[[ -f "$temporary/extension/l10n/bundle.l10n.ja.json" ]]
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
if (manifest.l10n !== "./l10n") throw new Error("l10nフィールドが不正です");
for (const command of manifest.contributes.commands) {
  if (!/^%.+%$/.test(command.title)) throw new Error(`コマンド名がl10n化されていません: ${command.command}`);
}
const nls = await Bun.file(process.argv[2]).json();
const nlsJa = await Bun.file(process.argv[3]).json();
const bundle = await Bun.file(process.argv[4]).json();
const bundleJa = await Bun.file(process.argv[5]).json();
const raw = await Bun.file(process.argv[1]).text();
const refs = new Set([...raw.matchAll(/%([a-zA-Z0-9_.]+)%/g)].map(m => m[1]));
for (const key of refs) {
  if (!(key in nls)) throw new Error(`package.nls.jsonに不足: ${key}`);
  if (!(key in nlsJa)) throw new Error(`package.nls.ja.jsonに不足: ${key}`);
}
for (const key of Object.keys(bundle)) {
  if (!(key in bundleJa)) throw new Error(`bundle.l10n.ja.jsonに不足: ${key}`);
}
const dist = await Bun.file(process.argv[6]).text();
if (!dist.includes("l10n.t")) throw new Error("distにl10n.tが含まれていません");
' "$temporary/extension/package.json" "$temporary/extension/package.nls.json" "$temporary/extension/package.nls.ja.json" "$temporary/extension/l10n/bundle.l10n.json" "$temporary/extension/l10n/bundle.l10n.ja.json" "$temporary/extension/dist/extension.cjs"
codesign --verify "$binary"
