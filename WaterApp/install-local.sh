#!/usr/bin/env bash
# Build, sign the whole .app (including Info.plist), and install at a stable path.
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
derived="${WATER_DERIVED_DATA:-/tmp/sam-tools-water-derived}"
destination="$HOME/Applications/Water.app"
identity="${WATER_CODESIGN_IDENTITY:--}" # Use an Apple Development identity if one is available.

xcodebuild -project "$root/WaterApp.xcodeproj" -scheme Water \
  -configuration Debug -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO \
  GOOGLE_HEALTH_CLIENT_ID="${GOOGLE_HEALTH_CLIENT_ID:-}" build

mkdir -p "$HOME/Applications"
staging="$(mktemp -d "$HOME/Applications/.water-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$derived/Build/Products/Debug/Water.app" "$staging/Water.app"
codesign --force --sign "$identity" --identifier com.samtools.water "$staging/Water.app"
codesign --verify --deep --strict "$staging/Water.app"

if [ -e "$destination" ]; then
  installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")"
  if [ "$installed_id" != com.samtools.water ]; then
    echo "Refusing to replace an unrelated app at $destination" >&2
    exit 1
  fi
  rm -rf "$destination"
fi
mv "$staging/Water.app" "$destination"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
echo "Installed $destination"
open "$destination"
