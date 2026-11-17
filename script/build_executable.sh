#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
product="$1"
binary="$2"
output="${WAWUBI_BUILD_DIR:-$HOME/dev/build/wa-wubi}"
configuration="${WAWUBI_CONFIGURATION:-debug}"

mkdir -p "$output/tmp" "$output/clang" "$(dirname "$binary")"
export TMPDIR="$output/tmp"
export CLANG_MODULE_CACHE_PATH="$output/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$output/clang"

if [[ "${WAWUBI_UNIVERSAL:-0}" == 1 ]]; then
    bins=()
    for arch in arm64 x86_64; do
        options=(--arch "$arch" --configuration "$configuration" --scratch-path "$output/swift-$arch")
        swift build "${options[@]}" --product "$product" >&2
        bin="$(swift build "${options[@]}" --show-bin-path)"
        bins+=("$bin/$product")
    done
    xcrun lipo -create "${bins[@]}" -output "$binary"
else
    options=(--configuration "$configuration" --scratch-path "$output/swift")
    swift build "${options[@]}" --product "$product" >&2
    bin="$(swift build "${options[@]}" --show-bin-path)"
    cp "$bin/$product" "$binary"
fi
