#!/usr/bin/env bash
#
# find-profile.sh -- print the newest provisioning profile for a bundle id.
#
# Xcode stores profiles under a UUID filename, so the only way to tell which
# is which is to decode each one. Prints nothing and fails if there is no
# match, which is what build-app.sh checks for.
#
set -euo pipefail

# Profiles carry the app identifier under the modern key or the legacy one
# depending on when they were issued; a profile that only has the modern key
# looks empty to a reader that checks only the old one.
pastebop_profile_app_id() {
	local plist="$1"
	printf '%s' "$plist" | plutil -extract Entitlements.com\\.apple\\.application-identifier raw - 2>/dev/null \
		|| printf '%s' "$plist" | plutil -extract Entitlements.application-identifier raw - 2>/dev/null \
		|| return 1
}

# Sourced by build-app.sh purely for the helper above.
[[ "${1:-}" == "--source-only" ]] && return 0

BUNDLE_ID="${1:?usage: find-profile.sh <bundle-id>}"
DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
[[ -d "$DIR" ]] || exit 1

BEST=""
BEST_DATE=""
while IFS= read -r -d '' profile; do
	PLIST="$(security cms -D -i "$profile" 2>/dev/null)" || continue
	APP_ID="$(pastebop_profile_app_id "$PLIST")" || continue
	[[ -n "$APP_ID" ]] || continue
	# The identifier is prefixed with the team, and may end in a wildcard.
	case "${APP_ID#*.}" in
		"$BUNDLE_ID"|'*') ;;
		*) continue ;;
	esac
	EXPIRES="$(printf '%s' "$PLIST" | plutil -extract ExpirationDate raw - 2>/dev/null)" || continue
	if [[ -z "$BEST_DATE" || "$EXPIRES" > "$BEST_DATE" ]]; then
		BEST="$profile"
		BEST_DATE="$EXPIRES"
	fi
done < <(find "$DIR" -name '*.provisionprofile' -o -name '*.mobileprovision' -print0 2>/dev/null)

[[ -n "$BEST" ]] || exit 1
printf '%s\n' "$BEST"
