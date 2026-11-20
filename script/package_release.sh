#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
build="${WAWUBI_BUILD_DIR:-$HOME/dev/build/wa-wubi/release}"
export WAWUBI_BUILD_DIR="$build"
export WAWUBI_CONFIGURATION=release
export WAWUBI_UNIVERSAL=1
export WAWUBI_VERSION="${WAWUBI_VERSION:-0.1.35}"
: "${WAWUBI_SIGN_IDENTITY:?Developer ID Application signing identity required}"
: "${WAWUBI_NOTARY_KEY_FILE:?Notary API private key file required}"
: "${WAWUBI_NOTARY_KEY_ID:?Notary API key ID required}"
: "${WAWUBI_NOTARY_ISSUER:?Notary API issuer required}"
mkdir -p "$build/tmp"
export TMPDIR="$build/tmp"

app="$("$root/script/build_app.sh")"
codesign --verify --strict --deep "$app"
notarize() {
    local result
    result="$(xcrun notarytool submit "$1" --key "$WAWUBI_NOTARY_KEY_FILE" \
        --key-id "$WAWUBI_NOTARY_KEY_ID" --issuer "$WAWUBI_NOTARY_ISSUER" \
        --wait --timeout 25m --output-format json)"
    if ! printf '%s' "$result" | python3 -c 'import json,sys; r=json.load(sys.stdin); print("Notarization:",r.get("status"),r.get("id")); sys.exit(r.get("status") != "Accepted")' >&2; then
        return 1
    fi
}
zip="$build/WAWubi-notary.zip"
ditto -c -k --keepParent "$app" "$zip"
notarize "$zip"
xcrun stapler staple "$app" >&2
xcrun stapler validate "$app" >&2

stage="$(mktemp -d "$build/tmp/disk.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
payload="$build/WAWubi-payload.zip"
ditto -c -k --keepParent "$app" "$payload"
installer="$stage/安装 WA 五笔.app"
"$root/script/build_installer.sh" "$payload" "$installer"
installer_zip="$build/WAInstaller-notary.zip"
ditto -c -k --keepParent "$installer" "$installer_zip"
notarize "$installer_zip"
xcrun stapler staple "$installer" >&2
xcrun stapler validate "$installer" >&2
cp "$root/Resources/安装说明.txt" "$stage/"
dmg="$build/WA-Wubi-$WAWUBI_VERSION.dmg"
hdiutil create -ov -volname "WA 五笔" -srcfolder "$stage" -format UDZO "$dmg" >&2
codesign --force --sign "$WAWUBI_SIGN_IDENTITY" --identifier top.fuluwa.WAWubiInstaller.Image --timestamp "$dmg" >&2
notarize "$dmg"
xcrun stapler staple "$dmg" >&2
xcrun stapler validate "$dmg" >&2
printf '%s\n' "$dmg"
