// Preference domain, key names and Darwin notification names for com.andi.carly.
// This header is the single source of truth for key strings: CLPrefs.m resolves every value
// against these keys and applies the defaults documented in the table below when a key is
// missing from the plist or holds a value of the wrong type. The Prefs bundle (PreferenceLoader)
// must use these same key strings for its specifiers so it reads/writes the same plist.
#import <Foundation/Foundation.h>

// MARK: - Domain

/// CFPreferences application id / NSUserDefaults suite name for every key below.
#define CLPrefsDomain (@"com.andi.carly")

// MARK: - Darwin notifications
//
// Posted (via CFNotificationCenterGetDarwinNotifyCenter) by the Prefs bundle, observed by every
// running instance of the tweak via CLPrefs.
//
//   com.andi.carly/prefsChanged   — a setting changed; CLPrefs reloads and posts
//                                                   CLPrefsDidChangeNotification.
//   com.andi.carly/clearCache     — "Clear cache" tapped; CLPrefs posts
//                                                   CLPrefsClearCacheNotification (does not touch
//                                                   the cache itself — CLLyricsCache owns that).
//   com.andi.carly/resetDefaults  — "Reset to defaults" tapped; CLPrefs posts
//                                                   CLPrefsResetNotification. The Prefs bundle is
//                                                   responsible for actually clearing the plist
//                                                   keys before/after posting this.
#define CLPrefsDarwinNotificationPrefsChanged   (@"com.andi.carly/prefsChanged")
#define CLPrefsDarwinNotificationClearCache     (@"com.andi.carly/clearCache")
#define CLPrefsDarwinNotificationResetDefaults  (@"com.andi.carly/resetDefaults")

