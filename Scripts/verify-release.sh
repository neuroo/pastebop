#!/usr/bin/env bash
#
# verify-release.sh -- check the artifacts before they are published.
#
# Run after Scripts/package.sh, and always before creating a GitHub release.
# Once releases are immutable a bad asset cannot be replaced, only superseded
# by a new version, so everything worth checking is checked here.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source Scripts/version.sh
pastebop_parse_version "${PASTEBOP_VERSION:-$(tr -d '[:space:]' < VERSION)}"

DMG="dist/PasteBop-$MARKETING_VERSION.dmg"
ZIP="dist/PasteBop-$MARKETING_VERSION.zip"
FAILURES=0

fail() { echo "    FAIL  $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "    ok    $*"; }

echo "==> Artifacts"
for artifact in "$DMG" "$ZIP"; do
	if [[ ! -f "$artifact" ]]; then
		fail "$artifact is missing"
		continue
	fi
	# A truncated upload or a failed build can leave a plausible-looking but
	# tiny file behind.
	size=$(stat -f%z "$artifact")
	if (( size < 500000 )); then
		fail "$(basename "$artifact") is only $size bytes"
	else
		pass "$(basename "$artifact") ($((size / 1024)) KB)"
	fi
done
(( FAILURES == 0 )) || { echo "==> $FAILURES problem(s)" >&2; exit 1; }

echo "==> Zip archive"
if unzip -tq "$ZIP" > /dev/null 2>&1; then
	pass "archive integrity"
else
	fail "$(basename "$ZIP") does not pass unzip -t"
fi
# -Z1 lists bare paths one per line; -x demands a whole-line match.
# Not a pipeline into grep -q: grep exits on the first match, unzip takes
# SIGPIPE, and pipefail then reports the whole check as failed.
ZIP_ENTRIES="$(unzip -Z1 "$ZIP" 2>/dev/null || true)"
if grep -qxF "PasteBop.app/Contents/MacOS/PasteBop" <<< "$ZIP_ENTRIES"; then
	pass "contains the executable"
else
	fail "no PasteBop executable inside the archive"
fi

echo "==> Disk image"
# Mounted on a private path, not /Volumes/PasteBop. If anything already owns
# that name -- a volume an earlier run failed to eject, a copy of the release
# open in Finder -- macOS mounts this one at "/Volumes/PasteBop 1" and every
# check below would quietly pass or fail against the wrong disk.
MOUNT_ROOT="$(mktemp -d)"
VOLUME="$MOUNT_ROOT/PasteBop"
mkdir -p "$VOLUME"
trap 'hdiutil detach "$VOLUME" -quiet 2>/dev/null || true; rm -rf "$MOUNT_ROOT"' EXIT
hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$VOLUME"

[[ -d "$VOLUME/PasteBop.app" ]] && pass "contains PasteBop.app" || fail "no PasteBop.app"
[[ "$(readlink "$VOLUME/Applications" || true)" == "/Applications" ]] \
	&& pass "Applications alias points at /Applications" \
	|| fail "Applications alias is wrong or missing"
[[ -f "$VOLUME/.DS_Store" ]] && pass "window layout present" || fail "no window layout"
[[ -f "$VOLUME/.background/background.tiff" ]] \
	&& pass "background present" || fail "no background"

echo "==> App"
if codesign --verify --strict "$VOLUME/PasteBop.app" 2>/dev/null; then
	pass "signature valid"
else
	fail "signature invalid"
fi

# Each reader falls back to a placeholder rather than being allowed to abort
# the run under set -e: a damaged bundle should come out as a FAIL line and a
# closing count, not a bare tool error two thirds of the way down.
PLIST="$VOLUME/PasteBop.app/Contents/Info.plist"
SHIPPED=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || echo "unreadable")
[[ "$SHIPPED" == "$MARKETING_VERSION" ]] \
	&& pass "version $SHIPPED" \
	|| fail "bundle says $SHIPPED, expected $MARKETING_VERSION"

BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST" 2>/dev/null || echo "unreadable")
[[ "$BUILD" == "$BUILD_NUMBER" ]] \
	&& pass "build $BUILD" \
	|| fail "bundle build is $BUILD, expected $BUILD_NUMBER"

ARCHS=$(lipo -archs "$VOLUME/PasteBop.app/Contents/MacOS/PasteBop" 2>/dev/null || echo "unreadable")
[[ "$ARCHS" == "arm64" ]] && pass "arm64" || fail "architectures are '$ARCHS'"

[[ -x "$VOLUME/PasteBop.app/Contents/MacOS/PasteBop" ]] \
	&& pass "executable bit set" || fail "not executable"
[[ -f "$VOLUME/PasteBop.app/Contents/Resources/Assets.car" ]] \
	&& pass "asset catalog compiled" || fail "no Assets.car"
[[ -f "$VOLUME/PasteBop.app/Contents/Resources/AppIcon.icns" ]] \
	&& pass "icon present" || fail "no AppIcon.icns"

# The Services entry is declared in Info.plist and dispatched by name. A
# rename on one side without the other silently removes the menu item.
SERVICE=$(/usr/libexec/PlistBuddy -c "Print :NSServices:0:NSMessage" "$PLIST" 2>/dev/null \
	|| echo "missing")
[[ "$SERVICE" == "selectBop" ]] \
	&& pass "SelectBop service declared" \
	|| fail "NSServices message is '$SERVICE', expected selectBop"

echo
if (( FAILURES > 0 )); then
	echo "==> $FAILURES problem(s); do not publish" >&2
	exit 1
fi
echo "==> Ready to publish PasteBop $MARKETING_VERSION"
