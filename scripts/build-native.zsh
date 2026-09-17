#!/usr/bin/env zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
export CLANG_MODULE_CACHE_PATH="$project_root/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_root/.build/module-cache"
swift build -c release --product apple-intelligence-api
mkdir -p bin
cp .build/release/apple-intelligence-api bin/apple-intelligence-api
chmod 755 bin/apple-intelligence-api
codesign --force --sign - bin/apple-intelligence-api
