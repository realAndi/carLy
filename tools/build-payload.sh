#!/usr/bin/env bash
# Build carLy and stage everything the package will contain.
#
#   tools/build-payload.sh <version>
#
# Runs on macOS: the arm64e slice must come from Xcode's clang, which signs Objective-C class
# metadata the way iOS 17's arm64e runtime expects (Procursus' on-device clang does not, and its
# arm64e build crashes CarPlayTemplateUIHost at load). Theos picks the newest iPhoneOS SDK Xcode
# has. The .deb is assembled on Linux by build-deb.sh from what lands in packaging/payload/.
#
# Theos comes from $THEOS. A CI runner has Xcode but no Theos, and the shared workflow has no
# input to install one, so there -- and only there ($CI set, $THEOS unset) -- the commit pinned in
# tools/theos.pin is fetched into .theos-toolchain/. Pinned, so a Theos change can never alter a
# build without a commit here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?usage: build-payload.sh <version>}"

CONTROL_VERSION="$(awk '/^Version:/ { print $2; exit }' "$ROOT/control")"
[ "$VERSION" = "$CONTROL_VERSION" ] \
    || { echo "asked to build $VERSION, but control says $CONTROL_VERSION -- bump control first"; exit 1; }

if [ -z "${THEOS:-}" ]; then
    if [ -z "${CI:-}" ]; then
        echo "set THEOS to a Theos checkout (git clone --recursive https://github.com/theos/theos ~/theos)"
        exit 1
    fi
    PIN="$(tr -d '[:space:]' < "$ROOT/tools/theos.pin")"
    THEOS="$ROOT/.theos-toolchain"
    if [ ! -d "$THEOS/.git" ]; then
        echo "==> fetching Theos $PIN"
        git init -q "$THEOS"
        git -C "$THEOS" remote add origin https://github.com/theos/theos.git
        git -C "$THEOS" fetch -q --depth 1 origin "$PIN"
        git -C "$THEOS" checkout -q FETCH_HEAD
        git -C "$THEOS" submodule update -q --init --recursive
    fi
    export THEOS
fi

make -C "$ROOT" clean >/dev/null
# Ad-hoc signed with the system codesign: ElleKit loads ad-hoc dylibs, and macOS has no ldid.
make -C "$ROOT" stage FINALPACKAGE=1 TARGET_CODESIGN=codesign TARGET_CODESIGN_FLAGS="-f -s -"

PAYLOAD="$ROOT/packaging/payload"
rm -rf "$PAYLOAD"
mkdir -p "$PAYLOAD/root"
# Theos stages without the rootless prefix (it adds /var/jb when it packages); build-deb.sh does.
cp -R "$ROOT/.theos/_/." "$PAYLOAD/root/"
rm -rf "$PAYLOAD/root/DEBIAN"
printf '%s\n' "$VERSION" > "$PAYLOAD/PAYLOAD.version"

for binary in Library/MobileSubstrate/DynamicLibraries/carLy.dylib \
              Library/PreferenceBundles/carLyPrefs.bundle/carLyPrefs; do
    [ -f "$PAYLOAD/root/$binary" ] || { echo "the build did not produce $binary"; exit 1; }
    lipo "$PAYLOAD/root/$binary" -verify_arch arm64 arm64e \
        || { echo "$binary is missing arm64 or arm64e"; exit 1; }
done
echo "==> payload staged in packaging/payload/ ($(du -sh "$PAYLOAD" | cut -f1))"
