#import <XCTest/XCTest.h>
#import "GLLocationHealth.h"
#import <math.h>

@interface LocationHealthTests : XCTestCase
@property GLLocationHealthPolicy *policy;
@end

@implementation LocationHealthTests
- (void)setUp {
    self.policy = [GLLocationHealthPolicy new];
    [self.policy resetAtUptime:100];
    [self.policy setExpected:YES uptime:100];
}
- (NSDate *)date:(double)uptime { return [NSDate dateWithTimeIntervalSince1970:1700000000 + uptime]; }
- (CLLocation *)fix:(double)uptime accuracy:(double)accuracy {
    return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(45, -122) altitude:0
        horizontalAccuracy:accuracy verticalAccuracy:5 timestamp:[self date:uptime]];
}
- (BOOL)evaluate:(double)uptime retry:(BOOL)retry {
    return [self.policy evaluateAtUptime:uptime date:[self date:uptime] automaticRetry:retry];
}
- (void)receive:(double)uptime recorded:(double)recorded accuracy:(double)accuracy {
    [self.policy observeLocations:@[[self fix:recorded accuracy:accuracy]] uptime:uptime date:[self date:uptime]];
}
- (void)testRetriesWaitBackOffAndStopAfterThreeAttempts {
    XCTAssertFalse([self evaluate:219 retry:YES]);
    XCTAssertTrue([self evaluate:220 retry:YES]);
    XCTAssertFalse([self evaluate:459 retry:YES]);
    XCTAssertTrue([self evaluate:460 retry:YES]);
    XCTAssertFalse([self evaluate:1059 retry:YES]);
    XCTAssertTrue([self evaluate:1060 retry:YES]);
    XCTAssertFalse([self evaluate:100000 retry:YES]);
    XCTAssertEqual(self.policy.attempts, 3);
    NSArray *events = [self.policy takeEvents];
    XCTAssertEqual([events filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == 'retry_requested'"]].count, 3);
    XCTAssertEqual([events filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == 'updates_missing'"]].count, 1);
}
- (void)testOldCallbacksDoNotResetTheRetryBudget {
    [self receive:100 recorded:100 accuracy:5];
    [self receive:220 recorded:100 accuracy:5];
    XCTAssertTrue([self evaluate:220 retry:YES]);
    [self receive:460 recorded:100 accuracy:5];
    XCTAssertTrue([self evaluate:460 retry:YES]);
    XCTAssertEqual(self.policy.attempts, 2);
    XCTAssertEqualObjects([self.policy snapshotAtUptime:460][@"state"], @"updates_outdated");
}
- (void)testFreshReadingsResetTheBudgetAndRecordTheObservedGap {
    XCTAssertTrue([self evaluate:220 retry:YES]);
    [self receive:230 recorded:230 accuracy:5];
    XCTAssertEqual(self.policy.attempts, 0);
    XCTAssertFalse([self evaluate:349 retry:YES]);
    XCTAssertTrue([self evaluate:350 retry:YES]);
    NSDictionary *resumed = [[self.policy takeEvents] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == 'updates_resumed'"]].firstObject;
    XCTAssertEqual([resumed[@"seconds"] doubleValue], 130);
    XCTAssertEqual([resumed[@"attempt"] unsignedIntegerValue], 1);
}
- (void)testAnEmptyOrUnusableCallbackIsNotAFreshReading {
    [self.policy observeLocations:@[] uptime:200 date:[self date:200]];
    [self receive:210 recorded:210 accuracy:-1];
    [self receive:215 recorded:300 accuracy:5];
    XCTAssertTrue([self evaluate:220 retry:YES]);
    XCTAssertEqualObjects([self.policy snapshotAtUptime:220][@"state"], @"updates_outdated");
}
- (void)testLoggingAloneNeverRequestsARestart {
    XCTAssertFalse([self evaluate:220 retry:NO]);
    XCTAssertFalse([self evaluate:10000 retry:NO]);
    XCTAssertEqual(self.policy.attempts, 0);
    XCTAssertEqual([self.policy takeEvents].count, 1);
}
- (void)testFreshFilteredPointsDoNotRestartGPS {
    for(int t = 100; t <= 250; t += 10) {
        [self receive:t recorded:t accuracy:500];
        [self.policy recordSaved:0 rejected:@{@"accuracy": @1} uptime:t date:[self date:t]];
        XCTAssertFalse([self evaluate:t retry:YES]);
    }
    XCTAssertEqual(self.policy.attempts, 0);
    XCTAssertEqualObjects([self.policy snapshotAtUptime:250][@"state"], @"points_skipped");
    NSDictionary *event = [[self.policy takeEvents] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == 'points_skipped'"]].firstObject;
    XCTAssertGreaterThan([event[@"rejected"][@"accuracy"] intValue], 0);
    [self.policy recordSaved:1 rejected:@{} uptime:251 date:[self date:251]];
    XCTAssertEqualObjects([self.policy takeEvents].firstObject[@"kind"], @"saving_resumed");
}
- (void)testAStoredOldPointDoesNotPretendTheLocationStreamIsFresh {
    [self.policy recordSaved:1 rejected:@{} uptime:219 date:[self date:219]];
    XCTAssertTrue([self evaluate:220 retry:YES]);
}
- (void)testPausesStopChecksAndResumeGetsAFullGracePeriod {
    XCTAssertTrue([self evaluate:220 retry:YES]);
    [self.policy setExpected:NO uptime:230];
    XCTAssertFalse([self evaluate:10000 retry:YES]);
    [self.policy setExpected:YES uptime:10000];
    XCTAssertFalse([self evaluate:10119 retry:YES]);
    XCTAssertTrue([self evaluate:10120 retry:YES]);
    XCTAssertEqual(self.policy.attempts, 2);
}
- (void)testAnExplicitResetClearsAnExhaustedBudget {
    [self evaluate:220 retry:YES]; [self evaluate:460 retry:YES]; [self evaluate:1060 retry:YES];
    [self.policy resetAtUptime:2000];
    XCTAssertEqual(self.policy.attempts, 0);
    XCTAssertFalse([self evaluate:2119 retry:YES]);
    XCTAssertTrue([self evaluate:2120 retry:YES]);
}
- (void)testChangingThePhoneClockDoesNotChangeElapsedTime {
    NSDate *jumped = [[self date:150] dateByAddingTimeInterval:86400];
    XCTAssertFalse([self.policy evaluateAtUptime:150 date:jumped automaticRetry:YES]);
    XCTAssertTrue([self.policy evaluateAtUptime:220 date:jumped automaticRetry:YES]);
}
- (void)testMovingThePhoneClockBackDoesNotBlockNewFreshReadings {
    [self.policy observeLocations:@[[self fix:1500 accuracy:5]] uptime:100 date:[self date:1500]];
    XCTAssertTrue([self.policy evaluateAtUptime:220 date:[self date:200] automaticRetry:YES]);
    [self.policy observeLocations:@[[self fix:210 accuracy:5]] uptime:230 date:[self date:210]];
    XCTAssertEqual(self.policy.attempts, 0);
    XCTAssertEqualObjects([self.policy snapshotAtUptime:230][@"state"], @"receiving");
}
- (void)testRetryThresholdHasSafeBounds {
    self.policy.retryAfter = 0; XCTAssertEqual(self.policy.retryAfter, 60);
    self.policy.retryAfter = 100000; XCTAssertEqual(self.policy.retryAfter, 1800);
    self.policy.retryAfter = NAN; XCTAssertEqual(self.policy.retryAfter, 120);
}
@end

@interface LocationHealthLogTests : XCTestCase
@property NSURL *directory;
@property GLLocationHealthLog *log;
@end

@implementation LocationHealthLogTests
- (void)setUp {
    self.directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    self.log = [[GLLocationHealthLog alloc] initWithDirectory:self.directory];
}
- (void)tearDown { [NSFileManager.defaultManager removeItemAtURL:self.directory error:NULL]; }
- (NSArray<NSDictionary *> *)load {
    XCTestExpectation *done = [self expectationWithDescription:@"Health log loaded"];
    __block NSArray *events;
    [self.log load:^(NSArray *values) { events = values; [done fulfill]; }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    return events;
}
- (NSDictionary *)event:(int)number {
    return @{@"id": [NSString stringWithFormat:@"%d", number], @"kind": @"updates_missing", @"time": @(NSDate.date.timeIntervalSince1970)};
}
- (void)testLogSurvivesReopeningAndStripsLocationAndServerData {
    NSMutableDictionary *entry = [[self event:1] mutableCopy];
    entry[@"latitude"] = @45; entry[@"url"] = @"https://secret.test"; entry[@"token"] = @"secret";
    entry[@"rejected"] = @{@"accuracy": @2, @"latitude": @45};
    [self.log append:entry];
    XCTAssertEqual(self.load.count, 1);
    self.log = [[GLLocationHealthLog alloc] initWithDirectory:self.directory];
    NSDictionary *saved = self.load.firstObject;
    XCTAssertNil(saved[@"latitude"]); XCTAssertNil(saved[@"url"]); XCTAssertNil(saved[@"token"]);
    XCTAssertEqualObjects(saved[@"rejected"], (@{@"accuracy": @2}));
    NSNumber *excluded;
    [self.directory getResourceValue:&excluded forKey:NSURLIsExcludedFromBackupKey error:nil];
    XCTAssertTrue(excluded.boolValue);
#if !TARGET_OS_SIMULATOR
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:[[self.directory URLByAppendingPathComponent:@"events.json"] path] error:nil];
    XCTAssertEqualObjects(attributes[NSFileProtectionKey], NSFileProtectionCompleteUntilFirstUserAuthentication);
#endif
}
- (void)testLogKeepsOnlyTwoHundredEvents {
    for(int i = 0; i < 205; i++) [self.log append:[self event:i]];
    NSArray *events = self.load;
    XCTAssertEqual(events.count, 200);
    XCTAssertEqualObjects(events.firstObject[@"id"], @"5");
    XCTAssertEqualObjects(events.lastObject[@"id"], @"204");
}
- (void)testOldAndMalformedEntriesAreOmitted {
    NSMutableDictionary *old = [[self event:1] mutableCopy];
    old[@"time"] = @(NSDate.date.timeIntervalSince1970 - 8 * 86400);
    [self.log append:old];
    [self.log append:@{@"kind": @"missing_time"}];
    [self.log append:[self event:2]];
    XCTAssertEqual(self.load.count, 1);
    XCTAssertEqualObjects(self.load.firstObject[@"id"], @"2");
}
- (void)testReadingTheLogRemovesExpiredEntriesFromTheFile {
    NSMutableDictionary *old = [[self event:1] mutableCopy];
    old[@"time"] = @(NSDate.date.timeIntervalSince1970 - 8 * 86400);
    [self.log append:old];
    XCTAssertEqual(self.load.count, 0);
    NSData *data = [NSData dataWithContentsOfURL:[self.directory URLByAppendingPathComponent:@"events.json"]];
    NSArray *saved = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    XCTAssertEqualObjects(saved, @[]);
}
- (void)testClearingTheLogIsSerializedAfterPendingWrites {
    [self.log append:[self event:1]];
    XCTestExpectation *done = [self expectationWithDescription:@"Health log cleared"];
    [self.log clear:^{ [done fulfill]; }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertEqual(self.load.count, 0);
}
- (void)testAnOversizedOrInvalidFileDoesNotLoad {
    [NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *file = [self.directory URLByAppendingPathComponent:@"events.json"];
    [[NSMutableData dataWithLength:300 * 1024] writeToURL:file atomically:YES];
    XCTAssertEqual(self.load.count, 0);
    [@"invalid json" writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
    XCTAssertEqual(self.load.count, 0);
}
@end

@interface LocationSaveAllowanceTests : XCTestCase
@end
@implementation LocationSaveAllowanceTests
- (void)testCompletionAndLaterExpirationEndTheAllowanceOnlyOnce {
    __block void (^expiration)(void);
    __block int ends = 0;
    GLLocationSaveAllowance *allowance = [[GLLocationSaveAllowance alloc] initWithBegin:^UIBackgroundTaskIdentifier(void (^callback)(void)) {
        expiration = callback; return 17;
    } end:^(UIBackgroundTaskIdentifier identifier) { XCTAssertEqual(identifier, 17); ends++; }];
    [allowance finish]; [allowance finish]; expiration();
    XCTAssertEqual(ends, 1);
}
- (void)testExpirationBeforeCompletionEndsTheAllowanceOnlyOnce {
    __block void (^expiration)(void);
    __block int ends = 0;
    GLLocationSaveAllowance *allowance = [[GLLocationSaveAllowance alloc] initWithBegin:^UIBackgroundTaskIdentifier(void (^callback)(void)) {
        expiration = callback; return 17;
    } end:^(UIBackgroundTaskIdentifier identifier) { ends++; }];
    expiration(); [allowance finish];
    XCTAssertEqual(ends, 1);
}
- (void)testImmediateExpirationStillEndsTheReturnedIdentifier {
    __block int ends = 0;
    GLLocationSaveAllowance *allowance = [[GLLocationSaveAllowance alloc] initWithBegin:^UIBackgroundTaskIdentifier(void (^callback)(void)) {
        callback(); return 17;
    } end:^(UIBackgroundTaskIdentifier identifier) { XCTAssertEqual(identifier, 17); ends++; }];
    [allowance finish];
    XCTAssertEqual(ends, 1);
}
- (void)testAnUnavailableAllowanceDoesNotTryToEndAnInvalidIdentifier {
    __block int ends = 0;
    GLLocationSaveAllowance *allowance = [[GLLocationSaveAllowance alloc] initWithBegin:^UIBackgroundTaskIdentifier(void (^callback)(void)) {
        return UIBackgroundTaskInvalid;
    } end:^(UIBackgroundTaskIdentifier identifier) { ends++; }];
    [allowance finish];
    XCTAssertEqual(ends, 0);
}
@end
