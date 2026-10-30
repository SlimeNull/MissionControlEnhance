#!/usr/bin/env bash
# Builds build/MissionControlEnhance.app and signs it.
#
#   CONFIG        release (default) or debug
#   ARCH          arm64 or x86_64; defaults to the host architecture
#   VERSION       overrides CFBundleShortVersionString, e.g. 1.0.0
#   SIGN_IDENTITY codesigning identity; "-" for ad-hoc. Defaults to the first development
#                 identity in the keychain, which keeps the Accessibility grant valid across
#                 rebuilds, or ad-hoc when there is none (as on CI).
#
# An ad-hoc signature over the complete bundle is what lets a downloaded copy run after the user
# clicks "Open Anyway" in Privacy & Security. Without one (or with a bundle modified after
# signing) macOS reports the app as damaged instead and offers no way to open it.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
ARCH="${ARCH:-$(uname -m)}"
swift build -c "$CONFIG" --arch "$ARCH"
BIN="$(swift build -c "$CONFIG" --arch "$ARCH" --show-bin-path)/MissionControlEnhance"

APP="build/MissionControlEnhance.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MissionControlEnhance"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi

# Finder info and other extended attributes make codesign refuse the bundle.
xattr -cr "$APP"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application|Apple Development/ { print $2; exit }')}"
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP for $ARCH (signed with: ${IDENTITY:-ad-hoc})"