// MARK: - Keys
//
// Removed in 0.5.0 (never read by the tweak again; Settings' Reset removes them and Import skips
// them, see +[CLPrefsShared legacyKeys]): lyricsPosition, lyricsMaxLines (the two-line overlay),
// artworkScale (the brick transform), titleFontSize, compactMode (fought the host every pass),
// hideAppBadge (an unverified heuristic).
//
// | Key                          | Type            | Default                                     | Meaning |
// |-------------------------------|-----------------|----------------------------------------------|---------|
// | **General** |
// | enabled                       | bool            | YES                                          | Master on/off switch for the whole tweak. |
// | debugLogging                  | bool            | NO                                           | Enables CLLogLevelDebug output (see CLLog.h); wired live by CLPrefs. |
// | enabledApps                   | array\<string\> | ["com.spotify.client","com.apple.Music"]     | Now-playing bundle ids the tweak is active for, when allApps is NO. Apple Music since 0.8.0 (its CarPlay player runs in the Music app). |
// | allApps                       | bool            | NO                                           | Ignore enabledApps and run for every now-playing bundle id. |
// | **Lyrics** |
// | lyricsMode                    | int             | 4                                             | The layout. 0 off, 2 "No Artwork" (CarPlay's compact player without the cover, in a 200 pt strip below the lyrics, or a 240 pt column beside them on short screens), 4 side by side (player column left, lyrics right; No Artwork on screens too narrow to split). 1 (the removed overlay) and 3 (the removed Replace Artwork) read as 4. See UI/CLLayoutGeometry.h. |
// | lyricsFontFamily              | string          | "" (system)                                  | UIFont family name; empty means the system font. |
// | lyricsFontSize                | float           | 24                                            | The largest point size the lyrics panel uses (it shrinks to fit smaller panels; see CLLayoutPanelFit). |
// | lyricsFontWeight              | int             | 600                                           | Numeric 100...900 (CSS-style); converted via +[CLColor fontWeightFromNumeric:]. |
// | lyricsCurrentColor            | hex string      | "#FFFFFF"                                     | Colour of the current (active) lyric line. |
// | lyricsNextColor               | hex string      | "#FFFFFF"                                     | Base colour of the next/upcoming lyric line(s). |
// | lyricsNextAlpha               | float           | 0.45                                          | Opacity applied on top of lyricsNextColor for dimming. |
// | lyricsAlignment               | int             | 0                                             | 0 left, 1 center, 2 right. |
// | lyricsAnimations              | bool            | YES                                           | Animate line transitions (fade/slide) vs. hard cut. |
// | lyricsShowPlainWhenUnsynced   | bool            | YES                                           | Show plain (unsynced) lyrics as static text when no LRC is available. |
// | lyricsOffsetMs                | int             | 0                                             | Manual sync offset in milliseconds, added to the computed elapsed time — so a positive value makes lines appear *earlier* and a negative one delays them (the LRC `[offset:]` convention, see CLLyricsSyncEngine.h and Lyrics.plist's footer). |
// | serviceLyricsOffsetMs         | int             | 0                                             | The same offset for lyrics timed by the playing app's own service: Spotify's ("spotify", "spotify-cache") and Apple Music's ("apple-music"). lyricsOffsetMs then only moves LRCLIB, custom and embedded lyrics (0.9.0). |
// | lyricsShowNoteOnGap           | bool            | YES                                           | Show a musical-note indicator during instrumental gaps between lines. |
// | lyricsBackground              | int             | 0                                             | 0 none, 1 translucent pill, 2 solid. |
// | lyricsBackgroundColor         | hex string      | "#000000"                                     | Colour used when lyricsBackground != 0. |
// | lyricsBackgroundAlpha         | float           | 0.35                                          | Opacity applied on top of lyricsBackgroundColor. |
// | **Layout** |
// | artworkCornerRadius           | float           | 12                                            | Corner radius applied to the artwork square, in points. |
// | backdropStyle                 | int             | 0                                             | The host's own full-bleed blurred artwork backdrop (verified in -[CPUINowPlayingViewController viewDidLoad]): 0 keep it (system), 1 plain (hidden: the host's dark table background shows). |
// | backdropOpacity               | float           | 1.0                                           | Opacity of the host's backdrop artwork image, 0...1; 1 is the system look, lower is darker. Ignored when backdropStyle is 1. |
// | tintFromArtwork                | bool            | NO                                            | Derive the accent colour from the current artwork instead of accentColor. |
// | accentColor                   | hex string      | "" (system)                                   | Custom accent colour; empty means use the system/CarPlay tint. |
// | showAlbum                     | bool            | YES                                           | Show the album name line in the song details. |
// | progressBarStyle              | int             | 0                                             | 0 show, 2 hide; 1 (the removed thin bar) reads as 0. |
// | hidePlaybackRateButton        | bool            | NO                                            | Hide the playback-speed ("1×") button in the player's play-mode row (shown for podcasts and audiobooks). 0.7.4: before, it hid an empty label in the top bar. |
// | hideQueueButton               | bool            | NO                                            | Hide the queue bar button item ("Queue & Jam" on Spotify). |
// | showLyricsButton              | bool            | YES                                           | Show the microphone in the play-mode row that opens full-screen lyrics (0.7.4). |
// | lyricsSide                    | int             | 0                                             | Where the lyrics go beside a player column (Side by Side, No Artwork on short screens): 0 right, 1 left (0.7.5). |
// | **Sources** |
// | providerOrder                 | array\<string\> | ["embedded","apple-music","spotify","spotify-cache","lrclib","custom"] | Lyrics provider identifiers in try order; unknown identifiers are ignored by the chain. An order saved before a source existed ("embedded"/"apple-music" before 0.8.0, "spotify" before 0.9.0) gets it where the default order runs it (CLProviderFactory). |
// | embeddedLyricsEnabled         | bool            | YES                                           | Enable lyrics embedded in the song file (Apple Music library songs; tags, the library's lyrics text, a sidecar .lrc). 0.8.0. |
// | appleMusicLyricsEnabled       | bool            | YES                                           | Enable Apple Music's own synced lyrics for Apple Music catalog songs (fetched by the Music app's signed-in session). 0.8.0. |
// | lrclibEnabled                 | bool            | YES                                           | Enable the LRCLIB provider. |
// | spotifyLyricsEnabled          | bool            | YES                                           | Enable Spotify's own lyrics for Spotify songs, fetched by carLy inside Spotify with Spotify's login and handed to the CarPlay host (0.9.0). Off also stops the service in Spotify. |
// | spotifyCacheEnabled           | bool            | YES                                           | Enable the Spotify on-disk lyrics cache provider. |
// | customEndpointEnabled         | bool            | NO                                            | Enable the user-supplied custom endpoint provider. |
// | customEndpointURL             | string          | ""                                            | URL template, may contain {artist} {title} {duration}. |
// | customEndpointHeaderName      | string          | ""                                            | Optional single extra HTTP header name for the custom endpoint. |
// | customEndpointHeaderValue     | string          | ""                                            | Optional single extra HTTP header value for the custom endpoint. |
// | offlineOnly                   | bool            | NO                                            | Never hit the network; only cache/disk providers run. |
// | cacheNegativeHours            | int             | 24                                            | TTL, in hours, for cached "no lyrics found" results. |

