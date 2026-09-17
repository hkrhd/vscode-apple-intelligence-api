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
grep -q '性能は実験的' "$temporary/extension/README.md"
codesign --verify "$binary"
