#import <XCTest/XCTest.h>
#import "GLTrackingPolicy.h"

@interface TrackingPolicyTests : XCTestCase
@end

@implementation TrackingPolicyTests

- (CLLocation *)point:(double)x time:(double)t error:(double)error speed:(double)speed course:(double)course {
    return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(45, -122 + x / 78715)
        altitude:0 horizontalAccuracy:error verticalAccuracy:error course:course courseAccuracy:5
        speed:speed speedAccuracy:0.2 timestamp:[NSDate dateWithTimeIntervalSince1970:10000 + t]];
}

- (BOOL)observe:(GLAdaptivePolicy *)policy x:(double)x time:(double)t motion:(GLMovementState)motion require:(BOOL)required {
    CLLocation *point = [self point:x time:t error:5 speed:0 course:0];
    return [policy observeLocation:point motion:motion now:point.timestamp dwell:120 radius:30 maxAccuracy:25 requireMotion:required];
}

- (void)testAdaptiveRequiresSustainedCorroboratedStop {
    GLAdaptivePolicy *policy = [GLAdaptivePolicy new];
    XCTAssertFalse([self observe:policy x:0 time:0 motion:GLMovementStationary require:YES]);
    XCTAssertFalse([self observe:policy x:1 time:60 motion:GLMovementStationary require:YES]);
    XCTAssertFalse(policy.stationary);
    XCTAssertTrue([self observe:policy x:2 time:120 motion:GLMovementStationary require:YES]);
    XCTAssertTrue(policy.stationary);
    XCTAssertTrue([policy movementDetected]);
    XCTAssertFalse(policy.stationary);
}

- (void)testUnknownMotionPreservesDetailedAcquisitionAndReleasesQuietMode {
    GLAdaptivePolicy *policy = [GLAdaptivePolicy new];
    for(int t = 0; t <= 300; t += 30) [self observe:policy x:0 time:t motion:GLMovementUnknown require:YES];
    XCTAssertFalse(policy.stationary);
    [self observe:policy x:0 time:400 motion:GLMovementStationary require:YES];
    [self observe:policy x:0 time:460 motion:GLMovementStationary require:YES];
    [self observe:policy x:0 time:520 motion:GLMovementStationary require:YES];
    XCTAssertTrue(policy.stationary);
    XCTAssertTrue([self observe:policy x:0 time:521 motion:GLMovementUnknown require:YES]);
    XCTAssertFalse(policy.stationary);
}

- (void)testGPSOnlyAdaptiveIsAnExplicitAlternative {
    GLAdaptivePolicy *policy = [GLAdaptivePolicy new];
    for(int t = 0; t <= 120; t += 60) [self observe:policy x:0 time:t motion:GLMovementUnknown require:NO];
    XCTAssertTrue(policy.stationary);
}

- (void)testDelayedAndOutOfOrderFixesCannotEnterSleep {
    GLAdaptivePolicy *policy = [GLAdaptivePolicy new];
    CLLocation *point = [self point:0 time:0 error:5 speed:0 course:0];
    XCTAssertFalse([policy observeLocation:point motion:GLMovementStationary now:[point.timestamp dateByAddingTimeInterval:300]
        dwell:120 radius:30 maxAccuracy:25 requireMotion:YES]);
    [self observe:policy x:0 time:200 motion:GLMovementStationary require:YES];
    [self observe:policy x:0 time:100 motion:GLMovementStationary require:YES];
    [self observe:policy x:0 time:201 motion:GLMovementStationary require:YES];
    XCTAssertFalse(policy.stationary);
}

