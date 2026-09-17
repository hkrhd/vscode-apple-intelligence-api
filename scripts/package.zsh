#!/usr/bin/env zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
bun run build
zsh scripts/collect-licenses.zsh
mkdir -p .artifacts
bunx --bun @vscode/vsce package --no-dependencies --target darwin-arm64 --out .artifacts/vscode-apple-intelligence-api-darwin-arm64.vsix
