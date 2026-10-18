// cltests — on-device test tool for carLy's non-UI code (layout geometry, parser, sync
// engine, protobuf reader, LRCLIB/custom providers, Spotify cache decoder, playback state,
// provider chain).
// No car, no CarPlay, no Spotify install and no network required for the default run.
//
// Build & run (from the repo root; also see tests/run.sh which does this for you):
//   export THEOS=/var/jb/var/mobile/theos
//   umask 022
//   make -C tests
//   tests/.theos/obj/cltests                 # offline suites only (default, fast, deterministic)
//   tests/.theos/obj/cltests --network        # also hits lrclib.net for one live lookup
//   tests/.theos/obj/cltests --spotify <id>   # also reads the REAL Spotify cache on this device
//                                             # for one Spotify track id (from
//                                             # spotify:track:<ID>#... in a Now Playing snapshot)
//                                             # and prints whatever it finds; not asserted, since
//                                             # it depends on this phone's Spotify history.
//   tests/.theos/obj/cltests --network --spotify <id>   # both together
//
// `tests/.theos` is this target's own Theos build directory (separate from the root tweak's
// `.theos`), so `make -C tests` is safe to run even while another agent is mid-build at the repo
// root — see docs/ORCHESTRATION.md's ground rules (only the integration agent runs `make` at the
// root; the tests slice owns everything under tests/, including running its own `make`).
//
// Exit code: 0 when every assertion in the suites that ran passed, 1 otherwise. A network or
// --spotify hiccup never fails the run by itself (see the individual suites for how each one
// treats live, non-deterministic results); a hard assertion failure always does.
#import <Foundation/Foundation.h>
#import "CLTestCase.h"
#import "CLLRCParserTests.h"
#import "CLTrackTests.h"
#import "CLLyricsTests.h"
#import "CLPlaybackStateTests.h"
#import "CLLyricsSyncEngineTests.h"
#import "CLProtobufReaderTests.h"
#import "CLSpotifyContainerTests.h"
#import "CLLyricsCacheTests.h"
#import "CLProviderChainTests.h"
#import "CLLRCLibProviderTests.h"
#import "CLCustomEndpointProviderTests.h"
#import "CLSpotifyCacheProviderTests.h"
#import "CLProviderFactoryTests.h"
#import "CLLyricsControllerTests.h"
#import "CLLayoutGeometryTests.h"
#import "CLTTMLParserTests.h"
#import "CLEmbeddedLyricsReaderTests.h"
#import "CLMusicSourcesTests.h"
#import "CLSpotifyColorLyricsDecoderTests.h"
#import "CLSpotifyBridgeTests.h"
#import "CLSpotifyRequestTemplateTests.h"
#import "CLSpotifyAppProviderTests.h"
#import <stdlib.h>
#import <unistd.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL networkEnabled = NO;
        NSString *spotifyTrackID = nil;

        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]] ?: @"";
            if ([arg isEqualToString:@"--network"]) {
                networkEnabled = YES;
            } else if ([arg isEqualToString:@"--spotify"]) {
                if (i + 1 < argc) {
                    spotifyTrackID = [NSString stringWithUTF8String:argv[++i]];
                } else {
                    fprintf(stderr, "--spotify requires a Spotify track id argument\n");
                    return 2;
                }
            } else if ([arg isEqualToString:@"--help"] || [arg isEqualToString:@"-h"]) {
                printf("Usage: cltests [--network] [--spotify <spotifyTrackID>]\n");
                return 0;
            } else {
                fprintf(stderr, "Unknown argument: %s (see --help)\n", argv[i]);
                return 2;
            }
        }

        // The Spotify bridge suites write requests, answers and a status file. Without an override
        // they would land in the phone's live bridge (/var/jb/var/mobile/...), where a running
        // Spotify would act on them; tests/run.sh and scripts/test-mac.sh pass a scratch directory,
        // and a bare run gets one here, before anything resolves CLSpotifyBridge's directory.
        NSString *scratchBridge = nil;
        if (getenv("CARLY_SPOTIFY_BRIDGE_DIR") == NULL) {
            scratchBridge = [NSTemporaryDirectory() stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"carly-bridge-%d", (int)getpid()]];
            setenv("CARLY_SPOTIFY_BRIDGE_DIR", scratchBridge.fileSystemRepresentation, 1);
        }

        printf("cltests — carLy on-device test tool\n");
        printf("network tests: %s | spotify cache lookup: %s\n",
               networkEnabled ? "ON" : "off (pass --network)",
               spotifyTrackID ? spotifyTrackID.UTF8String : "off (pass --spotify <id>)");

        // Pure logic, always run, deterministic, no network/disk-beyond-our-own-cache/car needed.
        CLRunLayoutGeometryTests();
        CLRunLRCParserTests();
        CLRunTrackTests();
        CLRunLyricsTests();
        CLRunPlaybackStateTests();
        CLRunLyricsSyncEngineTests();
        CLRunProtobufReaderTests();
        CLRunSpotifyContainerTests();
        CLRunSpotifyCacheProviderTests();
        CLRunProviderChainTests();
        CLRunProviderFactoryTests();
        CLRunCustomEndpointProviderTests();
        CLRunTTMLParserTests();
        CLRunEmbeddedLyricsReaderTests();
        CLRunMusicSourcesTests();
        CLRunSpotifyColorLyricsDecoderTests();
        CLRunSpotifyBridgeTests();
        CLRunSpotifyRequestTemplateTests();
        // Both ends of the Spotify round trip in this process, through the scratch bridge.
        CLRunSpotifyAppProviderTests();

        // Touches this process's own on-disk cache directory (see CLLyricsCacheTests.m for why
        // that is safe to do unconditionally).
        CLRunLyricsCacheTests();

        // Drives the real CLLyricsController with a fake provider and -startDetached, so it never
        // touches MediaRemote or this phone's own playback (see CLLyricsControllerTests.m).
        CLRunLyricsControllerTests();

        // Network-gated.
        CLRunLRCLibProviderTests(networkEnabled);

        // Real-device-data-gated, exploratory only (never affects the exit code by itself).
        if (spotifyTrackID) {
            CLRunSpotifyCacheProviderLiveLookup(spotifyTrackID);
        }

        if (scratchBridge) [[NSFileManager defaultManager] removeItemAtPath:scratchBridge error:NULL];
        return CLTestSummarize();
    }
}
