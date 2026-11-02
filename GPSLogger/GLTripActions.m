//
//  GLTripActions.m
//  Overland
//

#import <UIKit/UIKit.h>
#import "GLTripActions.h"
#import "GLManager.h"
#import "Overland-Swift.h"

@interface GLQuickActionObserver : NSObject
@end

@implementation GLQuickActionObserver
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    dispatch_async(dispatch_get_main_queue(), ^{
        [GLTripActions updateQuickActions];
    });
}
@end

@implementation GLTripActions

+ (void)startTripWithMode:(NSString *)mode {
    GLManager *manager = [GLManager sharedManager];
    if(manager.tripInProgress) {
        return;
    }
    if(mode != nil && [GLTripModeStore containsModeID:mode]) {
        manager.currentTripMode = mode;
    }

    [manager startTrip];
}

+ (void)endTripRestoringTracking {
    GLManager *manager = [GLManager sharedManager];
    if(!manager.tripInProgress) {
        return;
    }
    [manager endTrip];

}

+ (void)startUpdatingQuickActions {
    static GLQuickActionObserver *observer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        observer = [GLQuickActionObserver new];
        [NSUserDefaults.standardUserDefaults addObserver:observer forKeyPath:GLTripStartTimeDefaultsName options:0 context:NULL];
    });
    [self updateQuickActions];
}

+ (NSArray<UIApplicationShortcutItem *> *)quickActionItems {
    if([GLManager sharedManager].tripInProgress) {
        UIApplicationShortcutIcon *icon = [UIApplicationShortcutIcon iconWithSystemImageName:@"stop.circle.fill"];
        return @[[[UIApplicationShortcutItem alloc] initWithType:@"stop" localizedTitle:@"Stop Trip"
                                               localizedSubtitle:nil icon:icon userInfo:nil]];
    }
    NSMutableArray<NSString *> *modes = [NSMutableArray array];
    for(NSString *mode in [[GLManager sharedManager] tripModesByFrequency]) if([GLTripModeStore containsModeID:mode]) [modes addObject:mode];
    for(NSString *mode in GLTripModeStore.allModeIDs) if(![modes containsObject:mode]) [modes addObject:mode];
    NSMutableArray<UIApplicationShortcutItem *> *items = [NSMutableArray array];
    for(NSString *mode in modes) {
        if(items.count == 4) break;
        NSString *symbol = [GLTripModeStore symbolForModeID:mode];
        UIApplicationShortcutIcon *icon = [GLTripModeStore isCustomSymbol:symbol]
            ? [UIApplicationShortcutIcon iconWithTemplateImageName:symbol]
            : [UIApplicationShortcutIcon iconWithSystemImageName:symbol];
        [items addObject:[[UIApplicationShortcutItem alloc] initWithType:mode localizedTitle:[GLTripModeStore nameForModeID:mode]
                                                       localizedSubtitle:nil icon:icon userInfo:nil]];
    }
    return items;
}

+ (void)updateQuickActions {
    UIApplication.sharedApplication.shortcutItems = [self quickActionItems];
}

@end
