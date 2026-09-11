#!/usr/bin/env bash
#
# make-demo.sh -- regenerate the animated demo in the README.
#
# The renderer needs the real rewrite table, so it is compiled together with
# PasteBopCore rather than run as a standalone script. Swift only allows
# top-level code in a file called main.swift, hence the copy.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

cp Scripts/make-demo.swift "$BUILD/main.swift"
swiftc -O -target arm64-apple-macosx14.0 \
	Sources/PasteBopCore/*.swift "$BUILD/main.swift" \
	-o "$BUILD/make-demo"
"$BUILD/make-demo"
