# tests/Makefile — on-device Theos "tool" target for cltests. Has its own .theos/ under tests/,
# separate from the tweak's root .theos/, so this is safe to build even while another agent is
# mid-build at the repo root (see docs/ORCHESTRATION.md's ground rules: only the integration agent
# runs `make` at the repo root; the tests slice owns running `make` here).
#
#   export THEOS=/var/jb/var/mobile/theos
#   umask 022
#   make -C tests
#   tests/.theos/obj/cltests [--network] [--spotify <trackID>]
#
# Excludes what needs UIKit or a real host process: Tweak/Util/CLPrefs.m, Tweak/Util/CLColor.m,
# everything in Tweak/UI except the header-only CLLayoutGeometry.h (the rest is covered by
# tests/ui/, which builds against UIKit) and Tweak/Hooks.
#
# Tweak/Core/CLNowPlayingSource.m and Tweak/Core/CLLyricsController.m ARE built in: neither one
# imports UIKit (MediaRemote is reached with dlopen), and the fix wave added
# -[CLLyricsController startDetached] so the controller can be exercised without subscribing to
# the real now-playing source — i.e. without dlopen'ing MediaRemote or reacting to whatever is
# playing on this phone. Nothing in tests/ may call -seekToLineAtIndex:, which would.
TARGET := iphone:clang:latest:15.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TOOL_NAME := cltests

cltests_FILES := \
	main.m \
	CLTestCase.m \
	CLTestFixtures.m \
	CLLRCParserTests.m \
	CLTrackTests.m \
	CLLyricsTests.m \
	CLPlaybackStateTests.m \
	CLLyricsSyncEngineTests.m \
	CLProtobufReaderTests.m \
	CLSpotifyContainerTests.m \
	CLLyricsCacheTests.m \
	CLProviderChainTests.m \
	CLLRCLibProviderTests.m \
	CLCustomEndpointProviderTests.m \
	CLSpotifyCacheProviderTests.m \
	CLProviderFactoryTests.m \
	CLLyricsControllerTests.m \
	CLLayoutGeometryTests.m \
	CLTTMLParserTests.m \
	CLEmbeddedLyricsReaderTests.m \
	CLMusicSourcesTests.m \
	CLSpotifyColorLyricsDecoderTests.m \
	CLSpotifyBridgeTests.m \
	CLSpotifyRequestTemplateTests.m \
	CLSpotifyAppProviderTests.m \
	$(wildcard ../Tweak/Lyrics/*.m) \
	$(wildcard ../Tweak/Sync/*.m) \
	../Tweak/Util/CLLog.m \
	../Tweak/Util/CLProtobufReader.m \
	../Tweak/Util/CLSpotifyContainer.m \
	../Tweak/Core/CLPlaybackState.m \
	../Tweak/Core/CLNowPlayingSource.m \
	../Tweak/Core/CLLyricsController.m \
	../Tweak/Core/CLMusicItemInfo.m \
	../Tweak/Core/CLMusicItemRegistry.m

cltests_CFLAGS := -fobjc-arc -Wall -Werror -Wno-unused-function -I../Tweak -I../Tweak/Private -DCL_VERSION='"test"'
cltests_LIBRARIES := sqlite3
# CoreGraphics: CLLayoutGeometryTests exercises the header-only UI/CLLayoutGeometry.h (CGRect math).
cltests_FRAMEWORKS := Foundation CoreGraphics
cltests_CODESIGN_FLAGS := -S

include $(THEOS)/makefiles/tool.mk
