#!/bin/sh
# tests/ui/run.sh — build and run the CLLayoutCustomizer harness (tests/ui/CLLayoutCustomizerHarness.m).
#
# Run by tests/run.sh as well as on its own. The harness writes preferences, so this script
# points CLPrefs at a scratch domain (CARLY_PREFS_DOMAIN, see CLPrefs.h) and removes it
# afterwards: the real com.andi.carly domain — a configured install's settings —
# is never touched. Do not remove that export.
#
# It needs no Theos project, no .theos and no car — one clang line and ldid.
set -eu

REPO=$(cd "$(dirname "$0")/../.." && pwd)
export THEOS=${THEOS:-/var/jb/var/mobile/theos}
SDK="$THEOS/sdks/iPhoneOS16.2.sdk"
OUT="${TMPDIR:-/tmp}/carly-uitest.$$"
umask 022

# Scratch preference domain + scratch lyrics cache root, so a run cannot touch this phone's own
# carLy settings or cached lyrics. Both are honoured by the code under test itself
# (CLPrefsActiveDomain() / CLCacheDirectory()); nothing sets them inside CarPlayTemplateUIHost.
#
# The domain carries $$ (a per-run name) on purpose. The harness clears its keys between tests
# with CFPreferencesSetAppValue(NULL) + CFPreferencesAppSynchronize, which is enough *inside* one
# process but does not reliably reach cfprefsd's cache for the next one: re-running this script
# against a domain cfprefsd has already seen resurrects the last run's values and fails
# ResetPrefs. A name cfprefsd has never heard of makes every run hermetic. Override
# CARLY_PREFS_DOMAIN only if you want that state to persist, and then expect one run per name.
export CARLY_PREFS_DOMAIN="${CARLY_PREFS_DOMAIN:-com.andi.carly.uitests.$$}"
export CARLY_CACHE_DIR="${CARLY_CACHE_DIR:-${TMPDIR:-/tmp}/carly-uitests-$$}"
cleanup() {
    rm -f "$OUT"
    rm -rf "$CARLY_CACHE_DIR"
    # Rootless: `mobile`'s preferences live under /var/jb (that is where the scratch domain is
    # actually written). The un-prefixed path is tried too because CLPrefs' own plist fallback
    # reads both, and leaving a stray file in either one would follow the next run around.
    rm -f "/var/mobile/Library/Preferences/$CARLY_PREFS_DOMAIN.plist" \
          "/var/jb/var/mobile/Library/Preferences/$CARLY_PREFS_DOMAIN.plist"
}
trap cleanup EXIT

cd "$REPO"
echo "== building the layout-customizer harness =="
clang -o "$OUT" \
    tests/ui/CLLayoutCustomizerHarness.m \
    Tweak/UI/*.m \
    Tweak/Util/CLLog.m Tweak/Util/CLColor.m Tweak/Util/CLPrefs.m Tweak/Util/CLRuntime.m \
    Tweak/Lyrics/CLLyricsTypes.m Tweak/Lyrics/CLLyricsCache.m Tweak/Lyrics/CLProviderChain.m \
    Tweak/Core/*.m Tweak/Sync/*.m \
    -target arm64-apple-ios17.0 -isysroot "$SDK" \
    -fobjc-arc -Wall -Werror -Wno-unused-function -DCL_VERSION='"test"' \
    -I"$THEOS/vendor/include" -ITweak -ITweak/Private \
    -framework UIKit -framework CoreGraphics
ldid -S "$OUT"

echo "== running =="
set +e
"$OUT"
STATUS=$?
set -e
exit "$STATUS"