- (void)testMovingAndInaccurateLocationsDoNotEstablishStationaryDwell {
    GLAdaptivePolicy *policy = [GLAdaptivePolicy new];
    [self observe:policy x:0 time:0 motion:GLMovementStationary require:YES];
    CLLocation *poor = [self point:0 time:100 error:500 speed:0 course:0];
    [policy observeLocation:poor motion:GLMovementStationary now:poor.timestamp dwell:120 radius:30 maxAccuracy:25 requireMotion:YES];
    [self observe:policy x:0 time:121 motion:GLMovementStationary require:YES];
    [self observe:policy x:0 time:130 motion:GLMovementStationary require:YES];
    XCTAssertFalse(policy.stationary);
    XCTAssertFalse([self observe:policy x:0 time:150 motion:GLMovementMoving require:YES]);
    XCTAssertFalse(policy.stationary);
}

- (void)testReliableSpeedAndClusterExitResumeDetailedTracking {
    GLAdaptivePolicy *policy = [GLAdaptivePolicy new];
    for(int t = 0; t <= 120; t += 60) [self observe:policy x:0 time:t motion:GLMovementStationary require:YES];
    XCTAssertTrue([self observe:policy x:100 time:121 motion:GLMovementStationary require:YES]);
    XCTAssertFalse(policy.stationary);
    for(int t = 200; t <= 320; t += 60) [self observe:policy x:100 time:t motion:GLMovementStationary require:YES];
    XCTAssertTrue(policy.stationary);
    CLLocation *moving = [self point:100 time:321 error:200 speed:10 course:0];
    XCTAssertTrue([policy observeLocation:moving motion:GLMovementStationary now:moving.timestamp
        dwell:120 radius:30 maxAccuracy:25 requireMotion:YES]);
    XCTAssertFalse(policy.stationary);
}

- (void)testLegacySelectionRequiresBothLimits {
    CLLocation *start = [self point:0 time:0 error:5 speed:10 course:0];
    XCTAssertFalse([GLPointSelection acceptLocation:[self point:20 time:1 error:5 speed:10 course:90]
        previous:start anyLimit:NO distance:10 seconds:5 turn:20]);
    XCTAssertFalse([GLPointSelection acceptLocation:[self point:1 time:6 error:5 speed:0 course:0]
        previous:start anyLimit:NO distance:10 seconds:5 turn:20]);
    XCTAssertTrue([GLPointSelection acceptLocation:[self point:20 time:6 error:5 speed:10 course:0]
        previous:start anyLimit:NO distance:10 seconds:5 turn:20]);
}

- (void)testOptionalSelectionAcceptsEitherLimit {
    CLLocation *start = [self point:0 time:0 error:5 speed:10 course:0];
    for(CLLocation *point in @[[self point:20 time:1 error:5 speed:10 course:0], [self point:1 time:6 error:5 speed:0 course:0]]) {
        XCTAssertTrue([GLPointSelection acceptLocation:point previous:start anyLimit:YES distance:10 seconds:5 turn:0]);
    }
    XCTAssertFalse([GLPointSelection acceptLocation:[self point:1 time:1 error:5 speed:10 course:0]
        previous:start anyLimit:YES distance:10 seconds:5 turn:0]);
}

- (void)testDisabledORTriggersDoNotAcceptEveryPoint {
    CLLocation *start = [self point:0 time:0 error:5 speed:10 course:0];
    CLLocation *near = [self point:1 time:1 error:5 speed:10 course:0];
    XCTAssertFalse([GLPointSelection acceptLocation:near previous:start anyLimit:YES distance:10 seconds:0 turn:0]);
    XCTAssertTrue([GLPointSelection acceptLocation:near previous:start anyLimit:YES distance:0 seconds:0 turn:0]);
}

- (void)testTurnsUseShortestAngleAndIgnoreStationaryCourseJitter {
    CLLocation *start = [self point:0 time:0 error:5 speed:10 course:355];
    CLLocation *next = [self point:1 time:1 error:5 speed:10 course:5];
    XCTAssertFalse([GLPointSelection acceptLocation:next previous:start anyLimit:YES distance:0 seconds:0 turn:15]);
    XCTAssertTrue([GLPointSelection acceptLocation:next previous:start anyLimit:YES distance:0 seconds:0 turn:5]);
    XCTAssertTrue([GLPointSelection acceptLocation:[self point:1 time:1 error:5 speed:10 course:90]
        previous:start anyLimit:YES distance:100 seconds:60 turn:20]);
    XCTAssertFalse([GLPointSelection acceptLocation:[self point:1 time:1 error:5 speed:0 course:90]
        previous:start anyLimit:YES distance:100 seconds:60 turn:20]);
}

