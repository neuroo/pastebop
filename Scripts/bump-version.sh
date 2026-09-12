#!/usr/bin/env bash
#
# bump-version.sh -- set VERSION to today's date.
#
# Versions are CalVer: 2026.09.11. Running this twice in one day bumps the
# release counter instead, giving 2026.09.11.2.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source Scripts/version.sh

TODAY="$(date +%Y.%m.%d)"
CURRENT="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo "")"

if [[ "$CURRENT" == "$TODAY" ]]; then
	NEXT="$TODAY.2"
elif [[ "$CURRENT" == "$TODAY."* ]]; then
	NEXT="$TODAY.$(( ${CURRENT##*.} + 1 ))"
else
	NEXT="$TODAY"
fi

pastebop_parse_version "$NEXT"
echo "$NEXT" > VERSION

echo "$CURRENT -> $NEXT (CFBundleVersion $BUILD_NUMBER)"
echo
echo "Next:"
# Annotated on purpose: --follow-tags pushes annotated tags only, so a
# lightweight one is created locally and silently never reaches GitHub, and
# the release workflow never runs.
echo "  git commit -am \"Release $NEXT\" && git tag -a -m \"PasteBop $NEXT\" v$NEXT && git push --follow-tags"
