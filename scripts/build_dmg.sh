#!/usr/bin/env bash
# Builds the app (see build.sh for the environment variables it takes) and packs it into
# build/MissionControlEnhance-<version>-<arch>.dmg, with an Applications shortcut to drag onto.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${ARCH:-$(uname -m)}"
export ARCH
scripts/build.sh

APP="build/MissionControlEnhance.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="build/MissionControlEnhance-$VERSION-$ARCH.dmg"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
# ditto keeps the bundle byte-for-byte, so its signature stays valid.
ditto "$APP" "$STAGING/MissionControlEnhance.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "MissionControlEnhance" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Built $DMG"
