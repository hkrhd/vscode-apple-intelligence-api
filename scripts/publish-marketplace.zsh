#!/usr/bin/env zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
bunx --bun @vscode/vsce publish \
  --packagePath .artifacts/vscode-apple-intelligence-api-darwin-arm64.vsix \
  --skip-duplicate
