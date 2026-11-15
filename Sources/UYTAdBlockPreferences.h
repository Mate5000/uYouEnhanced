#import <Foundation/Foundation.h>

// Must run before AdBlocking.xm decides which hooks to install. Keep explicit
// user choices, including both workarounds disabled, across app upgrades.
static inline void UYTInitializeAdBlockPreferences(NSUserDefaults *defaults) {
    NSString *lite = @"adBlockWorkaroundLite_enabled";
    NSString *full = @"adBlockWorkaround_enabled";
    BOOL hasLite = [defaults objectForKey:lite] != nil;
    BOOL hasFull = [defaults objectForKey:full] != nil;
    if (!hasLite) [defaults setBool:NO forKey:lite];
    if (!hasFull) [defaults setBool:!hasLite forKey:full];
    if (![defaults objectForKey:@"removeYouTubeAds"])
        [defaults setBool:NO forKey:@"removeYouTubeAds"];
}
