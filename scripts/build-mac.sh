#!/bin/sh
# Build the carLy package on macOS with Xcode's clang.
#
# Why this exists: the on-device Procursus clang cannot pointer-authenticate Objective-C class
# metadata (isa/superclass), so its arm64e slice crashes CarPlayTemplateUIHost at load. Xcode's
# clang signs it correctly. Build here, install the resulting deb on the phone.
#
# Run ON THE MAC, from anywhere:
#   cd ~/Documents/diffMusicCarplay && ./scripts/build-mac.sh
#
# This Mac has Xcode but not ldid or xz (no Homebrew), so we sign with the system codesign
# (ad-hoc) and compress the deb with gzip. Both are accepted by the device package manager and
# by ElleKit. Install ldid + xz (e.g. via Homebrew) if you ever want a plain `make package`.
set -e
export THEOS="${THEOS:-$HOME/theos}"
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

make clean
make package FINALPACKAGE=1 \
    TARGET_CODESIGN=codesign \
    TARGET_CODESIGN_FLAGS="-f -s -" \
    THEOS_PLATFORM_DEB_COMPRESSION_TYPE=gzip \
    "$@"

echo
echo "Built package:"
ls -1 packages/*.deb
