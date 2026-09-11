#!/usr/bin/env bash
#
# version.sh -- derive the bundle version numbers from a CalVer string.
#
# PasteBop versions are dates: 2026.09.11, with an optional fourth component
# for a second release on the same day (2026.09.11.2).
#
# Sourced by the other scripts, or run directly to print what a version resolves
# to:  Scripts/version.sh 2026.09.11
#
# Sets, or prints:
#   MARKETING_VERSION  what people see       e.g. 2026.09.11
#   BUILD_NUMBER       CFBundleVersion       e.g. 2026091101
#
# CFBundleVersion has to increase with every release, so the release counter is
# always present and zero padded: YYYYMMDDNN. Without the padding 2026.09.11.2
# would produce 202609112, which is larger than the next day's 20260912.

pastebop_parse_version() {
	local version="${1:-}"
	[[ -n "$version" ]] || { echo "version.sh: no version given" >&2; return 2; }

	local year month day release
	IFS='.' read -r year month day release <<< "$version"
	release="${release:-1}"

	if ! [[ "$year" =~ ^[0-9]{4}$ && "$month" =~ ^[0-9]{1,2}$ \
		&& "$day" =~ ^[0-9]{1,2}$ && "$release" =~ ^[0-9]{1,2}$ ]]; then
		echo "version.sh: '$version' is not YYYY.MM.DD[.N]" >&2
		return 2
	fi

	# Reject a date that does not exist, so a typo fails at build time rather
	# than shipping. BSD date silently rolls 2026-02-30 forward to 2026-03-02,
	# so compare what it gives back instead of just checking it succeeded.
	local canonical normalized
	canonical="$(printf '%04d-%02d-%02d' "$((10#$year))" "$((10#$month))" "$((10#$day))")"
	normalized="$(date -j -f "%Y-%m-%d" "$canonical" "+%Y-%m-%d" 2>/dev/null || true)"
	if [[ "$normalized" != "$canonical" ]]; then
		echo "version.sh: '$version' is not a real date" >&2
		return 2
	fi

	MARKETING_VERSION="$version"
	BUILD_NUMBER="$(printf '%04d%02d%02d%02d' "$((10#$year))" "$((10#$month))" "$((10#$day))" "$((10#$release))")"
}

# Run directly: print the resolution.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	set -euo pipefail
	cd "$(dirname "${BASH_SOURCE[0]}")/.."
	pastebop_parse_version "${1:-$(tr -d '[:space:]' < VERSION)}"
	echo "MARKETING_VERSION=$MARKETING_VERSION"
	echo "BUILD_NUMBER=$BUILD_NUMBER"
fi
