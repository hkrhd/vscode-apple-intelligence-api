#!/usr/bin/env zsh
set -euo pipefail
project_root="${0:A:h:h}"
license_root="$project_root/dist/licenses"
rm -rf "$license_root"
mkdir -p "$license_root"
for checkout in "$project_root"/.build/checkouts/*; do
  [[ -d "$checkout" ]] || continue
  dependency="${checkout:t}"
  mkdir -p "$license_root/$dependency"
  found=false
  for notice in "$checkout"/(LICENSE*|NOTICE*)(N); do
    cp "$notice" "$license_root/$dependency/${notice:t}"
    found=true
  done
  if [[ "$found" == false ]]; then
    rmdir "$license_root/$dependency"
  fi
done
