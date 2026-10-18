#!/bin/sh
# scripts/test-mac.sh — build both test suites on the Mac and run them in the iOS Simulator.
#
# The Mac-side replacement for tests/run.sh (which builds with the phone's Theos). Same two
# suites: cltests (pure logic) and the tests/ui CLLayoutCustomizer harness (UIKit, fake
# CPUINowPlaying* classes). Both are built with Xcode's clang against the iphonesimulator SDK and
# spawned inside an iOS 17 simulator, the closest runtime to the phone's iOS 17.3.
#
#   scripts/test-mac.sh                      # both suites, offline
#   scripts/test-mac.sh --network            # also one live lrclib.net lookup (cltests only)
#
# CARLY_SIM_UDID picks a specific simulator; otherwise the first available iPhone on an
# iOS 17 runtime is used (booted first if needed). Exit code: 0 only when both suites passed.
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO"
THEOS=${THEOS:-$HOME/theos}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/carly-mac-tests.XXXXXX")

UDID=${CARLY_SIM_UDID:-$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices):
    if ".iOS-17-" not in runtime:
        continue
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print(device["udid"]); sys.exit(0)
')}
if [ -z "$UDID" ]; then
    echo "no iOS 17 iPhone simulator found (Xcode > Settings > Components installs one)" >&2
    exit 1
fi
xcrun simctl bootstatus "$UDID" -b >/dev/null

# Scratch preference domain + lyrics cache root, per run, exactly like tests/run.sh: nothing here
# may write the real com.andi.carly domain. simctl forwards SIMCTL_CHILD_* to the
# spawned process with the prefix stripped.
PREFS_DOMAIN="com.andi.carly.uitests.$$"
SIM_DATA="$HOME/Library/Developer/CoreSimulator/Devices/$UDID/data"
cleanup() {
    rm -rf "$OUT"
    rm -f "$SIM_DATA/Library/Preferences/$PREFS_DOMAIN.plist"
}
trap cleanup EXIT

echo "== checking the settings plists =="
python3 scripts/check-prefs-plists.py

CC="xcrun --sdk iphonesimulator clang -target arm64-apple-ios15.0-simulator"   # the tweak's own deployment target (Makefile)
CFLAGS="-fobjc-arc -Wall -Werror -Wno-unused-function -DCL_VERSION=\"test\" -ITweak -ITweak/Private"

echo "== building cltests (iOS Simulator) =="
# Same file list as tests/Makefile.
$CC $CFLAGS -o "$OUT/cltests" \
    tests/main.m tests/CLTestCase.m tests/CLTestFixtures.m \
    tests/CLLRCParserTests.m tests/CLTrackTests.m tests/CLLyricsTests.m tests/CLPlaybackStateTests.m \
    tests/CLLyricsSyncEngineTests.m tests/CLProtobufReaderTests.m tests/CLSpotifyContainerTests.m \
    tests/CLLyricsCacheTests.m tests/CLProviderChainTests.m tests/CLLRCLibProviderTests.m \
    tests/CLCustomEndpointProviderTests.m tests/CLSpotifyCacheProviderTests.m \
    tests/CLProviderFactoryTests.m tests/CLLyricsControllerTests.m tests/CLLayoutGeometryTests.m \
    tests/CLTTMLParserTests.m tests/CLEmbeddedLyricsReaderTests.m tests/CLMusicSourcesTests.m \
    tests/CLSpotifyColorLyricsDecoderTests.m tests/CLSpotifyBridgeTests.m \
    tests/CLSpotifyRequestTemplateTests.m tests/CLSpotifyAppProviderTests.m \
    Tweak/Lyrics/*.m Tweak/Sync/*.m \
    Tweak/Util/CLLog.m Tweak/Util/CLProtobufReader.m Tweak/Util/CLSpotifyContainer.m \
    Tweak/Core/CLPlaybackState.m Tweak/Core/CLNowPlayingSource.m Tweak/Core/CLLyricsController.m \
    Tweak/Core/CLMusicItemInfo.m Tweak/Core/CLMusicItemRegistry.m \
    -framework Foundation -framework CoreGraphics -lsqlite3

echo "== building the UI harness (iOS Simulator) =="
# Same file list as tests/ui/run.sh.
$CC $CFLAGS -I"$THEOS/vendor/include" -o "$OUT/uitest" \
    tests/ui/CLLayoutCustomizerHarness.m \
    Tweak/UI/*.m \
    Tweak/Util/CLLog.m Tweak/Util/CLColor.m Tweak/Util/CLPrefs.m Tweak/Util/CLRuntime.m \
    Tweak/Lyrics/CLLyricsTypes.m Tweak/Lyrics/CLLyricsCache.m Tweak/Lyrics/CLProviderChain.m \
    Tweak/Core/*.m Tweak/Sync/*.m \
    -framework UIKit -framework CoreGraphics

run_suite() {   # name, cache dir, binary, args...
    name=$1; cache=$2; shift 2
    echo
    echo "== running $name =="
    set +e
    SIMCTL_CHILD_CARLY_CACHE_DIR="$cache" \
    SIMCTL_CHILD_CARLY_SPOTIFY_BRIDGE_DIR="$cache/spotify-bridge" \
    SIMCTL_CHILD_CARLY_PREFS_DOMAIN="$PREFS_DOMAIN" \
        xcrun simctl spawn "$UDID" "$@"
    status=$?
    set -e
    rm -rf "$cache"
    return $status
}

set +e
run_suite cltests "$OUT/cache-cltests" "$OUT/cltests" "$@"
STATUS=$?
run_suite tests/ui "$OUT/cache-ui" "$OUT/uitest"
UI_STATUS=$?
set -e

echo
echo "== summary =="
[ "$STATUS" -eq 0 ] && echo "cltests: ALL PASSED" || echo "cltests: FAILED (exit $STATUS)"
[ "$UI_STATUS" -eq 0 ] && echo "tests/ui: ALL PASSED" || echo "tests/ui: FAILED (exit $UI_STATUS)"
[ "$STATUS" -ne 0 ] && exit "$STATUS"
exit "$UI_STATUS"
