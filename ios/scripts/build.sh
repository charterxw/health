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
    # CI passes a rising build number so sideloading tools replace the installed
    # copy, and the commit so Settings shows which build is running.
    stamp=()
    if [[ -n "${PINE_BUILD_NUMBER:-}" ]]; then stamp+=("CURRENT_PROJECT_VERSION=$PINE_BUILD_NUMBER"); fi
    if [[ -n "${PINE_COMMIT:-}" ]]; then stamp+=("PINE_COMMIT=$PINE_COMMIT"); fi
    if [[ "${PINE_APP_GROUP:-}" == "1" ]]; then stamp+=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) PINE_WIDGET'); fi
    xcodebuild -jobs 2 -project "$root/Health.xcodeproj" -scheme Health -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO ${stamp[@]+"${stamp[@]}"} build
    app="$derived/Build/Products/Release-iphoneos/Health.app"
    test -d "$app/PlugIns/WorkoutWidget.appex"
    # Optional: ad-hoc sign with the shared App Group so the sideloading tool can
    # provision it and the home-screen widget can read today's data.
    if [[ "${PINE_APP_GROUP:-}" == "1" ]]; then
      codesign --force --sign - --entitlements "$root/Config/Pine.entitlements" "$app/PlugIns/WorkoutWidget.appex"
      codesign --force --sign - --entitlements "$root/Config/Pine.entitlements" "$app"
    fi
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
