#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
archive="$1"
app="$2"
: "${WAWUBI_SIGN_IDENTITY:?Developer ID Application signing identity required}"

"$root/script/build_executable.sh" WAInstaller "$app/Contents/MacOS/WAInstaller"
resources="$app/Contents/Resources"
mkdir -p "$resources"
cp "$archive" "$resources/WAWubi.zip"
cp "$root/Resources/"{AppIcon.icns,BrandIcon.png} "$resources/"
cp "$root/Resources/Installer-Info.plist" "$app/Contents/Info.plist"
if [[ -n "${WAWUBI_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $WAWUBI_VERSION" "$app/Contents/Info.plist"
fi
codesign --force --sign "$WAWUBI_SIGN_IDENTITY" --options runtime --timestamp "$app" >&2
codesign --verify --strict --deep "$app"
