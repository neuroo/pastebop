#!/usr/bin/env bash
#
# build-app.sh -- assemble PasteBop.app from the SwiftPM build product.
#
# There is no .xcodeproj: the package builds a plain executable and this script
# wraps it in a bundle. That keeps the repository readable and the CI job short.
#
# Usage:
#   Scripts/build-app.sh [--debug] [--arch <arm64|x86_64|universal>] [--sign <identity>]
#
# Apple silicon only by default. Pass --arch universal if an Intel build is
# ever needed again.
#
# Environment:
#   PASTEBOP_BUNDLE_ID   bundle identifier      (default info.neuroo.PasteBop)
#   PASTEBOP_VERSION     marketing version      (default: contents of VERSION)
#   CODESIGN_IDENTITY    signing identity       (default: "-", ad-hoc)
#   PASTEBOP_ICLOUD      1 to compile in iCloud sync (default: off)
#   PASTEBOP_PROFILE     .provisionprofile granting the iCloud container
#                        (default: the newest one in Xcode's profile folder
#                        that names this bundle identifier)
#
# iCloud stays off by default because it cannot work from a source build: the
# container belongs to this project's team, so a build signed with anyone
# else's certificate has no profile that grants it. Turning it on without the
# entitlement is harmless -- the app checks at runtime and falls back to no
# sync -- but it is off unless a release build asks for it.
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

CONFIGURATION="release"
ARCHITECTURE="arm64"
IDENTITY="${CODESIGN_IDENTITY:--}"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--debug) CONFIGURATION="debug"; shift ;;
		--release) CONFIGURATION="release"; shift ;;
		--arch) ARCHITECTURE="$2"; shift 2 ;;
		--sign) IDENTITY="$2"; shift 2 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

BUNDLE_ID="${PASTEBOP_BUNDLE_ID:-info.neuroo.PasteBop}"
source Scripts/version.sh
source Scripts/find-profile.sh --source-only
pastebop_parse_version "${PASTEBOP_VERSION:-$(tr -d '[:space:]' < VERSION)}"
VERSION="$MARKETING_VERSION"
COPYRIGHT="Copyright © $(date +%Y) Romain Gaucher. MIT licensed."
DEPLOYMENT_TARGET="14.0"

DIST="$ROOT/dist"
APP="$DIST/PasteBop.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Building PasteBop $VERSION (build $BUILD_NUMBER) [$CONFIGURATION, $ARCHITECTURE]"

# ---------------------------------------------------------------- executable

SWIFT_FLAGS=(--configuration "$CONFIGURATION" --disable-sandbox)
case "$ARCHITECTURE" in
	universal) SWIFT_FLAGS+=(--arch arm64 --arch x86_64) ;;
	arm64|x86_64) SWIFT_FLAGS+=(--arch "$ARCHITECTURE") ;;
	*) echo "unknown architecture: $ARCHITECTURE" >&2; exit 2 ;;
esac

