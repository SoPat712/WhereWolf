//
//  SceneDelegate.m
//  WhereWolf
//
//  Created by Aaron Parecki on 12/10/23.
//  Copyright © 2023 Aaron Parecki. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "SceneDelegate.h"
#import "GLManager.h"
#import "GLTripActions.h"
#import "NSArray+map.h"
#import "WhereWolf-Swift.h"
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
        [[NSNotificationCenter defaultCenter] postNotificationName:@"WhereWolfOpenTracker" object:nil];
    }
    if([[url host] isEqualToString:@"setup"]) {
        [WhereWolfSetupURLHandler apply:url];
    }
}

#pragma mark - Quick Actions

// https://developer.apple.com/documentation/uikit/menus_and_shortcuts/add_home_screen_quick_actions?language=objc

- (void)sceneWillResignActive:(UIScene *)scene {
    
    [[GLManager sharedManager] applicationWillResignActive];
    [GLTripActions updateQuickActions];
}


- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    // Cold-launch setup links and quick actions arrive in connectionOptions.

    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = [WhereWolfRootHosting makeRoot];
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
        [IntentDonations tripEnded];
    } else if([GLTripModeStore containsModeID:shortcutItem.type]) {
        [GLTripActions startTripWithMode:shortcutItem.type];
        [IntentDonations tripStartedWithMode:shortcutItem.type];
    }
}


- (void)scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)activity {
    [self handleTrackingActivity:activity];
}

- (void)handleTrackingActivity:(NSUserActivity *)activity {
    NSString *type = [NSString stringWithFormat:@"%@.startTracking", NSBundle.mainBundle.bundleIdentifier];
    if([activity.activityType isEqual:type]) {
        [[GLManager sharedManager] startAllUpdates];
    }
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    [[GLManager sharedManager] syncTripLiveActivity];
}

@end
