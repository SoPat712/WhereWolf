#import "GLTrackingPolicy.h"
#import <math.h>

@interface GLAdaptivePolicy ()
@property (nonatomic) BOOL stationary;
@property (nonatomic, strong) CLLocation *anchor;
@property (nonatomic, strong) NSDate *dwellStart;
@property (nonatomic, strong) NSDate *lastObservation;
@property (nonatomic) NSUInteger sampleCount;
@end

@implementation GLAdaptivePolicy

- (void)reset {
    self.stationary = NO;
    self.anchor = nil;
    self.dwellStart = nil;
    self.lastObservation = nil;
    self.sampleCount = 0;
}

- (BOOL)movementDetected {
    BOOL changed = self.stationary;
    [self reset];
    return changed;
}

- (BOOL)observeLocation:(CLLocation *)location motion:(GLMovementState)motion now:(NSDate *)now
                 dwell:(NSTimeInterval)dwell radius:(CLLocationDistance)radius
           maxAccuracy:(CLLocationAccuracy)accuracy requireMotion:(BOOL)requireMotion {
    NSTimeInterval age = [now timeIntervalSinceDate:location.timestamp];
    if(!CLLocationCoordinate2DIsValid(location.coordinate) || !isfinite(location.horizontalAccuracy)
       || location.horizontalAccuracy < 0 || age < 0 || age > 20
       || (self.lastObservation && [location.timestamp compare:self.lastObservation] != NSOrderedDescending)) return NO;
    self.lastObservation = location.timestamp;
    BOOL movingSpeed = isfinite(location.speed) && location.speed >= 0.7
        && isfinite(location.speedAccuracy) && location.speedAccuracy >= 0 && location.speedAccuracy <= 1.5;
    if(motion == GLMovementMoving || movingSpeed || (requireMotion && motion == GLMovementUnknown)) {
        BOOL changed = [self movementDetected];
        self.lastObservation = location.timestamp;
        return changed;
    }
    if(location.horizontalAccuracy > accuracy) {
        if(!self.stationary) {
            self.dwellStart = nil;
            self.sampleCount = 0;
            self.anchor = nil;
        }
        return NO;
    }
    if(!self.anchor || [location distanceFromLocation:self.anchor] > radius) {
        BOOL changed = self.stationary;
        self.stationary = NO;
        self.anchor = location;
        self.dwellStart = location.timestamp;
        self.sampleCount = 1;
        return changed;
    }
    self.sampleCount++;
    if(!self.stationary && self.sampleCount >= 3
       && [location.timestamp timeIntervalSinceDate:self.dwellStart] >= dwell) {
        self.stationary = YES;
        return YES;
    }
    return NO;
}
@end

@interface GLPointQualityPolicy ()
@property (nonatomic, strong) CLLocation *pending;
@end

@implementation GLPointQualityPolicy

- (void)reset { self.pending = nil; }

- (BOOL)plausible:(CLLocation *)location after:(CLLocation *)previous maximumSpeed:(CLLocationSpeed)speed {
    NSTimeInterval elapsed = [location.timestamp timeIntervalSinceDate:previous.timestamp];
    if(elapsed <= 0 || !isfinite(elapsed)) return NO;
    CLLocationDistance excess = MAX(0, [location distanceFromLocation:previous]
        - MAX(0, previous.horizontalAccuracy) - MAX(0, location.horizontalAccuracy));
    return excess <= speed * elapsed;
}

- (BOOL)acceptLocation:(CLLocation *)location relativeTo:(CLLocation *)previous
          maximumSpeed:(CLLocationSpeed)speed {
    if(!previous || [self plausible:location after:previous maximumSpeed:speed]) {
        self.pending = nil;
        return YES;
    }
    // A corroborating fix permits genuine relocation without locking onto an old baseline forever.
    if(self.pending && [self plausible:location after:self.pending maximumSpeed:speed]) {
        if([location.timestamp timeIntervalSinceDate:self.pending.timestamp] < 1) return NO;
        self.pending = nil;
        return YES;
    }
    self.pending = location;
    return NO;
}
@end

@implementation GLPointSelection
+ (BOOL)acceptLocation:(CLLocation *)location previous:(CLLocation *)previous
             anyLimit:(BOOL)anyLimit distance:(CLLocationDistance)distance
              seconds:(NSTimeInterval)seconds turn:(CLLocationDirection)turn {
    if(!previous) return YES;
    NSTimeInterval elapsed = [location.timestamp timeIntervalSinceDate:previous.timestamp];
    if(elapsed < 0) return NO;
    BOOL distancePass = distance <= 0 || [location distanceFromLocation:previous] >= distance;
    BOOL timePass = seconds <= 0 || elapsed >= seconds;
    if(!anyLimit) return distancePass && timePass;
    if(distance <= 0 && seconds <= 0 && turn <= 0) return YES;
    BOOL turnPass = NO;
    if(turn > 0 && elapsed > 0 && location.speed >= 0.7 && previous.speed >= 0.7
       && location.course >= 0 && previous.course >= 0
       && location.courseAccuracy >= 0 && location.courseAccuracy <= 30
       && previous.courseAccuracy >= 0 && previous.courseAccuracy <= 30) {
        double angle = fabs(location.course - previous.course);
        angle = fmod(angle, 360);
        angle = MIN(angle, 360 - angle);
        turnPass = angle >= turn;
    }
    return (distance > 0 && distancePass) || (seconds > 0 && timePass) || turnPass;
}
@end
