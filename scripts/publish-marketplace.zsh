#!/usr/bin/env zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
attempt=1
max_attempts=5
until bunx --bun @vscode/vsce publish \
  --packagePath .artifacts/vscode-apple-intelligence-api-darwin-arm64.vsix \
  --skip-duplicate; do
  if (( attempt >= max_attempts )); then
    echo "Marketplaceへの公開に${max_attempts}回失敗しました" >&2
    exit 1
  fi
  echo "公開に失敗しました。60秒後に再試行します (${attempt}/${max_attempts})" >&2
  sleep 60
  (( attempt++ ))
done
