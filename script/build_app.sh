#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="${WAWUBI_BUILD_DIR:-$HOME/dev/build/wa-wubi}"
configuration="${WAWUBI_CONFIGURATION:-debug}"
app="$output/WA 五笔.app"

mkdir -p "$output/tmp" "$output/clang"
export TMPDIR="$output/tmp"
export CLANG_MODULE_CACHE_PATH="$output/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$output/clang"
cd "$root"

if [[ "${WAWUBI_UNIVERSAL:-0}" == 1 ]]; then
    for arch in arm64 x86_64; do
        swift build --arch "$arch" --configuration "$configuration" --scratch-path "$output/swift-$arch" --product WAWubi >&2
    done
else
    swift build --configuration "$configuration" --scratch-path "$output/swift" --product WAWubi >&2
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
if [[ "${WAWUBI_UNIVERSAL:-0}" == 1 ]]; then
    bins=()
    for arch in arm64 x86_64; do
        path="$(swift build --arch "$arch" --configuration "$configuration" --scratch-path "$output/swift-$arch" --show-bin-path)"
        bins+=("$path/WAWubi")
    done
    xcrun lipo -create "${bins[@]}" -output "$app/Contents/MacOS/WAWubi"
else
    bin="$(swift build --configuration "$configuration" --scratch-path "$output/swift" --show-bin-path)"
    cp "$bin/WAWubi" "$app/Contents/MacOS/WAWubi"
fi
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n "${WAWUBI_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $WAWUBI_VERSION" "$app/Contents/Info.plist"
fi
cp Resources/wubi86.dict.yaml Resources/{GPL-3.0,LGPL-3.0}.txt "$app/Contents/Resources/"
cp Resources/InputIcon.png "$app/Contents/Resources/"
if [[ -n "${WAWUBI_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$WAWUBI_SIGN_IDENTITY" --options runtime --timestamp \
        --entitlements Resources/Release.entitlements "$app" >&2
else
    codesign --force --sign - "$app" >&2
fi
printf '%s\n' "$app"
