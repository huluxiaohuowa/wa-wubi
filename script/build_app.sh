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
/usr/bin/unzip -oq Resources/QingjianEnglishGlossary.zip -d "$app/Contents/Resources"
cp Resources/QingjianEnglishGlossary-NOTICE.txt "$app/Contents/Resources/"
cp Resources/Unicode-CLDR-LICENSE.txt "$app/Contents/Resources/"
cp Resources/wubi86.dict.yaml Resources/{GPL-3.0,LGPL-3.0}.txt "$app/Contents/Resources/"
compiler="$output/compile-mac-lexicon"
xcrun --sdk macosx swiftc -O -module-cache-path "$output/clang" \
    Sources/Core/Lexicon.swift Sources/Core/LexiconDatabase.swift script/compile_mobile_lexicon.swift -o "$compiler"
"$compiler" Resources/wubi86.dict.yaml "$app/Contents/Resources/wubi86.sqlite"
cp Resources/{InputIcon.png,InputIcon@2x.png,BrandIcon.png,AppIcon.icns} "$app/Contents/Resources/"
cp -R Resources/zh-Hans.lproj Resources/en.lproj "$app/Contents/Resources/"
if [[ -n "${WAWUBI_SIGN_IDENTITY:-}" ]]; then
    : "${WAWUBI_PROVISIONING_PROFILE:?Developer ID provisioning profile required}"
    signing="$(mktemp -d "$output/signing.XXXXXX")"
    trap 'rm -rf "$signing"' EXIT
    security cms -D -i "$WAWUBI_PROVISIONING_PROFILE" -o "$signing/profile.plist"
    app_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$signing/profile.plist")"
    team_id="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$signing/profile.plist")"
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
    test "$app_id" = "$team_id.$bundle_id"
    cp "$WAWUBI_PROVISIONING_PROFILE" "$app/Contents/embedded.provisionprofile"
    cp Resources/Release.entitlements "$signing/entitlements.plist"
    /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $app_id" \
        -c "Add :com.apple.developer.team-identifier string $team_id" "$signing/entitlements.plist"
    codesign --force --sign "$WAWUBI_SIGN_IDENTITY" --options runtime --timestamp \
        --entitlements "$signing/entitlements.plist" "$app" >&2
else
    codesign --force --sign - "$app" >&2
fi
printf '%s\n' "$app"
