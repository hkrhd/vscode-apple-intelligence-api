#!/usr/bin/env zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
bun pm version "$1" --no-git-tag-version --allow-same-version
bun run package
bun run test:package
