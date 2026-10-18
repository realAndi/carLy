#!/bin/sh
# tests/run.sh — build cltests (in its own tests/.theos, never touching the root build) and run
# it, printing a short summary. Safe to run repeatedly and safe to run while another agent is
# building the tweak itself at the repo root (see docs/ORCHESTRATION.md).
#
# Two suites run here: the cltests tool (pure logic, built from this directory) and the UI harness
# under tests/ui (CLLayoutCustomizer against fake CPUINowPlaying* classes). Both must pass. The
# arguments below go to cltests only; tests/ui takes none.
#
# Usage:
#   tests/run.sh                          # offline suites only (fast, deterministic)
#   tests/run.sh --network                # also do one live lrclib.net lookup
#   tests/run.sh --spotify <trackID>      # also read the real Spotify cache for one track id
#   tests/run.sh --network --spotify <id> # both
#
# Exit code: 0 when every assertion in both suites passed. Otherwise cltests' own exit code (2 for
# a bad argument), or the harness's when only it failed — so this is safe in a shell `&&` chain.
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
export THEOS=${THEOS:-/var/jb/var/mobile/theos}
umask 022

echo "== building cltests =="
make -C "$SCRIPT_DIR" >/tmp/cltests-build.$$ 2>&1
BUILD_STATUS=$?
if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "build failed:"
    cat /tmp/cltests-build.$$
    rm -f /tmp/cltests-build.$$
    exit 1
fi
rm -f /tmp/cltests-build.$$

BINARY="$SCRIPT_DIR/.theos/obj/debug/cltests"
if [ ! -x "$BINARY" ]; then
    # Older/newer Theos versions have placed the "debug" configuration's binary directly under
    # obj/ instead of obj/debug/ at times; fall back to whichever exists.
    BINARY="$SCRIPT_DIR/.theos/obj/cltests"
fi
if [ ! -x "$BINARY" ]; then
    echo "build succeeded but the cltests binary was not found under $SCRIPT_DIR/.theos/obj"
    exit 1
fi

# Give CLLyricsCache a scratch storage root for the duration of the run (CLLyricsCache.h): the
# suite then cannot touch this user's own cached lyrics, and two runs cannot collide. Removed
# again below whatever the outcome.
CACHE_DIR="${TMPDIR:-/tmp}/carly-tests-$$"
export CARLY_CACHE_DIR="$CACHE_DIR"
# Same for the Spotify bridge suites: never the live /var/jb/var/mobile/... bridge.
export CARLY_SPOTIFY_BRIDGE_DIR="$CACHE_DIR/spotify-bridge"

echo "== running cltests $* =="
set +e
"$BINARY" "$@"
STATUS=$?
set -e
rm -rf "$CACHE_DIR"

# tests/ui/ is the CLLayoutCustomizer harness: fake CPUINowPlaying* classes carrying the real
# private ivar names, so the UI slice runs with no car and no CarPlayUI. It used to be excluded
# from this script because it writes preferences and would have wiped a configured install's
# settings; it now honours CARLY_PREFS_DOMAIN and tests/ui/run.sh points that at a scratch
# domain. `env -u` so it sets up (and tears down) its own scratch domain and cache root instead
# of inheriting — and deleting — the ones this run just used.
echo
echo "== running the UI harness (tests/ui) =="
set +e
env -u CARLY_CACHE_DIR -u CARLY_PREFS_DOMAIN -u CARLY_SPOTIFY_BRIDGE_DIR sh "$SCRIPT_DIR/ui/run.sh"
UI_STATUS=$?
set -e

echo "== summary =="
if [ "$STATUS" -eq 0 ]; then
    echo "cltests: ALL PASSED"
else
    echo "cltests: FAILED (exit $STATUS) — see FAIL lines above"
fi
if [ "$UI_STATUS" -eq 0 ]; then
    echo "tests/ui: ALL PASSED"
else
    echo "tests/ui: FAILED (exit $UI_STATUS) — see FAIL lines above"
fi
if [ "$STATUS" -ne 0 ]; then
    exit "$STATUS"
fi
exit "$UI_STATUS"