ENTITLEMENTS=""
PROFILE=""
if [[ "${PASTEBOP_ICLOUD:-0}" == "1" ]]; then
	SWIFT_FLAGS+=(-Xswiftc -DPASTEBOP_ICLOUD)
	echo "==> iCloud sync compiled in"

	# The entitlement is worthless without a profile granting it, and an app
	# signed for a container it cannot claim fails to launch. Refuse rather
	# than produce that.
	if [[ "$IDENTITY" == "-" ]]; then
		echo "PASTEBOP_ICLOUD needs a real signing identity; ad-hoc cannot carry the entitlement." >&2
		exit 2
	fi
	PROFILE="${PASTEBOP_PROFILE:-}"
	if [[ -z "$PROFILE" ]]; then
		PROFILE="$(Scripts/find-profile.sh "$BUNDLE_ID" || true)"
	fi
	if [[ ! -f "$PROFILE" ]]; then
		echo "No provisioning profile for $BUNDLE_ID." >&2
		echo "Create one with iCloud key-value storage, then set PASTEBOP_PROFILE." >&2
		exit 2
	fi
	# Check the profile actually grants the container before signing. A
	# profile for an App ID without the iCloud capability signs fine and
	# fails at launch, which is a much worse place to find out.
	PROFILE_PLIST="$(security cms -D -i "$PROFILE" 2>/dev/null)" || {
		echo "Could not read $PROFILE." >&2; exit 2; }
	if ! printf '%s' "$PROFILE_PLIST" | grep -q "ubiquity-kvstore-identifier"; then
		echo "$PROFILE does not grant iCloud key-value storage." >&2
		echo "Tick iCloud on the $BUNDLE_ID App ID, then regenerate the profile." >&2
		exit 2
	fi
	PROFILE_APP_ID="$(pastebop_profile_app_id "$PROFILE_PLIST" || true)"
	case "${PROFILE_APP_ID#*.}" in
		"$BUNDLE_ID"|'*') ;;
		*)
			echo "$PROFILE is for ${PROFILE_APP_ID#*.}, not $BUNDLE_ID." >&2
			exit 2 ;;
	esac

	ENTITLEMENTS="$ROOT/App/PasteBop.entitlements"
	echo "==> Using profile: $PROFILE"
	echo "    grants iCloud key-value storage for ${PROFILE_APP_ID#*.}"
fi

swift build "${SWIFT_FLAGS[@]}" --product PasteBop
BINARY="$(swift build "${SWIFT_FLAGS[@]}" --product PasteBop --show-bin-path)/PasteBop"
[[ -x "$BINARY" ]] || { echo "no executable at $BINARY" >&2; exit 1; }

# -------------------------------------------------------------------- bundle

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"
cp "$BINARY" "$MACOS/PasteBop"

echo "==> Compiling asset catalog"
xcrun actool App/Assets.xcassets \
	--compile "$RESOURCES" \
	--platform macosx \
	--minimum-deployment-target "$DEPLOYMENT_TARGET" \
	--output-partial-info-plist "$DIST/assets-partial.plist" \
	--output-format human-readable-text \
	> /dev/null

echo "==> Building icon"
iconutil --convert icns App/AppIcon.iconset --output "$RESOURCES/AppIcon.icns"

echo "==> Writing Info.plist"
cp App/Info.plist "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy \
	-c "Set :CFBundleIdentifier $BUNDLE_ID" \
	-c "Set :CFBundleShortVersionString $VERSION" \
	-c "Set :CFBundleVersion $BUILD_NUMBER" \
	-c "Set :NSHumanReadableCopyright $COPYRIGHT" \
	"$CONTENTS/Info.plist" > /dev/null
plutil -lint "$CONTENTS/Info.plist" > /dev/null

printf 'APPL????' > "$CONTENTS/PkgInfo"

if [[ -n "$PROFILE" ]]; then
	cp "$PROFILE" "$CONTENTS/embedded.provisionprofile"
fi

# --------------------------------------------------------------------- sign

# A Developer ID identity gets the hardened runtime and a secure timestamp so
# the result can be notarised. Ad-hoc ("-") supports neither.
echo "==> Signing with identity: $IDENTITY"
if [[ "$IDENTITY" == "-" ]]; then
	codesign --force --sign - "$APP"
else
	SIGN_FLAGS=(--force --options runtime --timestamp --identifier "$BUNDLE_ID")
	[[ -n "$ENTITLEMENTS" ]] && SIGN_FLAGS+=(--entitlements "$ENTITLEMENTS")
	codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

# An entitlement that did not make it into the signature is a silent failure:
# the app launches and simply never syncs.
if [[ -n "$ENTITLEMENTS" ]]; then
	if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "ubiquity-kvstore-identifier"; then
		echo "    iCloud entitlement present"
	else
		echo "the iCloud entitlement is not in the signature" >&2
		exit 1
	fi
fi

rm -f "$DIST/assets-partial.plist"

echo "==> Built $APP"
lipo -archs "$MACOS/PasteBop" | sed 's/^/    architectures: /'
du -sh "$APP" | sed 's/^/    size: /'
