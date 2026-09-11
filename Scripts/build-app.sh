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

# --------------------------------------------------------------------- sign

# A Developer ID identity gets the hardened runtime and a secure timestamp so
# the result can be notarised. Ad-hoc ("-") supports neither.
echo "==> Signing with identity: $IDENTITY"
if [[ "$IDENTITY" == "-" ]]; then
	codesign --force --sign - "$APP"
else
	codesign --force --options runtime --timestamp \
		--identifier "$BUNDLE_ID" --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

rm -f "$DIST/assets-partial.plist"

echo "==> Built $APP"
lipo -archs "$MACOS/PasteBop" | sed 's/^/    architectures: /'
du -sh "$APP" | sed 's/^/    size: /'
