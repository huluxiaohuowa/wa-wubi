#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${WAWUBI_APP_PATH:-}"
if [[ -z "$app" ]]; then app="$("$root/script/build_app.sh")"; fi
destination="$HOME/Library/Input Methods/WA 五笔.app"
pkill -x WAWubi >/dev/null 2>&1 || true
mkdir -p "$(dirname "$destination")"
if [[ -d "$destination" ]]; then
    rsync -a --delete "$app/" "$destination/"
else
    ditto "$app" "$destination"
fi
build_dir="${WAWUBI_BUILD_DIR:-$HOME/dev/build/wa-wubi}"
TMPDIR="$build_dir/tmp" SWIFT_MODULE_CACHE_PATH="$build_dir/clang" swift "$root/script/register.swift" "$@"