// General
#define CLPrefKeyEnabled                     (@"enabled")
#define CLPrefKeyDebugLogging                (@"debugLogging")
#define CLPrefKeyEnabledApps                 (@"enabledApps")
#define CLPrefKeyAllApps                     (@"allApps")

// Lyrics
#define CLPrefKeyLyricsMode                  (@"lyricsMode")
#define CLPrefKeyLyricsFontFamily            (@"lyricsFontFamily")
#define CLPrefKeyLyricsFontSize              (@"lyricsFontSize")
#define CLPrefKeyLyricsFontWeight            (@"lyricsFontWeight")
#define CLPrefKeyLyricsCurrentColor          (@"lyricsCurrentColor")
#define CLPrefKeyLyricsNextColor             (@"lyricsNextColor")
#define CLPrefKeyLyricsNextAlpha             (@"lyricsNextAlpha")
#define CLPrefKeyLyricsAlignment             (@"lyricsAlignment")
#define CLPrefKeyLyricsAnimations            (@"lyricsAnimations")
#define CLPrefKeyLyricsShowPlainWhenUnsynced (@"lyricsShowPlainWhenUnsynced")
#define CLPrefKeyLyricsOffsetMs              (@"lyricsOffsetMs")
#define CLPrefKeyServiceLyricsOffsetMs       (@"serviceLyricsOffsetMs")
#define CLPrefKeyLyricsShowNoteOnGap         (@"lyricsShowNoteOnGap")
#define CLPrefKeyLyricsBackground            (@"lyricsBackground")
#define CLPrefKeyLyricsBackgroundColor       (@"lyricsBackgroundColor")
#define CLPrefKeyLyricsBackgroundAlpha       (@"lyricsBackgroundAlpha")

// Layout
#define CLPrefKeyArtworkCornerRadius         (@"artworkCornerRadius")
#define CLPrefKeyBackdropStyle               (@"backdropStyle")
#define CLPrefKeyBackdropOpacity             (@"backdropOpacity")
#define CLPrefKeyTintFromArtwork             (@"tintFromArtwork")
#define CLPrefKeyAccentColor                 (@"accentColor")
#define CLPrefKeyShowAlbum                   (@"showAlbum")
#define CLPrefKeyProgressBarStyle            (@"progressBarStyle")
#define CLPrefKeyHidePlaybackRateButton      (@"hidePlaybackRateButton")
#define CLPrefKeyHideQueueButton             (@"hideQueueButton")
#define CLPrefKeyShowLyricsButton            (@"showLyricsButton")
#define CLPrefKeyLyricsSide                  (@"lyricsSide")

// Sources
#define CLPrefKeyProviderOrder               (@"providerOrder")
#define CLPrefKeyLRCLibEnabled               (@"lrclibEnabled")
#define CLPrefKeyEmbeddedLyricsEnabled       (@"embeddedLyricsEnabled")
#define CLPrefKeyAppleMusicLyricsEnabled     (@"appleMusicLyricsEnabled")
#define CLPrefKeySpotifyLyricsEnabled        (@"spotifyLyricsEnabled")
#define CLPrefKeySpotifyCacheEnabled         (@"spotifyCacheEnabled")
#define CLPrefKeyCustomEndpointEnabled       (@"customEndpointEnabled")
#define CLPrefKeyCustomEndpointURL           (@"customEndpointURL")
#define CLPrefKeyCustomEndpointHeaderName    (@"customEndpointHeaderName")
#define CLPrefKeyCustomEndpointHeaderValue   (@"customEndpointHeaderValue")
#define CLPrefKeyOfflineOnly                 (@"offlineOnly")
#define CLPrefKeyCacheNegativeHours          (@"cacheNegativeHours")
