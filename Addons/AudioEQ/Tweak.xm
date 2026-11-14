#import "Settings.h"
#import "AudioHooks.hpp"
#import <objc/runtime.h>

// The app uses its native settings row. StandaloneSettings.xm is a separate
// development-only translation unit, never linked into uYouEnhanced.
@interface YTActionSheetAction : NSObject
+ (instancetype)actionWithTitle:(NSString *)title iconImage:(UIImage *)image style:(NSInteger)style handler:(void (^)(void))handler;
+ (instancetype)actionWithTitle:(NSString *)title iconImage:(UIImage *)image secondaryIconImage:(UIImage *)secondary accessibilityIdentifier:(NSString *)identifier handler:(void (^)(void))handler;
@end
@protocol YTAEQProtoLookup
- (id)messageForFieldNumber:(int32_t)field;
@end

static char actionMarker;
static id safeValue(id object, NSString *key) {
    if (!object) return nil;
    @try { return [object valueForKey:key]; } @catch (__unused NSException *exception) { return nil; }
}
static BOOL isPlayerSettings(NSArray *renderers) {
    for (id renderer in renderers) {
        id options = safeValue(safeValue(renderer, @"elementRenderer"), @"compatibilityOptions");
        id extension = [options respondsToSelector:@selector(messageForFieldNumber:)] ? [(id<YTAEQProtoLookup>)options messageForFieldNumber:396644439] : nil;
        NSString *identifier = safeValue(extension, @"menuItemIdentifier");
        if ([identifier isEqualToString:@"menu_item_video_quality"] || [identifier isEqualToString:@"menu_item_playback_speed"] ||
            [identifier isEqualToString:@"menu_item_audio_track"]) return YES;
    }
    return NO;
}

%group PlayerMenuIntegration
%hook YTMenuController
- (NSMutableArray *)actionsForRenderers:(NSMutableArray *)renderers fromView:(UIView *)view entry:(id)entry shouldLogItems:(BOOL)log firstResponder:(id)responder {
    NSMutableArray *actions = [%orig mutableCopy];
    if (!actions || !isPlayerSettings(renderers)) return actions;
    for (id action in actions) if ([objc_getAssociatedObject(action, &actionMarker) boolValue]) return actions;
    __weak id weakResponder = responder;
    __weak UIView *weakView = view;
    void (^handler)(void) = ^{ YTAEQPresentPanel(weakResponder, weakView); };
    Class actionClass = %c(YTActionSheetAction);
    YTActionSheetAction *action = nil;
    UIImage *icon = [UIImage systemImageNamed:@"slider.horizontal.3"];
    if ([actionClass respondsToSelector:@selector(actionWithTitle:iconImage:secondaryIconImage:accessibilityIdentifier:handler:)])
        action = [actionClass actionWithTitle:YTAEQLocalize(@"Audio EQ") iconImage:icon secondaryIconImage:nil accessibilityIdentifier:@"YTAudioEQ.playerMenu" handler:handler];
    else if ([actionClass respondsToSelector:@selector(actionWithTitle:iconImage:style:handler:)])
        action = [actionClass actionWithTitle:YTAEQLocalize(@"Audio EQ") iconImage:icon style:0 handler:handler];
    if (action) {
        objc_setAssociatedObject(action, &actionMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // Append: other tweaks' original renderer/action indexes remain valid.
        [actions addObject:action];
    }
    return actions;
}
%end
%end

%ctor {
    @autoreleasepool {
        // Class detection also permits custom bundle IDs in sideloaded IPAs.
        if (!NSClassFromString(@"YTPlayerViewController")) return;
        YTAEQInitializeSettings();
        YTAEQInstallAudioHooks();
        Class menu = NSClassFromString(@"YTMenuController");
        SEL selector = @selector(actionsForRenderers:fromView:entry:shouldLogItems:firstResponder:);
        if (class_getInstanceMethod(menu, selector)) { %init(PlayerMenuIntegration); }
    }
}
