#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="${WAWUBI_BUILD_DIR:-$HOME/dev/build/wa-wubi}"
app="$output/WA 五笔.app"

cd "$root"
"$root/script/build_executable.sh" WAWubi "$app/Contents/MacOS/WAWubi"
mkdir -p "$app/Contents/Resources"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n "${WAWUBI_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $WAWUBI_VERSION" "$app/Contents/Info.plist"
fi
/usr/bin/unzip -oq Resources/WAWubiHan.zip -d "$app/Contents/Resources"
cp Resources/wubi86.dict.yaml Resources/{GPL-3.0,LGPL-3.0}.txt "$app/Contents/Resources/"
cp Resources/{InputIcon.png,InputIcon@2x.png,BrandIcon.png,AppIcon.icns} "$app/Contents/Resources/"
cp -R Resources/zh-Hans.lproj Resources/en.lproj "$app/Contents/Resources/"
if [[ -n "${WAWUBI_SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$WAWUBI_SIGN_IDENTITY" --options runtime --timestamp \
        --entitlements Resources/Release.entitlements "$app" >&2
else
    codesign --force --sign - "$app" >&2
fi
printf '%s\n' "$app"
