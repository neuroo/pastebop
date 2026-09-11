#!/usr/bin/env bash
#
# make-dmg-layout.sh -- regenerate the Finder window layout for the disk image.
#
# Finder stores window geometry, icon positions and the background picture in a
# .DS_Store, and the background is referenced by an alias that embeds the volume
# path. So the file has to be written onto a real mounted volume, which is what
# this script does: build a scratch read-write image named exactly like the
# release one, write the layout onto it, and copy the result out.
#
# The output (App/dmg/DS_Store) is committed, so Scripts/package.sh just copies
# it and the release pipeline needs no Python at all.
#
# Run from the repository root, after changing the window geometry:
#     Scripts/make-dmg-layout.sh
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Must match Scripts/package.sh, or the alias inside the layout will point at a
# volume that never gets mounted and Finder will fall back to a blank window.
VOLUME_NAME="PasteBop"
# Must match Window in Scripts/make-dmg-background.swift.
WINDOW_WIDTH=560
WINDOW_HEIGHT=400
ICON_SIZE=96
APP_ICON_X=150
APP_ICON_Y=180
APPLICATIONS_ICON_X=410
APPLICATIONS_ICON_Y=180

MOUNT="/Volumes/$VOLUME_NAME"

# Unlike the release scripts this one cannot mount somewhere private: the
# background alias written below embeds the volume path, and it has to be the
# path users will really get. If the name is already taken macOS mounts at
# "/Volumes/PasteBop 1" instead, and the layout would be committed pointing at
# a volume nobody will ever have -- a blank DMG window, noticed only after a
# release. Checked first, before the venv and before the trap is armed, so an
# early exit cannot eject somebody else's disk.
if [[ -e "$MOUNT" ]]; then
	echo "$MOUNT is already mounted; eject it and run this again" >&2
	exit 1
fi

VENV="${PASTEBOP_DSSTORE_VENV:-$(mktemp -d)/venv}"
if [[ ! -x "$VENV/bin/python" ]]; then
	echo "==> Installing ds_store into $VENV"
	python3 -m venv "$VENV"
	"$VENV/bin/pip" install --quiet ds-store mac_alias
fi

STAGE="$(mktemp -d)"
SCRATCH_DMG="$(mktemp -u).dmg"

cleanup() {
	hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
	rm -rf "$STAGE" "$SCRATCH_DMG"
}
trap cleanup EXIT

echo "==> Staging a scratch volume"
mkdir -p "$STAGE/.background"
cp App/dmg/background.tiff "$STAGE/.background/background.tiff"
# Finder needs something at the icon positions or it discards them.
mkdir -p "$STAGE/PasteBop.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" \
	-fs HFS+ -format UDRW -quiet "$SCRATCH_DMG"
hdiutil attach "$SCRATCH_DMG" -nobrowse -quiet
[[ -d "$MOUNT/.background" ]] || {
    echo "the scratch volume did not mount at $MOUNT" >&2
    exit 1
}

echo "==> Writing the layout"
"$VENV/bin/python" - "$MOUNT" <<PYTHON
import sys
from ds_store import DSStore
from mac_alias import Alias

mount = sys.argv[1]
background = f"{mount}/.background/background.tiff"

with DSStore.open(f"{mount}/.DS_Store", "w+") as store:
    # Window: position on screen, then content size. Toolbar and sidebar off so
    # the background is the whole window.
    store["."]["bwsp"] = {
        "WindowBounds": "{{200, 200}, {$WINDOW_WIDTH, $WINDOW_HEIGHT}}",
        "ShowSidebar": False,
        "ShowToolbar": False,
        "ShowStatusBar": False,
        "ShowPathbar": False,
        "SidebarWidth": 0,
    }
    # Icon view: background picture, big icons, no auto-arrange so the
    # positions below survive.
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": Alias.for_file(background).to_bytes(),
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "arrangeBy": "none",
        "showIconPreview": True,
        "showItemInfo": False,
        "labelOnBottom": True,
        "textSize": 12.0,
        "iconSize": float($ICON_SIZE),
        "scrollPositionX": 0.0,
        "scrollPositionY": 0.0,
    }
    store["."]["vSrn"] = ("long", 1)
    store["PasteBop.app"]["Iloc"] = ($APP_ICON_X, $APP_ICON_Y)
    store["Applications"]["Iloc"] = ($APPLICATIONS_ICON_X, $APPLICATIONS_ICON_Y)

print("  wrote .DS_Store")
PYTHON

cp "$MOUNT/.DS_Store" App/dmg/DS_Store
hdiutil detach "$MOUNT" -quiet

echo "==> App/dmg/DS_Store ($(stat -f%z App/dmg/DS_Store) bytes)"
