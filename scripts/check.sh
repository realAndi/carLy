#!/bin/sh
# Syntax-check ONE .m or .x file without touching .theos (safe to run from several agents at once).
# Usage: scripts/check.sh Tweak/Lyrics/CLLRCParser.m
set -e
THEOS=${THEOS:-/var/jb/var/mobile/theos}
SDK=$THEOS/sdks/iPhoneOS16.2.sdk
f="$1"; src="$f"; tmp=""; lang=""
case "$f" in
  *.x) tmp=$(mktemp "${TMPDIR:-/tmp}/clcheck.XXXXXX"); mv "$tmp" "$tmp.m"; tmp="$tmp.m"; perl "$THEOS/bin/logos.pl" "$f" > "$tmp"; src="$tmp";;
  # A bare header is plain C to clang unless we say otherwise, so every ObjC header "failed"
  # when checked directly. -x objective-c-header makes a header-only change checkable.
  *.h) lang="-x objective-c-header";;
esac
extra=""
case "$f" in Prefs/*) extra="-IPrefs";; esac
# -F"$THEOS/vendor/lib": Logos emits #include "substrate.h" for any file containing a %hook, and
# that header pulls <CydiaSubstrate/CydiaSubstrate.h> out of the CydiaSubstrate.framework there.
clang -fsyntax-only -target arm64-apple-ios17.0 -isysroot "$SDK" -fobjc-arc -Wall -Werror -Wno-unused-function \
  -DCL_VERSION='"dev"' -DTHEOS_PACKAGE_SCHEME_ROOTLESS -I"$THEOS/vendor/include" -I"$THEOS/include" \
  -F"$THEOS/vendor/lib" -ITweak -ITweak/Private $extra \
  -include "$THEOS/Prefix.pch" $lang "$src"
[ -n "$tmp" ] && rm -f "$tmp"
echo "OK $f"