- (void)testJumpFilterRejectsIsolatedTeleportAndAcceptsReturnToTrail {
    GLPointQualityPolicy *policy = [GLPointQualityPolicy new];
    CLLocation *start = [self point:0 time:0 error:5 speed:10 course:0];
    XCTAssertFalse([policy acceptLocation:[self point:10000 time:1 error:5 speed:10 course:0] relativeTo:start maximumSpeed:40]);
    XCTAssertTrue([policy acceptLocation:[self point:10 time:2 error:5 speed:10 course:0] relativeTo:start maximumSpeed:40]);
}

- (void)testJumpFilterCorroborationWorksWithDenseFixes {
    GLPointQualityPolicy *policy = [GLPointQualityPolicy new];
    CLLocation *start = [self point:0 time:0 error:5 speed:10 course:0];
    for(NSNumber *time in @[@1, @1.2, @1.8]) {
        XCTAssertFalse([policy acceptLocation:[self point:10000 time:time.doubleValue error:5 speed:0 course:0]
            relativeTo:start maximumSpeed:40]);
    }
    XCTAssertTrue([policy acceptLocation:[self point:10000 time:2.1 error:5 speed:0 course:0] relativeTo:start maximumSpeed:40]);
}

- (void)testJumpFilterHonorsUncertaintyAndFastTravelSetting {
    GLPointQualityPolicy *policy = [GLPointQualityPolicy new];
    CLLocation *start = [self point:0 time:0 error:100 speed:0 course:0];
    XCTAssertTrue([policy acceptLocation:[self point:200 time:1 error:100 speed:0 course:0] relativeTo:start maximumSpeed:40]);
    start = [self point:0 time:0 error:5 speed:300 course:0];
    XCTAssertTrue([policy acceptLocation:[self point:300 time:1 error:5 speed:300 course:0] relativeTo:start maximumSpeed:400]);
}

- (void)testJumpFilterKeepsFlightsThatGPSSpeedSupports {
    GLPointQualityPolicy *policy = [GLPointQualityPolicy new];
    CLLocation *previous = [self point:0 time:0 error:10 speed:250 course:90];
    for(int second = 1; second <= 3; second++) {
        CLLocation *cruise = [self point:250 * second time:second error:10 speed:250 course:90];
        XCTAssertTrue([policy acceptLocation:cruise relativeTo:previous maximumSpeed:100]);
        previous = cruise;
    }
    CLLocation *start = [self point:0 time:0 error:17 speed:14 course:90];
    XCTAssertFalse([policy acceptLocation:[self point:225 time:1 error:17 speed:14 course:90] relativeTo:start maximumSpeed:100]);
    CLLocation *unsure = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(45, -122 + 250 / 78715.0)
        altitude:0 horizontalAccuracy:10 verticalAccuracy:10 course:90 courseAccuracy:5
        speed:250 speedAccuracy:50 timestamp:[NSDate dateWithTimeIntervalSince1970:10001]];
    [policy reset];
    XCTAssertFalse([policy acceptLocation:unsure relativeTo:[self point:0 time:0 error:10 speed:0 course:90] maximumSpeed:100]);
}

- (void)testResetDiscardsPendingRelocationEvidence {
    GLPointQualityPolicy *policy = [GLPointQualityPolicy new];
    CLLocation *start = [self point:0 time:0 error:5 speed:0 course:0];
    XCTAssertFalse([policy acceptLocation:[self point:10000 time:1 error:5 speed:0 course:0] relativeTo:start maximumSpeed:40]);
    [policy reset];
    XCTAssertFalse([policy acceptLocation:[self point:10000 time:3 error:5 speed:0 course:0] relativeTo:start maximumSpeed:40]);
}
@end
