#!/usr/bin/env bash
# Build a clean, self-contained macOS app archive for sharing.
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
derived="${WATER_PACKAGE_DERIVED_DATA:-/tmp/sam-tools-water-package-derived}"
identity="${WATER_CODESIGN_IDENTITY:--}"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

xcodebuild -project "$root/WaterApp.xcodeproj" -scheme Water \
  -configuration Release -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  GOOGLE_HEALTH_CLIENT_ID="${GOOGLE_HEALTH_CLIENT_ID:-}" build

ditto "$derived/Build/Products/Release/Water.app" "$staging/Water.app"
if [ "$identity" = - ]; then
  codesign --force --sign - --identifier com.samtools.water "$staging/Water.app"
else
  codesign --force --options runtime --timestamp --sign "$identity" \
    --identifier com.samtools.water "$staging/Water.app"
fi
codesign --verify --deep --strict "$staging/Water.app"

architectures="$(lipo -archs "$staging/Water.app/Contents/MacOS/Water")"
if [[ " $architectures " != *" arm64 "* || " $architectures " != *" x86_64 "* ]]; then
  echo "Expected a universal arm64/x86_64 build; found: $architectures" >&2
  exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$staging/Water.app/Contents/Info.plist")"
cp "$root/SHARE-README.txt" "$staging/READ-ME-FIRST.txt"
mkdir -p "$root/dist"
archive="$root/dist/Water-${version}-macOS-universal.zip"
ditto -c -k --keepParent --sequesterRsrc "$staging/Water.app" "$archive"
(cd "$staging" && zip -q "$archive" READ-ME-FIRST.txt)

# Verify the sent archive, not just the staging copy.
mkdir "$staging/unpacked"
ditto -x -k "$archive" "$staging/unpacked"
codesign --verify --deep --strict "$staging/unpacked/Water.app"
test -f "$staging/unpacked/READ-ME-FIRST.txt"

echo "Ready to share: $archive"
shasum -a 256 "$archive"
