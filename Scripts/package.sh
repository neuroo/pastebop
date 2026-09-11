#!/usr/bin/env bash
#
# package.sh -- wrap dist/PasteBop.app into a .dmg and a .zip.
#
# The .dmg is for people: it opens to a laid-out window with the app on the
# left and an Applications alias on the right, so installing is one drag. The
# .zip is for Homebrew casks and scripted installs.
#
# The window layout lives in App/dmg/DS_Store and the background in
# App/dmg/background.tiff (a multi-resolution TIFF so Retina displays get the
# 2x representation), both committed. Regenerate them with
# Scripts/make-dmg-layout.sh and Scripts/make-dmg-background.swift; this script
# only copies them, so the release pipeline needs nothing beyond hdiutil.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source Scripts/version.sh
pastebop_parse_version "${PASTEBOP_VERSION:-$(tr -d '[:space:]' < VERSION)}"

DIST="$PWD/dist"
APP="$DIST/PasteBop.app"
[[ -d "$APP" ]] || { echo "no app at $APP; run Scripts/build-app.sh first" >&2; exit 1; }

# The layout's background alias embeds this exact volume path, so the name has
# to stay fixed. Putting the version in it would blank the window.
VOLUME_NAME="PasteBop"
DMG="$DIST/PasteBop-$MARKETING_VERSION.dmg"
ZIP="$DIST/PasteBop-$MARKETING_VERSION.zip"

STAGE="$(mktemp -d)"
SCRATCH="$STAGE.rw.dmg"
# Mounted on a private path, not /Volumes/PasteBop. Something else can already
# own that name -- a volume an earlier run failed to eject, or a copy of the
# release sitting open in Finder -- and macOS then quietly mounts this image at
# "/Volumes/PasteBop 1" while every command below keeps talking to the other
# disk. The name recorded inside the image is still PasteBop, which is all the
# committed layout depends on.
MOUNT="$STAGE.mount"
cleanup() {
	hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
	rm -rf "$STAGE" "$MOUNT" "$SCRATCH"
}
trap cleanup EXIT

echo "==> Staging"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp App/dmg/background.tiff "$STAGE/.background/background.tiff"
cp App/dmg/DS_Store "$STAGE/.DS_Store"
# Gives the mounted volume the app's own icon instead of a blank disk.
cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

echo "==> Building $(basename "$DMG")"
rm -f "$DMG"
# Built read-write first: the custom-icon flag is a Finder attribute on the
# volume root, which only exists once the image is mounted.
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" \
	-fs HFS+ -format UDRW -quiet "$SCRATCH"
mkdir -p "$MOUNT"
hdiutil attach "$SCRATCH" -nobrowse -quiet -mountpoint "$MOUNT"
# Cosmetic only, so a toolchain without SetFile still produces a valid image.
if command -v SetFile > /dev/null; then
	SetFile -a C "$MOUNT"
else
	echo "    note: SetFile not found, volume keeps the generic disk icon" >&2
fi
# Has to be detached before converting, or the copy can catch a half-written
# volume.
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$SCRATCH" -format UDZO -imagekey zlib-level=9 -quiet -o "$DMG"
rm -f "$SCRATCH"

echo "==> Building $(basename "$ZIP")"
rm -f "$ZIP"
# ditto keeps the signature and resource forks intact; zip(1) does not.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Packaged"
shasum -a 256 "$DMG" "$ZIP" | sed 's/^/    /'
ls -lh "$DMG" "$ZIP" | awk '{print "    " $9 "  " $5}'
