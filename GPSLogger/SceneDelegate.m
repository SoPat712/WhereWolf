//
//  SceneDelegate.m
//  Overland
//
//  Created by Aaron Parecki on 12/10/23.
//  Copyright © 2023 Aaron Parecki. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "SceneDelegate.h"
#import "GLManager.h"
#import "GLTripActions.h"
#import "NSArray+map.h"
#import "Overland-Swift.h"
@import SwiftUI;

@implementation SceneDelegate

- (void)sceneWillEnterForeground:(UIScene *)scene {
    
    if([[NSUserDefaults standardUserDefaults] boolForKey:GLPurgeQueueOnNextLaunchDefaultsName]
       && [[GLManager sharedManager] deleteAllData]) {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLPurgeQueueOnNextLaunchDefaultsName];
    }

}


- (void)sceneDidEnterBackground:(UIScene *)scene {
    
    NSLog(@"Application is entering the background");
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[GLManager sharedManager] applicationDidEnterBackground];
}


- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    UIOpenURLContext *context = [URLContexts anyObject];
    NSURL *url = context.URL;
    
    if([[url host] isEqualToString:@"tracker"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"OverlandOpenTracker" object:nil];
    }
    if([[url host] isEqualToString:@"setup"]) {
        NSURLComponents *urlComponents = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSArray *queryItems  = urlComponents.queryItems;
        NSString *endpoint = [self queryValueForKey:@"url" fromQueryItems:queryItems];
        NSString *token    = [self queryValueForKey:@"token" fromQueryItems:queryItems];
        NSString *deviceId = [self queryValueForKey:@"device_id" fromQueryItems:queryItems];
        NSString *uniqueId = [self queryValueForKey:@"unique_id" fromQueryItems:queryItems];
        if(![GLManager isValidEndpoint:endpoint]) return;
        NSLog(@"Applying server configuration");
        [[GLManager sharedManager] saveNewDeviceId:deviceId];
        [[GLManager sharedManager] saveNewAPIEndpoint:endpoint andAccessToken:token];
        [[NSUserDefaults standardUserDefaults] setBool:[uniqueId isEqualToString:@"yes"] forKey:GLIncludeUniqueIdDefaultsName];
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        for(NSURLQueryItem *item in queryItems) {
            if([item.name hasPrefix:@"header_"] && item.name.length > 7 && item.value) {
                headers[[item.name substringFromIndex:7]] = item.value;
            }
        }
        if(headers.count > 0) [GLManager sharedManager].customHTTPHeaders = headers;
    }
}

- (NSString *)queryValueForKey:(NSString *)key fromQueryItems:(NSArray *)queryItems
{
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name=%@", key];
    NSURLQueryItem *queryItem = [[queryItems filteredArrayUsingPredicate:predicate] firstObject];
    return queryItem.value;
}

#pragma mark - Quick Actions

// https://developer.apple.com/documentation/uikit/menus_and_shortcuts/add_home_screen_quick_actions?language=objc

- (void)sceneWillResignActive:(UIScene *)scene {
    
    [[GLManager sharedManager] applicationWillResignActive];

    UIApplication *app = UIApplication.sharedApplication;

    // Offer frequent travel modes when idle and Stop Trip while recording a trip.
    if(![GLManager sharedManager].tripInProgress) {
        NSArray *frequent = [[GLManager sharedManager] tripModesByFrequency];
        NSMutableArray *tripModes = [NSMutableArray array];
        for(NSString *mode in frequent) if([GLTripModeStore containsModeID:mode]) [tripModes addObject:mode];
        for(NSString *mode in GLTripModeStore.allModeIDs) if(![tripModes containsObject:mode]) [tripModes addObject:mode];
        if(tripModes.count > 4) [tripModes removeObjectsInRange:NSMakeRange(4, tripModes.count - 4)];
        app.shortcutItems = [tripModes mapObjectsUsingBlock:^id(id obj, NSUInteger idx) {
            NSString *symbol = [GLTripModeStore symbolForModeID:obj];
            UIApplicationShortcutIcon *icon = [GLTripModeStore isCustomSymbol:symbol]
                ? [UIApplicationShortcutIcon iconWithTemplateImageName:symbol]
                : [UIApplicationShortcutIcon iconWithSystemImageName:symbol];
            return [[UIApplicationShortcutItem alloc] initWithType:obj
                                                    localizedTitle:[GLTripModeStore nameForModeID:obj]
                                                 localizedSubtitle:nil
                                                              icon:icon
                                                          userInfo:nil];
        }];
    } else {
        
        UIApplicationShortcutIcon *icon = [UIApplicationShortcutIcon iconWithSystemImageName:@"stop.circle.fill"];
        UIApplicationShortcutItem *item = [[UIApplicationShortcutItem alloc] initWithType:@"stop"
                                                                           localizedTitle:@"Stop Trip"
                                                                        localizedSubtitle:nil
                                                                                     icon:icon
                                                                                 userInfo:nil];
        app.shortcutItems = @[item];
    }
}


- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    // Cold-launch setup links and quick actions arrive in connectionOptions.

    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = [OverlandRootHosting makeRoot];
    [self.window makeKeyAndVisible];

    if(connectionOptions.URLContexts.count > 0) {
        [self scene:scene openURLContexts:connectionOptions.URLContexts];
    }
    for(NSUserActivity *activity in connectionOptions.userActivities) [self handleTrackingActivity:activity];
    if(connectionOptions.shortcutItem != nil) {
        [self handleLaunchFromShortcutItem:connectionOptions.shortcutItem];
    }
}

- (void)windowScene:(UIWindowScene *)windowScene performActionForShortcutItem:(UIApplicationShortcutItem *)shortcutItem completionHandler:(void (^)(BOOL))completionHandler {
    [self handleLaunchFromShortcutItem:shortcutItem];
    completionHandler(YES);
}

- (void)handleLaunchFromShortcutItem:(UIApplicationShortcutItem *)shortcutItem {
    if([shortcutItem.type isEqualToString:@"stop"]) {
        [GLTripActions endTripRestoringTracking];
    } else if([[GLManager GLTripModes] containsObject:shortcutItem.type]) {
        [GLTripActions startTripWithMode:shortcutItem.type];
    }
}


- (void)scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)activity {
    [self handleTrackingActivity:activity];
}

- (void)handleTrackingActivity:(NSUserActivity *)activity {
    NSString *type = [NSString stringWithFormat:@"%@.startTracking", NSBundle.mainBundle.bundleIdentifier];
    if([activity.activityType isEqual:type] || [activity.activityType isEqual:@"com.aaronpk.overland.startTracking"]) {
        [[GLManager sharedManager] startAllUpdates];
    }
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    [[GLManager sharedManager] syncTripLiveActivity];
}

@end
