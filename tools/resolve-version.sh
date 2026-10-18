#!/usr/bin/env bash
# Which carLy version should we build?
#
#   tools/resolve-version.sh           the Version line of `control`
#   tools/resolve-version.sh 1.0.1     that version, validated (leading v tolerated)
#
# Echoes the version on stdout and NOTHING else -- CI captures it. Progress and errors go to
# stderr. Runs on Linux, before the macOS job exists (realAndi/ios-port-ci, CONTRACT.md).
#
# carLy is built from this repository rather than packaged from an upstream release, so "the
# current version" is what `control` says -- the same file Theos reads, so the version compiled
# into the tweak (CL_VERSION) and the package's agree. A tag push passes the tag through the
# workflow's version input, and build-payload.sh refuses one that `control` does not match.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

VERSION="${1:-}"
VERSION="${VERSION#v}"

if [ -z "$VERSION" ]; then
    VERSION="$(awk '/^Version:/ { print $2; exit }' "$ROOT/control")"
    echo "==> control says $VERSION" >&2
fi

printf '%s' "$VERSION" | grep -qE '^[0-9]+(\.[0-9]+)*$' \
    || { echo "not a version: '$VERSION'" >&2; exit 1; }

echo "$VERSION"
