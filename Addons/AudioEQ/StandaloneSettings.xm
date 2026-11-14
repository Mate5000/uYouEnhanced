// Development package only. The app uses its native settings row and does not
// compile this translation unit.
#import "Settings.h"
#import <objc/runtime.h>

@interface YTSettingsCell : UITableViewCell
@end
@interface YTSettingsSectionItem : NSObject
+ (instancetype)itemWithTitle:(NSString *)title accessibilityIdentifier:(NSString *)identifier detailTextBlock:(NSString *(^)(void))detail selectBlock:(BOOL (^)(YTSettingsCell *, NSUInteger))select;
@end
@interface YTSettingsViewController : UIViewController
- (void)pushViewController:(UIViewController *)controller;
- (void)setSectionItems:(NSMutableArray *)items forCategory:(NSInteger)category title:(NSString *)title titleDescription:(NSString *)description headerHidden:(BOOL)hidden;
- (void)setSectionItems:(NSMutableArray *)items forCategory:(NSInteger)category title:(NSString *)title icon:(id)icon titleDescription:(NSString *)description headerHidden:(BOOL)hidden;
@end
@interface YTSettingsGroupData : NSObject
@property(nonatomic, readonly) NSUInteger type;
@end
@interface YTSettingsSectionItemManager : NSObject
@end

static const NSInteger AudioEQSection = 918264;
static NSArray *withAudioCategory(NSArray *original, BOOL afterGeneral) {
    NSMutableArray *categories = original ? [original mutableCopy] : [NSMutableArray array];
    if (![categories containsObject:@(AudioEQSection)]) {
        NSUInteger general = [categories indexOfObject:@1];
        [categories insertObject:@(AudioEQSection) atIndex:afterGeneral && general != NSNotFound ? general + 1 : 0];
    }
    return categories;
}

%group SettingsIntegration
%hook YTAppSettingsPresentationData
+ (NSArray *)settingsCategoryOrder { return withAudioCategory(%orig, YES); }
%end
%hook YTSettingsGroupData
- (NSArray *)orderedCategories {
    NSArray *original = %orig;
    if (self.type != 1 || class_getClassMethod(self.class, @selector(tweaks))) return original;
    return withAudioCategory(original, NO);
}
%end
%hook YTSettingsSectionItemManager
- (void)updateSectionForCategory:(NSUInteger)category withEntry:(id)entry {
    if (category != AudioEQSection) { %orig; return; }
    YTSettingsViewController *controller = nil;
    @try { controller = [self valueForKey:@"_settingsViewControllerDelegate"]; }
    @catch (__unused NSException *exception) { return; }
    if (!controller) return;
    __weak YTSettingsViewController *weakController = controller;
    YTSettingsSectionItem *item = [%c(YTSettingsSectionItem) itemWithTitle:YTAEQLocalize(@"Audio EQ")
        accessibilityIdentifier:@"YTAudioEQ.settings" detailTextBlock:nil
        selectBlock:^BOOL(__unused YTSettingsCell *cell, __unused NSUInteger index) {
            [weakController pushViewController:YTAEQCreatePanel()]; return YES;
        }];
    if (!item) return;
    NSMutableArray *items = [NSMutableArray arrayWithObject:item];
    if ([controller respondsToSelector:@selector(setSectionItems:forCategory:title:icon:titleDescription:headerHidden:)])
        [controller setSectionItems:items forCategory:AudioEQSection title:YTAEQLocalize(@"Audio EQ") icon:nil titleDescription:nil headerHidden:NO];
    else if ([controller respondsToSelector:@selector(setSectionItems:forCategory:title:titleDescription:headerHidden:)])
        [controller setSectionItems:items forCategory:AudioEQSection title:YTAEQLocalize(@"Audio EQ") titleDescription:nil headerHidden:NO];
}
%end
%end

%group GroupedSettingsIntegration
%hook YTSettingsGroupData
+ (NSArray *)tweaks { return withAudioCategory(%orig, NO); }
%end
%end

static BOOL groupedSettingsInstalled = NO;
static void installGroupedSettingsIfAvailable() {
    Class group = NSClassFromString(@"YTSettingsGroupData");
    if (!groupedSettingsInstalled && class_getClassMethod(group, @selector(tweaks))) {
        groupedSettingsInstalled = YES;
        %init(GroupedSettingsIntegration);
    }
}
%ctor {
    if (!NSClassFromString(@"YTPlayerViewController")) return;
    %init(SettingsIntegration);
    installGroupedSettingsIfAvailable();
    dispatch_async(dispatch_get_main_queue(), ^{ installGroupedSettingsIfAvailable(); });
}
