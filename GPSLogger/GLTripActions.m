//
//  GLTripActions.m
//  Overland
//

#import "GLTripActions.h"
#import "GLManager.h"
#import "Overland-Swift.h"

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

@end
