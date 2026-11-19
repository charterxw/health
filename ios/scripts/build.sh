#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcrun --find xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo 'Full Xcode is required. Install Xcode, launch it once, and select it in Xcode > Settings > Locations > Command Line Tools.' >&2
  exit 2
fi
sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
if test "${sdk_version%%.*}" -lt 26; then
  echo 'This revision uses Liquid Glass SDK APIs. Install Xcode 26 or newer; use Xcode 27 for iOS 27 builds.' >&2
  exit 2
fi
mode="${1:---simulator}"
derived="$root/build/DerivedData"
if [[ "$mode" == --unsigned-ipa ]]; then derived="$root/build/DerivedData-Device"; fi
mkdir -p "$root/build"
case "$mode" in
  --simulator)
    xcodebuild -jobs 2 -project "$root/Health.xcodeproj" -scheme Health -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build
    ;;
  --unsigned-ipa)
    xcodebuild -jobs 2 -project "$root/Health.xcodeproj" -scheme Health -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO build
    app="$derived/Build/Products/Release-iphoneos/Health.app"
    test -d "$app/PlugIns/WorkoutWidget.appex"
    stage="$(mktemp -d "$root/build/package.XXXXXX")"
    trap 'rm -rf "$stage"' EXIT
    mkdir "$stage/Payload"
    ditto --norsrc "$app" "$stage/Payload/Health.app"
    (cd "$stage" && ditto -c -k --norsrc --keepParent Payload Pine-unsigned.ipa)
    mv "$stage/Pine-unsigned.ipa" "$root/build/Pine-unsigned.ipa"
    echo "Unsigned IPA for SideStore: $root/build/Pine-unsigned.ipa"
    ;;
  *) echo 'Usage: build.sh [--simulator | --unsigned-ipa]' >&2; exit 2 ;;
esac
