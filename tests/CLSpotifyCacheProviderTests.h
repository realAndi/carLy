#import <Foundation/Foundation.h>
void CLRunSpotifyCacheProviderTests(void);

/// Exploratory, not asserted: reads the real Spotify cache on this device through the provider's
/// public fetch method for one track id, for a human to eyeball. Enabled by --spotify <trackID>.
void CLRunSpotifyCacheProviderLiveLookup(NSString *spotifyTrackID);
