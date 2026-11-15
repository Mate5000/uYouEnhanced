#import "../../Sources/UYTAdBlockPreferences.h"
#include <assert.h>

@interface MemoryDefaults : NSUserDefaults
@property(nonatomic, strong) NSMutableDictionary *values;
@end
@implementation MemoryDefaults
- (instancetype)init { self = [super init]; if (self) _values = [NSMutableDictionary dictionary]; return self; }
- (id)objectForKey:(NSString *)key { return self.values[key]; }
- (void)setBool:(BOOL)value forKey:(NSString *)key { self.values[key] = @(value); }
@end

int main(void) {
    @autoreleasepool {
        NSString *lite = @"adBlockWorkaroundLite_enabled", *full = @"adBlockWorkaround_enabled";
        MemoryDefaults *fresh = [MemoryDefaults new];
        UYTInitializeAdBlockPreferences(fresh);
        assert(![fresh.values[lite] boolValue] && [fresh.values[full] boolValue]);
        assert(![fresh.values[@"removeYouTubeAds"] boolValue]);
        NSDictionary *initial = [fresh.values copy];
        UYTInitializeAdBlockPreferences(fresh);
        assert([fresh.values isEqual:initial]);
        for (NSNumber *liteValue in @[@NO, @YES]) for (NSNumber *fullValue in @[@NO, @YES]) {
            MemoryDefaults *saved = [MemoryDefaults new];
            saved.values[lite] = liteValue; saved.values[full] = fullValue;
            saved.values[@"removeYouTubeAds"] = @YES;
            UYTInitializeAdBlockPreferences(saved);
            assert([saved.values[lite] isEqual:liteValue] && [saved.values[full] isEqual:fullValue]);
            assert([saved.values[@"removeYouTubeAds"] boolValue]);
        }
        MemoryDefaults *liteOnly = [MemoryDefaults new];
        liteOnly.values[lite] = @YES;
        UYTInitializeAdBlockPreferences(liteOnly);
        assert([liteOnly.values[lite] boolValue] && ![liteOnly.values[full] boolValue]);
        MemoryDefaults *disabled = [MemoryDefaults new];
        disabled.values[full] = @NO;
        UYTInitializeAdBlockPreferences(disabled);
        assert(![disabled.values[lite] boolValue] && ![disabled.values[full] boolValue]);
        puts("PASS: adblock first launch, repeated initialization and saved choices");
    }
}
