#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sqlite3.h>
#import "GLManager.h"
#import "GLTripActions.h"
#import "GLTrackingPolicy.h"
#import "GLLocationHealth.h"
#import "LOLDatabase.h"
#import "FMDatabase.h"

@interface GLManager (Testing)
+ (NSTimeInterval)retryAfter:(NSString *)value now:(NSDate *)now;
+ (NSString *)iso8601DateStringFromDate:(NSDate *)date;
+ (NSTimeInterval)uploadBackoffForFailure:(NSUInteger)failure jitter:(double)jitter;
- (BOOL)reminderEligible;
- (void)scheduleLocalNotification;
- (void)cancelLocalNotification;
- (BOOL)observeMovementLocation:(CLLocation *)location;
- (void)resetStationaryAnchors;
- (void)setupHTTPClient;
- (NSArray<CLLocation *> *)locationsByApplyingWifiZone:(NSArray<CLLocation *> *)locations networkInfo:(NSDictionary *)info;
- (void)sendQueueIfTimeElapsed;
- (void)sendQueueIfNotInProgress;
- (void)sendTimeExpired;
- (void)processLocations:(NSArray *)locations;
- (void)updateSettingsFromResponse:(id)response;
- (NSDictionary *)owntracksDictionaryFromLocation:(CLLocation *)location;
- (void)writeTripToDB:(BOOL)autopause steps:(NSInteger)steps;
- (void)writeTripToDB:(BOOL)autopause steps:(NSInteger)steps endDate:(NSDate *)endDate location:(CLLocation *)location;
- (NSDate *)stopDateForPrompt:(NSDictionary *)info;
- (void)wifiOnlySendingChanged;
- (void)applyTrackingConfiguration;
- (void)restoreTrackingState;
- (void)rememberMotion:(CMMotionActivity *)activity;
- (void)processMotionActivity:(CMMotionActivity *)activity;
- (NSArray *)motionArrayForDate:(NSDate *)date;
- (void)deferUploadForResponse:(NSHTTPURLResponse *)response error:(NSError *)error;
- (void)scheduleUploadAfter:(NSTimeInterval)delay;
- (void)rememberWifiNetworkInfo:(NSDictionary *)info;
- (void)evaluateLocationHealth;
- (BOOL)processLocationBatch:(NSArray *)locations;
@end

@protocol GLWifiOnlySendingTesting <NSObject>
+ (id<GLWifiOnlySendingTesting>)shared;
- (void)setForTestingWithEnabled:(BOOL)enabled expensive:(NSNumber *)expensive;
@end

@interface TestUploadManager : GLManager
@property NSTimeInterval scheduledUploadDelay;
@end
@implementation TestUploadManager
- (void)scheduleUploadAfter:(NSTimeInterval)delay {
    self.scheduledUploadDelay = delay;
    [super scheduleUploadAfter:delay];
}
@end

@interface TestLocationManager : CLLocationManager
@property NSUInteger startCount;
@property NSUInteger stopCount;
@property NSUInteger significantStartCount;
@property NSUInteger significantStopCount;
@property NSNumber *authorizationOverride;
@property NSMutableSet<CLRegion *> *regions;
@end
@implementation TestLocationManager
- (CLAuthorizationStatus)authorizationStatus { return self.authorizationOverride ? self.authorizationOverride.intValue : kCLAuthorizationStatusAuthorizedAlways; }
- (void)startUpdatingLocation { self.startCount++; }
- (void)stopUpdatingLocation { self.stopCount++; }
+ (BOOL)significantLocationChangeMonitoringAvailable { return YES; }
- (void)startMonitoringSignificantLocationChanges { self.significantStartCount++; }
- (void)stopMonitoringSignificantLocationChanges { self.significantStopCount++; }
- (void)startMonitoringVisits {}
- (void)stopMonitoringVisits {}
- (NSSet<CLRegion *> *)monitoredRegions { return self.regions.copy ?: [NSSet set]; }
- (void)startMonitoringForRegion:(CLRegion *)region {
    if(!self.regions) self.regions = [NSMutableSet set];
    [self.regions addObject:region];
}
- (void)stopMonitoringForRegion:(CLRegion *)region { [self.regions removeObject:region]; }
@end

@interface TestUnavailableRecoveryManager : TestLocationManager
@end
@implementation TestUnavailableRecoveryManager
+ (BOOL)significantLocationChangeMonitoringAvailable { return NO; }
@end

@interface TestLocationHealthManager : GLManager
@property NSTimeInterval healthUptime;
@property BOOL saveAllowanceActive;
@property BOOL protectedDuringProcessing;
@property NSUInteger allowanceEndCount;
@property NSURL *healthDirectory;
@end
@implementation TestLocationHealthManager
- (NSTimeInterval)locationHealthUptime { return self.healthUptime; }
- (GLLocationSaveAllowance *)newLocationSaveAllowance {
    __weak typeof(self) weakSelf = self;
    return [[GLLocationSaveAllowance alloc] initWithBegin:^UIBackgroundTaskIdentifier(void (^expiration)(void)) {
        weakSelf.saveAllowanceActive = YES;
        return 17;
    } end:^(UIBackgroundTaskIdentifier identifier) {
        weakSelf.saveAllowanceActive = NO;
        weakSelf.allowanceEndCount++;
    }];
}
- (BOOL)processLocationBatch:(NSArray *)locations {
    BOOL saved = [super processLocationBatch:locations];
    self.protectedDuringProcessing = self.saveAllowanceActive;
    return saved;
}
@end

@interface TestMotionActivity : CMMotionActivity
@property (nonatomic, strong) NSDate *date;
@property BOOL inCar;
@end
@implementation TestMotionActivity
- (NSDate *)startDate { return self.date; }
- (BOOL)walking { return !self.inCar; }
- (BOOL)automotive { return self.inCar; }
- (BOOL)stationary { return NO; }
- (CMMotionActivityConfidence)confidence { return CMMotionActivityConfidenceHigh; }
@end

@interface TestMotionManager : GLManager
@end
@implementation TestMotionManager
- (NSString *)motionAuthorizationStatus { return @"Allowed"; }
@end

@interface TestCloudWriter : GLCloudFileWriter
@property NSArray *captured;
@property (copy) void (^finish)(NSString *);
@end
@implementation TestCloudWriter
- (void)writeFeatures:(NSArray *)features mode:(GLCloudFileMode)mode completion:(void (^)(NSString *))completion {
    self.captured = features;
    self.finish = completion;
}
@end

@interface TestStationaryActivity : TestMotionActivity
@end
@implementation TestStationaryActivity
- (BOOL)walking { return NO; }
- (BOOL)stationary { return YES; }
- (CMMotionActivityConfidence)confidence { return CMMotionActivityConfidenceLow; }
@end

@interface OverlandTestProtocol : NSURLProtocol
@end

static void (^requestHandler)(OverlandTestProtocol *);
@implementation OverlandTestProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return [request.URL.host isEqualToString:@"overland.test"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading { if(requestHandler) requestHandler(self); }
- (void)stopLoading {}
- (void)respond:(NSString *)body status:(NSInteger)status {
    [self respond:body status:status headers:@{}];
}
- (void)respond:(NSString *)body status:(NSInteger)status headers:(NSDictionary *)headers {
    NSMutableDictionary *fields = [@{@"Content-Type": @"application/json"} mutableCopy];
    [fields addEntriesFromDictionary:headers];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:fields];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:[body dataUsingEncoding:NSUTF8StringEncoding]];
    [self.client URLProtocolDidFinishLoading:self];
}
@end

@interface NSURLSessionConfiguration (OverlandTests)
+ (NSURLSessionConfiguration *)overland_testConfiguration;
@end

@implementation NSURLSessionConfiguration (OverlandTests)
+ (NSURLSessionConfiguration *)overland_testConfiguration {
    NSURLSessionConfiguration *config = [self overland_testConfiguration];
    config.protocolClasses = [@[OverlandTestProtocol.class] arrayByAddingObjectsFromArray:config.protocolClasses ?: @[]];
    return config;
}
@end

// Keep fixture writes out of the running app host's preference domain.
static NSUserDefaults *fixtureDefaults;

@interface NSUserDefaults (OverlandTests)
+ (NSUserDefaults *)overland_testDefaults;
@end

@implementation NSUserDefaults (OverlandTests)
+ (NSUserDefaults *)overland_testDefaults {
    return fixtureDefaults ?: [self overland_testDefaults];
}
@end

static int denyCommit(void *context, int action, const char *first, const char *second, const char *database, const char *trigger) {
    return action == SQLITE_TRANSACTION && first && strcmp(first, "COMMIT") == 0 ? SQLITE_DENY : SQLITE_OK;
}

@interface OverlandTests : XCTestCase
@property GLManager *manager;
@property LOLDatabase *db;
@property NSDictionary *defaults;
@property NSString *defaultsSuite;
@end

@implementation OverlandTests
+ (void)setUp {
    [super setUp];
    method_exchangeImplementations(class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)), class_getClassMethod(NSUserDefaults.class, @selector(overland_testDefaults)));
    method_exchangeImplementations(class_getClassMethod(NSURLSessionConfiguration.class, @selector(defaultSessionConfiguration)), class_getClassMethod(NSURLSessionConfiguration.class, @selector(overland_testConfiguration)));
}
+ (void)tearDown {
    method_exchangeImplementations(class_getClassMethod(NSURLSessionConfiguration.class, @selector(defaultSessionConfiguration)), class_getClassMethod(NSURLSessionConfiguration.class, @selector(overland_testConfiguration)));
    method_exchangeImplementations(class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults)), class_getClassMethod(NSUserDefaults.class, @selector(overland_testDefaults)));
    [super tearDown];
}
- (void)setUp {
    [super setUp];
    NSUserDefaults *hostDefaults = NSUserDefaults.standardUserDefaults;
    self.defaults = [hostDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier] ?: @{};
    [[GLManager sharedManager] stopAllUpdates];
    self.defaultsSuite = [@"Overland.ManagerTests." stringByAppendingString:NSUUID.UUID.UUIDString];
    fixtureDefaults = [[NSUserDefaults alloc] initWithSuiteName:self.defaultsSuite];
    [fixtureDefaults registerDefaults:[hostDefaults volatileDomainForName:NSRegistrationDomain]];
    // The app host's pending uploads must not reach a test's request handler.
    [[GLManager sharedManager] setupHTTPClient];
    self.manager = [[TestUploadManager alloc] init];
    [self.manager setValue:@(UIBackgroundTaskInvalid) forKey:@"sendBackgroundTask"];
    self.db = [[LOLDatabase alloc] initWithPath:@":memory:"];
    self.db.serializer = ^NSData *(id object) {
        if(![NSJSONSerialization isValidJSONObject:object]) return nil;
        return [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    };
    self.db.deserializer = ^id(NSData *data) { return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]; };
    [self.manager setValue:self.db forKey:@"db"];
    self.manager.sendingInterval = @-1;
    [NSURLProtocol registerClass:OverlandTestProtocol.class];
}
- (void)tearDown {
    requestHandler = nil;
    [self.manager stopAllUpdates];
    if([self.manager isKindOfClass:TestLocationHealthManager.class]) {
        TestLocationHealthManager *health = (TestLocationHealthManager *)self.manager;
        XCTestExpectation *flushed = [self expectationWithDescription:@"Health fixture writes finished"];
        [health loadLocationHealthLog:^(NSArray *entries) { [flushed fulfill]; }];
        [self waitForExpectationsWithTimeout:5 handler:nil];
        [NSFileManager.defaultManager removeItemAtURL:health.healthDirectory error:nil];
    }
    // Clearing the endpoint resets backoff; discard this fixture's retry intent first.
    [self.manager setValue:@NO forKey:@"uploadPending"];
    [self.manager setValue:@NO forKey:@"drainAll"];
    [self.manager saveNewAPIEndpoint:nil andAccessToken:nil];
    [NSURLProtocol unregisterClass:OverlandTestProtocol.class];
    self.manager = nil;
    [fixtureDefaults removePersistentDomainForName:self.defaultsSuite];
    fixtureDefaults = nil;
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:self.defaults forName:NSBundle.mainBundle.bundleIdentifier];
    [super tearDown];
}
- (void)queue:(NSDictionary *)value key:(NSString *)key {
    [self.db accessCollection:@"GLLocationQueue" withBlock:^(id<LOLDatabaseAccessor> accessor) { [accessor setDictionary:value forKey:key]; }];
}
- (NSDictionary *)queued:(NSString *)key {
    __block NSDictionary *value;
    [self.db accessCollection:@"GLLocationQueue" withBlock:^(id<LOLDatabaseAccessor> accessor) { value = [accessor dictionaryForKey:key]; }];
    return value;
}
- (long)count {
    __block long count = -1;
    [self.manager numberOfLocationsInQueue:^(long num) { count = num; }];
    return count;
}
- (CLLocation *)location:(double)latitude time:(NSTimeInterval)time {
    return [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(latitude, -122.67) altitude:10 horizontalAccuracy:5 verticalAccuracy:5 course:0 speed:2 timestamp:[NSDate dateWithTimeIntervalSince1970:time]];
}
- (void)waitForSend {
    NSPredicate *done = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) { return !self.manager.sendInProgress; }];
    [self expectationForPredicate:done evaluatedWithObject:self.manager handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
}
- (void)failCommits:(BOOL)fail {
    Ivar ivar = class_getInstanceVariable(LOLDatabase.class, "db");
    sqlite3 *handle = *(sqlite3 **)((uint8_t *)(__bridge void *)self.db + ivar_getOffset(ivar));
    sqlite3_set_authorizer(handle, fail ? denyCommit : NULL, NULL);
}
- (TestLocationHealthManager *)healthManager {
    TestLocationHealthManager *manager = [TestLocationHealthManager new];
    manager.healthUptime = 100;
    manager.healthDirectory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    [manager setValue:[[GLLocationHealthLog alloc] initWithDirectory:manager.healthDirectory] forKey:@"locationHealthLog"];
    [manager setValue:self.db forKey:@"db"];
    [manager setValue:@(UIBackgroundTaskInvalid) forKey:@"sendBackgroundTask"];
    [manager setValue:[TestLocationManager new] forKey:@"locationManager"];
    manager.sendingInterval = @-1;
    manager.trackingMode = kGLTrackingModeStandard;
    manager.desiredAccuracy = 10;
    manager.pausesAutomatically = NO;
    self.manager = manager;
    return manager;
}
- (void)testLocationUpdateRetryDefaultsAndThresholdValidation {
    XCTAssertFalse([self.manager.advancedTrackingOptions[@"automatic_location_retry"] boolValue]);
    XCTAssertFalse([self.manager.advancedTrackingOptions[@"location_health_log"] boolValue]);
    XCTAssertEqual([self.manager.advancedTrackingOptions[@"location_retry_after"] intValue], 120);
    self.manager.advancedTrackingOptions = @{@"location_retry_after": @0};
    XCTAssertEqual([self.manager.advancedTrackingOptions[@"location_retry_after"] intValue], 60);
    self.manager.advancedTrackingOptions = @{@"location_retry_after": @100000};
    XCTAssertEqual([self.manager.advancedTrackingOptions[@"location_retry_after"] intValue], 1800);
}
- (void)testAutomaticLocationRetryRestartsAtMostThreeTimesAndKeepsSettings {
    TestLocationHealthManager *manager = [self healthManager];
    [manager setAdvancedTrackingOption:@YES forKey:@"automatic_location_retry"];
    [manager startAllUpdates];
    TestLocationManager *location = (TestLocationManager *)manager.locationManager;
    NSUInteger starts = location.startCount;
    for(NSNumber *time in @[@220, @460, @1060, @10000]) {
        manager.healthUptime = time.doubleValue;
        [manager evaluateLocationHealth];
    }
    XCTAssertEqual(location.startCount, starts + 3);
    XCTAssertEqual([manager.locationUpdateHealth[@"attempts"] intValue], 3);
    XCTAssertEqual(manager.desiredAccuracy, 10);
    XCTAssertFalse(manager.pausesAutomatically);
    XCTAssertEqual(manager.trackingMode, kGLTrackingModeStandard);
}
- (void)testLocationRetryRespectsPausesPermissionsEventModeAndStop {
    TestLocationHealthManager *manager = [self healthManager];
    [manager setAdvancedTrackingOption:@YES forKey:@"automatic_location_retry"];
    [manager startAllUpdates];
    TestLocationManager *location = (TestLocationManager *)manager.locationManager;
    NSUInteger starts = location.startCount;
    [manager setValue:@YES forKey:@"engineStationary"];
    manager.healthUptime = 1000;
    [manager evaluateLocationHealth];
    XCTAssertEqual(location.startCount, starts);
    XCTAssertEqualObjects(manager.locationUpdateHealth[@"reason"], @"automatic_pause");
    [manager setValue:@NO forKey:@"engineStationary"];
    [manager setValue:@YES forKey:@"didPauseByRadius"];
    [manager evaluateLocationHealth];
    XCTAssertEqualObjects(manager.locationUpdateHealth[@"reason"], @"radius_pause");
    XCTAssertEqual(location.startCount, starts);
    [manager setValue:@NO forKey:@"didPauseByRadius"];
    location.authorizationOverride = @(kCLAuthorizationStatusDenied);
    [manager evaluateLocationHealth];
    XCTAssertEqualObjects(manager.locationUpdateHealth[@"reason"], @"permission");
    XCTAssertEqual(location.startCount, starts);
    location.authorizationOverride = @(kCLAuthorizationStatusAuthorizedAlways);
    manager.trackingMode = kGLTrackingModeSignificant;
    [manager evaluateLocationHealth];
    XCTAssertEqualObjects(manager.locationUpdateHealth[@"reason"], @"event_mode");
    XCTAssertEqual(location.startCount, starts);
    [manager stopAllUpdates];
    manager.healthUptime = 100000;
    [manager evaluateLocationHealth];
    XCTAssertEqual(location.startCount, starts);
    XCTAssertEqualObjects(manager.locationUpdateHealth[@"reason"], @"tracking_off");
}
- (void)testFreshRejectedPointsDoNotTriggerAutomaticLocationRetry {
    TestLocationHealthManager *manager = [self healthManager];
    [manager setAdvancedTrackingOption:@YES forKey:@"automatic_location_retry"];
    manager.discardPointsOutsideAccuracy = 10;
    [manager startAllUpdates];
    TestLocationManager *location = (TestLocationManager *)manager.locationManager;
    NSUInteger starts = location.startCount;
    for(int t = 100; t <= 250; t += 10) {
        manager.healthUptime = t;
        CLLocation *fix = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(45, -122)
            altitude:0 horizontalAccuracy:500 verticalAccuracy:5 timestamp:[NSDate dateWithTimeIntervalSinceNow:-1]];
        [manager processLocations:@[fix]];
    }
    XCTAssertEqual(location.startCount, starts);
    XCTAssertEqual(self.count, 0);
    XCTAssertEqual([manager.locationUpdateHealth[@"attempts"] intValue], 0);
    XCTAssertEqualObjects(manager.locationUpdateHealth[@"state"], @"points_skipped");
}
- (void)testLocationRetryDoesNotInterruptAdaptivePowerSaving {
    TestLocationHealthManager *manager = [self healthManager];
    manager.advancedTrackingOptions = @{@"automatic_location_retry": @YES, @"adaptive": @YES, @"adaptive_require_motion": @NO};
    [manager startAllUpdates];
    GLAdaptivePolicy *policy = [GLAdaptivePolicy new];
    for(int t = 1000; t <= 1120; t += 60) {
        CLLocation *fix = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(45, -122)
            altitude:0 horizontalAccuracy:5 verticalAccuracy:5 timestamp:[NSDate dateWithTimeIntervalSince1970:t]];
        [policy observeLocation:fix motion:GLMovementStationary now:fix.timestamp dwell:120 radius:30 maxAccuracy:25 requireMotion:NO];
    }
    XCTAssertTrue(policy.stationary);
    [manager setValue:policy forKey:@"adaptivePolicy"];
    TestLocationManager *location = (TestLocationManager *)manager.locationManager;
    NSUInteger starts = location.startCount;
    manager.healthUptime = 10000;
    [manager evaluateLocationHealth];
    XCTAssertEqual(location.startCount, starts);
    XCTAssertEqualObjects(manager.locationUpdateHealth[@"reason"], @"adaptive_pause");
}
- (void)testHealthLoggingAndOptionChangesDoNotRestartUnchangedAcquisition {
    TestLocationHealthManager *manager = [self healthManager];
    [manager startAllUpdates];
    TestLocationManager *location = (TestLocationManager *)manager.locationManager;
    NSUInteger starts = location.startCount;
    [manager setAdvancedTrackingOption:@YES forKey:@"location_health_log"];
    [manager setAdvancedTrackingOption:@60 forKey:@"location_retry_after"];
    manager.healthUptime = 10000;
    [manager evaluateLocationHealth];
    XCTAssertEqual(location.startCount, starts);
    XCTAssertEqual([manager.locationUpdateHealth[@"attempts"] intValue], 0);
    [manager setAdvancedTrackingOption:@NO forKey:@"location_health_log"];
    XCTAssertNil([manager valueForKey:@"locationHealthTimer"]);
}
- (void)testLocationSavingIsProtectedUntilArchiveWritesFinish {
    TestLocationHealthManager *manager = [self healthManager];
    [manager setValue:@YES forKey:@"trackingEnabled"];
    [manager processLocations:@[[self location:45.5 time:1000]]];
    XCTAssertTrue(manager.protectedDuringProcessing);
    XCTAssertEqual(self.count, 1);
    NSPredicate *ended = [NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) { return !manager.saveAllowanceActive; }];
    [self expectationForPredicate:ended evaluatedWithObject:manager handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertEqual(manager.allowanceEndCount, 1);
}
- (void)testFailedQueueSaveEndsItsAllowanceAndRetainsTheAcceptedBaseline {
    TestLocationHealthManager *manager = [self healthManager];
    [manager setValue:@YES forKey:@"trackingEnabled"];
    [self failCommits:YES];
    [manager processLocations:@[[self location:45.5 time:1000]]];
    [self failCommits:NO];
    XCTAssertTrue(manager.protectedDuringProcessing);
    XCTAssertFalse(manager.saveAllowanceActive);
    XCTAssertEqual(manager.allowanceEndCount, 1);
    XCTAssertNil(manager.lastLocation);
    XCTAssertEqual(self.count, 0);
}
- (void)testCommitFailureReportsErrorAndRollsBack {
    [self queue:@{@"original": @YES} key:@"kept"];
    [self failCommits:YES];
    BOOL committed = [self.db accessCollection:@"GLLocationQueue" withBlock:^(id<LOLDatabaseAccessor> accessor) {
        [accessor deleteAllData];
        [accessor setDictionary:@{@"replacement": @YES} forKey:@"lost"];
    }];
    XCTAssertFalse(committed);
    XCTAssertNotNil(self.db.lastError);
    [self failCommits:NO];
    XCTAssertNotNil([self queued:@"kept"]);
    XCTAssertNil([self queued:@"lost"]);
}
- (void)testDeletePendingUploadsClearsRetryStateAndPreservesOtherCollections {
    [self queue:@{@"original": @YES} key:@"pending"];
    [self.db accessCollection:@"UnrelatedData" withBlock:^(id<LOLDatabaseAccessor> accessor) {
        [accessor setDictionary:@{@"kept": @YES} forKey:@"separate-record"];
    }];
    NSArray *import = @[@{@"source": @"healthkit"}];
    NSUInteger inserted = 0;
    XCTAssertTrue([self.db importRecords:import keys:@[@"workout-point"] intoCollection:@"GLLocationQueue" insertedCount:&inserted]);
    XCTAssertEqual(inserted, 1);
    [self.manager setValue:@YES forKey:@"uploadPending"];
    [self.manager setValue:@YES forKey:@"drainAll"];
    [self.manager setValue:@YES forKey:@"uploadBlocked"];
    [self.manager setValue:@3 forKey:@"uploadFailures"];
    [self.manager setValue:[NSDate dateWithTimeIntervalSinceNow:600] forKey:@"nextUploadDate"];
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:600 repeats:NO block:^(NSTimer *timer) { XCTFail(@"Deleted queue retried"); }];
    [self.manager setValue:timer forKey:@"uploadTimer"];
    CLLocation *fix = [self location:45.5 time:1000];
    [self.manager setValue:fix forKey:@"lastLocation"];

    XCTAssertTrue([self.manager deleteAllData]);

    XCTAssertEqual(self.count, 0);
    XCTAssertEqual(self.manager.currentPointsInQueue, 0);
    XCTAssertFalse([[self.manager valueForKey:@"uploadPending"] boolValue]);
    XCTAssertFalse([[self.manager valueForKey:@"drainAll"] boolValue]);
    XCTAssertFalse(self.manager.uploadsBlocked);
    XCTAssertNil(self.manager.uploadRetryDate);
    XCTAssertFalse(timer.valid);
    XCTAssertEqual(self.manager.lastLocation, fix);
    [self.db accessCollection:@"UnrelatedData" withBlock:^(id<LOLDatabaseAccessor> accessor) {
        XCTAssertNotNil([accessor dictionaryForKey:@"separate-record"]);
    }];
    XCTAssertTrue([self.db importRecords:import keys:@[@"workout-point"] intoCollection:@"GLLocationQueue" insertedCount:&inserted]);
    XCTAssertEqual(inserted, 0);
    XCTAssertEqual(self.count, 0);
    NSDictionary *state = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"GLUploadRetryState"];
    XCTAssertFalse([state[@"pending"] boolValue]);
    XCTAssertFalse([state[@"flush"] boolValue]);
}
- (void)testDeletePendingUploadsKeepsRecordsAndRetryStateWhenCommitFails {
    [self queue:@{@"original": @YES} key:@"pending"];
    [self.manager setValue:@YES forKey:@"uploadPending"];
    [self.manager setValue:@YES forKey:@"drainAll"];
    NSDate *retry = [NSDate dateWithTimeIntervalSinceNow:600];
    [self.manager setValue:retry forKey:@"nextUploadDate"];
    [self failCommits:YES];

    XCTAssertFalse([self.manager deleteAllData]);

    [self failCommits:NO];
    XCTAssertEqual(self.count, 1);
    XCTAssertTrue([[self.manager valueForKey:@"uploadPending"] boolValue]);
    XCTAssertTrue([[self.manager valueForKey:@"drainAll"] boolValue]);
    XCTAssertEqual(self.manager.uploadRetryDate, retry);
}
- (void)testDeletePendingUploadsRefusesInFlightBatches {
    [self queue:@{@"original": @YES} key:@"pending"];
    [self.manager setValue:@YES forKey:@"sendInProgress"];
    XCTAssertFalse([self.manager deleteAllData]);
    [self.manager setValue:@NO forKey:@"sendInProgress"];
    [self.manager setValue:@YES forKey:@"batchInProgress"];
    XCTAssertFalse([self.manager deleteAllData]);
    [self.manager setValue:@NO forKey:@"batchInProgress"];
    XCTAssertEqual(self.count, 1);
}
- (void)testFailedQueueCommitDoesNotAdvanceAcceptedFix {
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    CLLocation *first = [self location:45.5 time:1000];
    CLLocation *second = [self location:45.501 time:1010];
    [self.manager processLocations:@[first]];
    [self failCommits:YES];
    [self.manager processLocations:@[second]];
    XCTAssertEqual(self.manager.lastLocation, first);
    [self failCommits:NO];
    XCTAssertEqual(self.count, 1);
    [self.manager processLocations:@[second]];
    XCTAssertEqual(self.manager.lastLocation, second);
    XCTAssertEqual(self.count, 2);
}
- (void)testFailedQueueReadKeepsTheUploadPending {
    [self queue:@{@"properties": @{}} key:@"one"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    requestHandler = ^(OverlandTestProtocol *request) { XCTFail(@"A failed transaction must not send a partial read"); };
    [self failCommits:YES];
    [self.manager sendQueueNow];
    XCTAssertFalse(self.manager.sendInProgress);
    XCTAssertTrue([[self.manager valueForKey:@"uploadPending"] boolValue]);
    XCTAssertTrue([[self.manager valueForKey:@"drainAll"] boolValue]);
    XCTAssertGreaterThan([[self.manager valueForKey:@"nextUploadDate"] timeIntervalSinceNow], 0);
    [self failCommits:NO];
    XCTAssertEqual(self.count, 1);
}
- (void)testFailedTripSummaryCommitRetainsTripForRetry {
    FMDatabase *trip = [FMDatabase databaseWithPath:@":memory:"];
    [trip open];
    [trip executeUpdate:@"CREATE TABLE trips (id INTEGER PRIMARY KEY, timestamp REAL, latitude REAL, longitude REAL)"];
    [self.manager setValue:trip forKey:@"tripdb"];
    [NSUserDefaults.standardUserDefaults setObject:[NSDate dateWithTimeIntervalSince1970:900] forKey:GLTripStartTimeDefaultsName];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    [self.manager processLocations:@[[self location:45.5 time:1000], [self location:45.501 time:1010]]];
    double distance = self.manager.currentTripDistance;
    [self failCommits:YES];
    [self.manager writeTripToDB:NO steps:0];
    XCTAssertTrue(self.manager.tripInProgress);
    XCTAssertTrue(trip.isOpen);
    XCTAssertEqual(self.manager.currentTripPoints.count, 2);
    XCTAssertEqual(self.manager.currentTripDistance, distance);
    [self failCommits:NO];
    [self.manager writeTripToDB:NO steps:0];
    XCTAssertFalse(self.manager.tripInProgress);
    XCTAssertEqual(self.count, 3);
}
- (void)startFixtureTrip {
    FMDatabase *trip = [FMDatabase databaseWithPath:@":memory:"];
    [trip open];
    [trip executeUpdate:@"CREATE TABLE trips (id INTEGER PRIMARY KEY, timestamp REAL, latitude REAL, longitude REAL)"];
    [self.manager setValue:trip forKey:@"tripdb"];
    [NSUserDefaults.standardUserDefaults setObject:[NSDate dateWithTimeIntervalSince1970:900] forKey:GLTripStartTimeDefaultsName];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    [self.manager processLocations:@[[self location:45.5 time:1000], [self location:45.501 time:1010], [self location:45.505 time:1500]]];
}
- (NSDictionary *)tripSummary {
    __block NSDictionary *summary;
    [self.db accessCollection:@"GLLocationQueue" withBlock:^(id<LOLDatabaseAccessor> accessor) {
        [accessor enumerateKeysAndObjectsUsingBlock:^BOOL(NSString *key, NSDictionary *object) {
            if([object[@"properties"][@"type"] isEqual:@"trip"]) summary = object[@"properties"];
            return summary != nil;
        }];
    }];
    return summary;
}
- (void)testTripEndedEarlierStopsTimeDistanceAndLocationThere {
    [self startFixtureTrip];
    CLLocation *stop = [self location:45.501 time:1010];
    [self.manager writeTripToDB:NO steps:0 endDate:[NSDate dateWithTimeIntervalSince1970:1100] location:stop];
    XCTAssertFalse(self.manager.tripInProgress);
    NSDictionary *summary = [self tripSummary];
    XCTAssertEqualObjects(summary[@"end"], [GLManager iso8601DateStringFromDate:[NSDate dateWithTimeIntervalSince1970:1100]]);
    XCTAssertEqualWithAccuracy([summary[@"duration"] doubleValue], 200, 0.5);
    XCTAssertEqualWithAccuracy([summary[@"distance"] doubleValue], 111.2, 1);
    XCTAssertEqualWithAccuracy([summary[@"end_location"][@"geometry"][@"coordinates"][1] doubleValue], 45.501, 0.00001);
    XCTAssertEqualObjects([NSUserDefaults.standardUserDefaults objectForKey:GLLastTripEndDefaultsName], [NSDate dateWithTimeIntervalSince1970:1100]);
}
- (void)testStopPromptEndsOnlyItsOwnTripAtTheStop {
    [NSUserDefaults.standardUserDefaults setObject:[NSDate dateWithTimeIntervalSince1970:900] forKey:GLTripStartTimeDefaultsName];
    NSDate *(^stop)(NSDictionary *) = ^NSDate *(NSDictionary *info) { return [self.manager stopDateForPrompt:info]; };
    XCTAssertEqualObjects(stop(@{GLEndTripPromptTripStartKey: @900, GLEndTripPromptStoppedAtKey: @1100}),
                          [NSDate dateWithTimeIntervalSince1970:1100]);
    XCTAssertNil(stop(@{GLEndTripPromptTripStartKey: @500, GLEndTripPromptStoppedAtKey: @1100}));
    XCTAssertNil(stop(@{GLEndTripPromptTripStartKey: @900, GLEndTripPromptStoppedAtKey: @800}));
    XCTAssertNil(stop(@{}));
    NSDate *future = stop(@{GLEndTripPromptTripStartKey: @900, GLEndTripPromptStoppedAtKey: @(NSDate.date.timeIntervalSince1970 + 3600)});
    XCTAssertLessThan(future.timeIntervalSinceNow, 1);
}
- (void)testQuickActionsOfferModesOrStopTrip {
    NSArray *idle = [[GLTripActions quickActionItems] valueForKey:@"type"];
    XCTAssertGreaterThan(idle.count, 0);
    XCTAssertLessThanOrEqual(idle.count, 4);
    XCTAssertFalse([idle containsObject:@"stop"]);
    [NSUserDefaults.standardUserDefaults setObject:NSDate.date forKey:GLTripStartTimeDefaultsName];
    XCTAssertEqualObjects([[GLTripActions quickActionItems] valueForKey:@"type"], @[@"stop"]);
    [NSUserDefaults.standardUserDefaults removeObjectForKey:GLTripStartTimeDefaultsName];
}
- (void)testTripDistanceRestoresOnceAndAddsOnlyCommittedPoints {
    FMDatabase *trip = [FMDatabase databaseWithPath:@":memory:"];
    [trip open];
    [trip executeUpdate:@"CREATE TABLE trips (id INTEGER PRIMARY KEY, timestamp REAL, latitude REAL, longitude REAL)"];
    [trip executeUpdate:@"INSERT INTO trips (timestamp, latitude, longitude) VALUES (1000,45.5,-122.67), (1020,45.502,-122.67)"];
    [self.manager setValue:trip forKey:@"tripdb"];
    [NSUserDefaults.standardUserDefaults setObject:[NSDate dateWithTimeIntervalSince1970:900] forKey:GLTripStartTimeDefaultsName];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    CLLocation *a = [self location:45.5 time:1000];
    CLLocation *b = [self location:45.501 time:1010];
    CLLocation *c = [self location:45.502 time:1020];
    XCTAssertEqualWithAccuracy(self.manager.currentTripDistance, [a distanceFromLocation:c], 0.01);
    [self.manager processLocations:@[b]];
    XCTAssertEqualWithAccuracy(self.manager.currentTripDistance, [a distanceFromLocation:b] + [b distanceFromLocation:c], 0.01);
    [self failCommits:YES];
    [self.manager processLocations:@[[self location:45.51 time:1030]]];
    [self failCommits:NO];
    XCTAssertEqualWithAccuracy(self.manager.currentTripDistance, [a distanceFromLocation:b] + [b distanceFromLocation:c], 0.01);
}
- (void)testFailedSerializationRollsBackDeletion {
    [self queue:@{@"saved": @YES} key:@"original"];
    [self.db accessCollection:@"GLLocationQueue" withBlock:^(id<LOLDatabaseAccessor> accessor) {
        [accessor deleteAllData];
        [accessor setDictionary:@{@"bad": NSDate.date} forKey:@"replacement"];
    }];
    XCTAssertEqual(self.count, 1);
    XCTAssertEqualObjects([self queued:@"original"][@"saved"], @YES);
}
- (void)testPrepareFailureDoesNotLeaveTransactionOpen {
    [self.db accessCollection:@"invalid'" withBlock:^(id<LOLDatabaseAccessor> accessor) { XCTFail(@"Invalid table must not run its block"); }];
    [self queue:@{@"ok": @YES} key:@"next"];
    XCTAssertEqual(self.count, 1);
}
- (void)testExceptionRollsBackTransaction {
    @try {
        [self.db accessCollection:@"GLLocationQueue" withBlock:^(id<LOLDatabaseAccessor> accessor) {
            [accessor setDictionary:@{@"ok": @YES} forKey:@"lost"];
            @throw [NSException exceptionWithName:@"Test" reason:nil userInfo:nil];
        }];
    } @catch(NSException *exception) {}
    XCTAssertNil([self queued:@"lost"]);
    [self queue:@{@"ok": @YES} key:@"kept"];
    XCTAssertEqual(self.count, 1);
}
- (void)testRepeatedCountAndEarlyEnumeration {
    [self queue:@{@"ok": @YES} key:@"one"];
    [self queue:@{@"ok": @YES} key:@"two"];
    [self.db accessCollection:@"GLLocationQueue" withBlock:^(id<LOLDatabaseAccessor> accessor) {
        for(int i = 0; i < 2; i++) {
            [accessor countObjectsUsingBlock:^(long count) { XCTAssertEqual(count, 2); }];
            __block int visits = 0;
            [accessor enumerateKeysAndObjectsUsingBlock:^BOOL(NSString *key, NSDictionary *object) { visits++; return YES; }];
            XCTAssertEqual(visits, 1);
        }
    }];
}
- (void)testFirstPointSurvivesFiltersAndBatchUsesLastAcceptedPoint {
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    self.manager.discardPointsWithinDistance = 20;
    self.manager.discardPointsWithinSeconds = 10;
    [self.manager processLocations:@[[self location:45.5 time:1000], [self location:45.501 time:1011], [self location:45.502 time:1012]]];
    XCTAssertEqual(self.count, 2);
}
- (void)testSameSecondLocationsKeepDistinctKeys {
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    self.manager.discardPointsWithinSeconds = 0;
    [self.manager processLocations:@[[self location:45.5 time:1000.1], [self location:45.501 time:1000.2]]];
    XCTAssertEqual(self.count, 2);
}
- (void)testStoppedTrackerIgnoresLocationAndRegionCallbacks {
    self.manager.trackingMode = kGLTrackingModeStandardAndSignificant;
    self.manager.visitTrackingEnabled = YES;
    XCTAssertFalse(self.manager.trackingEnabled);
    [self.manager processLocations:@[[self location:45.5 time:1000]]];
    CLCircularRegion *region = [[CLCircularRegion alloc] initWithCenter:CLLocationCoordinate2DMake(45.5, -122.67) radius:100 identifier:@"resume-from-pause"];
    [self.manager locationManager:self.manager.locationManager didExitRegion:region];
    XCTAssertFalse(self.manager.trackingEnabled);
    XCTAssertEqual(self.count, 0);
}
- (void)testRemoteSettingsAcceptNumbersAndOffAndRejectMalformedValues {
    [self.manager updateSettingsFromResponse:@[@"not an object"]];
    [self.manager updateSettingsFromResponse:@{@"set": @{@"main": @[], @"trip": NSNull.null}}];
    [self.manager updateSettingsFromResponse:@{@"set": @{@"send_interval": @"off", @"main": @{@"batch_size": @50, @"visit_tracking": NSNull.null}}}];
    XCTAssertEqual(self.manager.sendingInterval.integerValue, -1);
    XCTAssertEqual(self.manager.pointsPerBatch, 50);
}
- (void)testOwntracksTimestampIsPointTime {
    NSDictionary *point = [self.manager owntracksDictionaryFromLocation:[self location:45.5 time:1700000000]];
    XCTAssertEqualObjects(point[@"tst"], @1700000000);
}
- (void)testEmptyOwntracksQueueDoesNotStartSend {
    self.manager.loggingMode = kGLLoggingModeOwntracks;
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    [self.manager sendQueueNow];
    XCTAssertFalse(self.manager.sendInProgress);
}
- (void)testOwntracksResponseRemovesOnlyTheSentPointAfterModeChanges {
    [self queue:@{@"_type": @"location", @"tst": @1} key:@"one"];
    [self queue:@{@"_type": @"location", @"tst": @2} key:@"two"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    __block OverlandTestProtocol *pending;
    XCTestExpectation *received = [self expectationWithDescription:@"Request received"];
    requestHandler = ^(OverlandTestProtocol *request) { pending = request; [received fulfill]; };
    self.manager.sendingInterval = @60;
    [self.manager sendQueueIfTimeElapsed];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    [[NSUserDefaults standardUserDefaults] setInteger:kGLLoggingModeAllData forKey:GLLoggingModeDefaultsName];
    [self queue:@{@"_type": @"location", @"tst": @3} key:@"three"];
    self.manager.sendingInterval = @-1;
    [pending respond:@"{\"result\":\"ok\",\"geocode\":123}" status:200];
    [self waitForSend];
    XCTAssertNil([self queued:@"one"]);
    XCTAssertNotNil([self queued:@"two"]);
    XCTAssertNotNil([self queued:@"three"]);
}
- (void)testMalformedAcknowledgementKeepsQueue {
    [self queue:@{@"properties": @{}} key:@"one"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    requestHandler = ^(OverlandTestProtocol *request) { [request respond:@"{\"result\":123}" status:200]; };
    [self.manager sendQueueNow];
    [self waitForSend];
    XCTAssertEqual(self.count, 1);
}
- (void)testPlainHTTPResponseCanAcknowledgeUpload {
    [self queue:@{@"properties": @{}} key:@"one"];
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:GLConsiderHTTP200SuccessDefaultsName];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    requestHandler = ^(OverlandTestProtocol *request) { [request respond:@"accepted" status:200]; };
    [self.manager sendQueueNow];
    [self waitForSend];
    XCTAssertEqual(self.count, 0);
}
- (void)testCustomHeadersValidateAndReachRequest {
    self.manager.customHTTPHeaders = @{@"CF-Access-Client-Id": @"test", @"Bad\r\nName": @"invalid", @"X-Bad": @"a\nb", @"Host": @"other", @"Authorization": @"override"};
    XCTAssertEqual(self.manager.customHTTPHeaders.count, 1);
    [self queue:@{@"properties": @{}} key:@"one"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:@"token"];
    requestHandler = ^(OverlandTestProtocol *request) {
        XCTAssertEqualObjects([request.request valueForHTTPHeaderField:@"CF-Access-Client-Id"], @"test");
        XCTAssertEqualObjects([request.request valueForHTTPHeaderField:@"Authorization"], @"Bearer token");
        [request respond:@"{\"result\":\"ok\"}" status:200];
    };
    [self.manager sendQueueNow];
    [self waitForSend];
    XCTAssertEqual(self.count, 0);
}
- (void)testWifiBSSIDDisambiguatesSameSSID {
    [self.manager addWifiZoneWithName:@"Home" latitude:@"1" longitude:@"2" bssid:nil];
    [self.manager addWifiZoneWithName:@"Home" latitude:@"3" longitude:@"4" bssid:@"aa:bb:cc:dd:ee:ff"];
    XCTAssertEqual(self.manager.wifiZones.count, 2);
    CLLocation *exact = [self.manager currentLocationFromWifiName:@"Home" bssid:@"AA:BB:CC:DD:EE:FF"];
    XCTAssertEqual(exact.coordinate.latitude, 3);
    CLLocation *fallback = [self.manager currentLocationFromWifiName:@"Home" bssid:nil];
    XCTAssertEqual(fallback.coordinate.latitude, 1);
    XCTAssertNil([self.manager currentLocationFromWifiName:@"Other" bssid:@"aa:bb:cc:dd:ee:ff"]);
}
- (void)testWifiZonePreservesDeliveredHistoryAndCurrentTimestamp {
    [self.manager addWifiZoneWithName:@"Home" latitude:@"1" longitude:@"2" bssid:nil];
    CLLocation *old = [self location:45.5 time:NSDate.date.timeIntervalSince1970 - 300];
    CLLocation *current = [self location:45.6 time:NSDate.date.timeIntervalSince1970 - 1];
    NSArray<CLLocation *> *result = [self.manager locationsByApplyingWifiZone:@[old, current] networkInfo:@{@"SSID": @"Home"}];
    XCTAssertEqual(result.count, 2);
    XCTAssertEqual(result[0], old);
    XCTAssertEqual(result[1].coordinate.latitude, 1);
    XCTAssertEqualObjects(result[1].timestamp, current.timestamp);
    XCTAssertEqual(result[1].horizontalAccuracy, 1);
    XCTAssertEqualObjects([self.manager locationsByApplyingWifiZone:@[old] networkInfo:@{@"SSID": @"Home"}], @[old]);
}
- (void)testWifiZoneUsesConfiguredRadius {
    [NSUserDefaults.standardUserDefaults setObject:@[@{@"name": @"Home", @"latitude": @1, @"longitude": @2, @"radius": @125}] forKey:@"WifiZones"];
    CLLocation *zone = [self.manager currentLocationFromWifiName:@"Home" bssid:nil];
    XCTAssertEqual(zone.horizontalAccuracy, 125);
    XCTAssertTrue([self.manager addWifiNetworks:@[@{@"name": @"Home"}] latitude:@"3" longitude:@"4"]);
    zone = [self.manager currentLocationFromWifiName:@"Home" bssid:nil];
    XCTAssertEqual(zone.horizontalAccuracy, 125);
    XCTAssertEqual(zone.coordinate.latitude, 3);
}
- (void)testWifiBSSIDNormalizationAndLegacyDuplicateReadUsesLastEntry {
    XCTAssertEqualObjects([GLManager normalizedWifiBSSID:@"A:B:C:D:E:F"], @"0a:0b:0c:0d:0e:0f");
    XCTAssertEqualObjects([GLManager normalizedWifiBSSID:@"AA-bb-CC-dd-EE-ff"], @"aa:bb:cc:dd:ee:ff");
    XCTAssertEqualObjects([GLManager normalizedWifiBSSID:@"aabbccddeeff"], @"aa:bb:cc:dd:ee:ff");
    XCTAssertNil([GLManager normalizedWifiBSSID:@"aa:bb:cc:dd:ee"]);

    [NSUserDefaults.standardUserDefaults setObject:@[
        @{@"name": @"Home", @"latitude": @"1", @"longitude": @"2", @"bssid": @"0A:0B:0C:0D:0E:0F"},
        @{@"name": @"Home", @"latitude": @"3", @"longitude": @"4", @"bssid": @"a:b:c:d:e:f"},
    ] forKey:GLWifiZonesDefaultsName];
    XCTAssertEqual(self.manager.wifiZones.count, 1);
    XCTAssertEqualObjects(self.manager.wifiZones.firstObject[@"bssid"], @"0a:0b:0c:0d:0e:0f");
    XCTAssertEqualObjects(self.manager.wifiZones.firstObject[@"latitude"], @"3");
    CLLocation *normalized = [self.manager currentLocationFromWifiName:@"Home" bssid:@"A:B:C:D:E:F"];
    XCTAssertEqual(normalized.coordinate.latitude, 3);
}
- (void)testWifiBatchUpsertsIdentityAtomicallyAndAllowsSameSSIDDifferentBSSID {
    XCTAssertTrue(([self.manager addWifiNetworks:@[
        @{@"name": @"Home", @"bssid": @"aa:bb:cc:dd:ee:ff"},
        @{@"name": @"Home", @"bssid": @"11:22:33:44:55:66"},
        @{@"name": @"Office"},
    ] latitude:@"1" longitude:@"2"]));
    XCTAssertEqual(self.manager.wifiZones.count, 3);
    XCTAssertTrue(([self.manager addWifiNetworks:@[@{@"name": @"Home", @"bssid": @"AABBCCDDEEFF"}]
        latitude:@"3" longitude:@"4"]));
    XCTAssertEqual(self.manager.wifiZones.count, 3);
    CLLocation *updated = [self.manager currentLocationFromWifiName:@"Home" bssid:@"aa:bb:cc:dd:ee:ff"];
    XCTAssertEqual(updated.coordinate.latitude, 3);

    NSArray *before = self.manager.wifiZones;
    XCTAssertFalse(([self.manager addWifiNetworks:@[
        @{@"name": @"New", @"bssid": @"aa:bb:cc:dd:ee:ff"},
        @{@"name": @"Invalid", @"bssid": @"not-a-bssid"},
    ] latitude:@"8" longitude:@"9"]));
    XCTAssertEqualObjects(self.manager.wifiZones, before);
    XCTAssertFalse(([self.manager addWifiNetworks:@[@{@"name": @"Invalid", @"bssid": @123}]
        latitude:@"8" longitude:@"9"]));
    XCTAssertEqualObjects(self.manager.wifiZones, before);
}
- (void)testWifiReadDropsMalformedEntriesWithoutCreatingWildcards {
    [NSUserDefaults.standardUserDefaults setObject:@[
        @"not-a-zone",
        @{@"name": @"BadCoordinate", @"latitude": @"not-a-number", @"longitude": @"2"},
        @{@"name": @"BadBSSID", @"latitude": @"1", @"longitude": @"2", @"bssid": @"not-an-address"},
        @{@"name": @"Valid", @"latitude": @1, @"longitude": @2, @"radius": @125},
    ] forKey:GLWifiZonesDefaultsName];
    NSArray *zones = self.manager.wifiZones;
    XCTAssertEqual(zones.count, 1);
    XCTAssertEqualObjects(zones.firstObject[@"name"], @"Valid");
    XCTAssertEqualObjects(zones.firstObject[@"latitude"], @"1");
    XCTAssertEqualObjects(zones.firstObject[@"radius"], @125);
    XCTAssertNil([self.manager currentLocationFromWifiName:@"BadBSSID" bssid:nil]);
}
- (void)testKnownWifiCatalogIsBoundedRedactsInvalidIdentityAndAvoidsRepeatedWrites {
    [NSUserDefaults.standardUserDefaults setObject:@[@"malformed", @{@"SSID": @"Stored", @"BSSID": @"A:B:C:D:E:F"}]
        forKey:GLWifiKnownNetworksDefaultsName];
    XCTAssertNoThrow([GLManager knownWifiNetworks]);
    [self.manager rememberWifiNetworkInfo:@{@"SSID": @"", @"BSSID": @"aa:bb:cc:dd:ee:ff"}];
    [self.manager rememberWifiNetworkInfo:@{@"SSID": @"Hidden", @"BSSID": @"not-a-bssid"}];
    [self.manager rememberWifiNetworkInfo:@{@"SSID": @"Wi-Fi", @"BSSID": @"00:00:00:00:00:00"}];
    [self.manager rememberWifiNetworkInfo:@{@"SSID": @"WLAN", @"BSSID": @"00:00:00:00:00:00"}];
    for(NSUInteger i = 0; i < 65; i++) {
        NSString *bssid = [NSString stringWithFormat:@"%x:%x:%x:%x:%x:%x", (unsigned int)i, 1u, 2u, 3u, 4u, 5u];
        [self.manager rememberWifiNetworkInfo:@{@"SSID": [NSString stringWithFormat:@"Network-%lu", (unsigned long)i], @"BSSID": bssid}];
    }
    NSArray *known = [GLManager knownWifiNetworks];
    XCTAssertEqual(known.count, 64);
    XCTAssertNil([known filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *network, NSDictionary *bindings) {
        return [network[@"name"] isEqualToString:@"Network-0"];
    }]].firstObject);
    NSDictionary *latest = known.lastObject;
    XCTAssertEqualObjects(latest[@"name"], @"Network-64");
    XCTAssertEqualObjects(latest[@"bssid"], @"40:01:02:03:04:05");
    NSArray *snapshot = [GLManager knownWifiNetworks];
    [self.manager rememberWifiNetworkInfo:@{@"SSID": @"Network-64", @"BSSID": @"40:01:02:03:04:05"}];
    XCTAssertEqualObjects([GLManager knownWifiNetworks], snapshot);
    [self.manager addWifiZoneWithName:@"Saved" latitude:@"1" longitude:@"2" bssid:@"A:B:C:D:E:F"];
    NSArray *merged = [self.manager knownWifiNetworksIncludingSavedZones:YES];
    XCTAssertTrue(merged.count > known.count);
    XCTAssertTrue(([merged containsObject:@{@"name": @"Saved", @"bssid": @"0a:0b:0c:0d:0e:0f"}]));
}
- (void)testUsageProfilesApplyAndRecognizeCustomEdits {
    for(NSInteger profile = 1; profile <= 5; profile++) {
        [self.manager applyUsageProfile:profile];
        XCTAssertEqual(self.manager.usageProfile, profile);
        XCTAssertFalse(self.manager.trackingEnabled);
        XCTAssertFalse(self.manager.visitTrackingEnabled);
        XCTAssertEqual(self.manager.discardPointsWithinDistance, -1);
        XCTAssertEqual(self.manager.discardPointsWithinSeconds, 0);
        XCTAssertEqual(self.manager.discardPointsOutsideAccuracy, -1);
    }
    XCTAssertEqual(self.manager.activityType, CLActivityTypeAutomotiveNavigation);
    XCTAssertEqual(self.manager.desiredAccuracy, kCLLocationAccuracyBestForNavigation);
    self.manager.discardPointsWithinDistance = 25;
    XCTAssertEqual(self.manager.usageProfile, 0);
    [self.manager applyUsageProfile:4];
    XCTAssertEqual(self.manager.activityType, CLActivityTypeFitness);
    XCTAssertEqual(self.manager.desiredAccuracy, kCLLocationAccuracyBest);
}

- (void)testLowPowerAndBalancedProfileThresholds {
    [self.manager applyUsageProfile:2];
    XCTAssertEqual(self.manager.trackingMode, kGLTrackingModeSignificant);
    XCTAssertTrue(self.manager.pausesAutomatically);
    XCTAssertEqual(self.manager.resumesAfterDistance, 500);
    XCTAssertEqual(self.manager.stopsAutomaticallyRadius, -1);
    [self.manager applyUsageProfile:3];
    XCTAssertEqual(self.manager.trackingMode, kGLTrackingModeStandardAndSignificant);
    XCTAssertEqual(self.manager.desiredAccuracy, 100);
    XCTAssertEqual(self.manager.stopsAutomaticallyRadius, 50);
    XCTAssertEqual(self.manager.stopsAutomaticallyAfterSeconds, 180);
    XCTAssertFalse(self.manager.pausesAutomatically);
    XCTAssertEqual(self.manager.resumesAfterDistance, -1);
    XCTAssertTrue(self.manager.showBackgroundLocationIndicator);
}

- (void)testUsageProfilePreservesUploadTripAndQueuedData {
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:@"test-token"];
    self.manager.loggingMode = kGLLoggingModeOwntracks;
    self.manager.sendingInterval = @900;
    self.manager.pointsPerBatch = 37;
    self.manager.desiredAccuracyDuringTrip = 23;
    [self queue:@{@"saved": @YES} key:@"saved"];
    [self.manager applyUsageProfile:1];
    XCTAssertEqualObjects(self.manager.apiEndpointURL, @"https://overland.test/");
    XCTAssertEqualObjects([NSUserDefaults.standardUserDefaults objectForKey:GLAPIAccessTokenDefaultsName], @"test-token");
    XCTAssertEqual(self.manager.loggingMode, kGLLoggingModeOwntracks);
    XCTAssertEqualObjects(self.manager.sendingInterval, @900);
    XCTAssertEqual(self.manager.pointsPerBatch, 37);
    XCTAssertEqual(self.manager.desiredAccuracyDuringTrip, 23);
    XCTAssertEqual(self.count, 1);
    XCTAssertEqualObjects([self queued:@"saved"][@"saved"], @YES);
    XCTAssertFalse(self.manager.trackingEnabled);
}

- (void)testInvalidProfilesAndActiveTripDoNotChangeSettings {
    [self.manager applyUsageProfile:1];
    NSDictionary *before = [NSUserDefaults.standardUserDefaults persistentDomainForName:self.defaultsSuite];
    [self.manager applyUsageProfile:0];
    [self.manager applyUsageProfile:-1];
    [self.manager applyUsageProfile:6];
    XCTAssertEqualObjects(before, [NSUserDefaults.standardUserDefaults persistentDomainForName:self.defaultsSuite]);
    [NSUserDefaults.standardUserDefaults setObject:NSDate.date forKey:GLTripStartTimeDefaultsName];
    [self.manager applyUsageProfile:2];
    XCTAssertEqual(self.manager.usageProfile, 1);
    XCTAssertTrue(self.manager.tripInProgress);
}

- (void)testEndpointRequiresHTTPAndHost {
    XCTAssertTrue([GLManager isValidEndpoint:@"https://example.com:8443/track"]);
    XCTAssertTrue([GLManager isValidEndpoint:@"http://localhost/track?lat=%LAT"]);
    XCTAssertFalse([GLManager isValidEndpoint:@"https:"]);
    XCTAssertFalse([GLManager isValidEndpoint:@"file:///tmp/data"]);
}
- (void)testFirstAutomaticSendAndFailureDoNotClaimSuccess {
    [self queue:@{@"properties": @{}} key:@"one"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    self.manager.sendingInterval = @60;
    requestHandler = ^(OverlandTestProtocol *request) { [request respond:@"unavailable" status:503]; };
    [self.manager sendQueueIfTimeElapsed];
    XCTAssertTrue(self.manager.sendInProgress);
    [self waitForSend];
    XCTAssertNil(self.manager.lastSentDate);
    XCTAssertEqual(self.count, 1);
    XCTAssertEqualObjects(self.manager.recentSendResults.lastObject[@"status"], @1);
    [self.manager sendQueueIfTimeElapsed];
    XCTAssertFalse(self.manager.sendInProgress);
}

- (void)testTripRecordsPointsWithNormalTrackingModeOff {
    self.manager.trackingMode = kGLTrackingModeOff;
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    FMDatabase *trip = [FMDatabase databaseWithPath:@":memory:"];
    [trip open];
    [trip executeUpdate:@"CREATE TABLE trips (id INTEGER PRIMARY KEY, timestamp REAL, latitude REAL, longitude REAL)"];
    [self.manager setValue:trip forKey:@"tripdb"];
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate dateWithTimeIntervalSince1970:900] forKey:GLTripStartTimeDefaultsName];
    [self.manager processLocations:@[[self location:45.5 time:1000], [self location:45.501 time:1010]]];
    XCTAssertEqual(self.count, 2);
    XCTAssertEqual(self.manager.currentTripPoints.count, 2);
    double distance = self.manager.currentTripDistance;
    XCTAssertGreaterThan(distance, 100);
    XCTAssertEqual(self.manager.currentTripDistance, distance);
    [self.manager writeTripToDB:NO steps:0];
    XCTAssertFalse(self.manager.tripInProgress);
    XCTAssertFalse(self.manager.trackingEnabled);
    XCTAssertFalse(trip.isOpen);
    XCTAssertEqual(self.count, 3);
}

- (void)testSendCannotBeStartedTwice {
    [self queue:@{@"properties": @{}} key:@"one"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    __block int requests = 0;
    requestHandler = ^(OverlandTestProtocol *request) {
        requests++;
        [request respond:@"{\"result\":\"ok\"}" status:200];
    };
    [self.manager sendQueueNow];
    [self.manager sendQueueNow];
    [self waitForSend];
    XCTAssertEqual(requests, 1);
    XCTAssertEqual(self.count, 0);
}
- (void)testAccountLookupUsesAuthenticationAndCustomHeaders {
    self.manager.customHTTPHeaders = @{@"X-Client": @"overland"};
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:@"token"];
    requestHandler = ^(OverlandTestProtocol *request) {
        XCTAssertEqualObjects([request.request valueForHTTPHeaderField:@"Authorization"], @"Bearer token");
        XCTAssertEqualObjects([request.request valueForHTTPHeaderField:@"X-Client"], @"overland");
        [request respond:@"{\"name\":\"Test Account\"}" status:200];
    };
    XCTestExpectation *done = [self expectationWithDescription:@"Account lookup"];
    [self.manager accountInfo:^(NSString *name) {
        XCTAssertEqualObjects(name, @"Test Account");
        [done fulfill];
    }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
}

- (void)testPayloadCountsTheActualSentBatch {
    [self queue:@{@"properties": @{@"locations_in_payload": @1}} key:@"one"];
    [self queue:@{@"properties": @{@"locations_in_payload": @1}} key:@"two"];
    [self queue:@{@"properties": @{@"locations_in_payload": @1}} key:@"three"];
    self.manager.pointsPerBatch = 2;
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    requestHandler = ^(OverlandTestProtocol *request) {
        NSData *body = request.request.HTTPBody;
        if(!body) {
            NSInputStream *stream = request.request.HTTPBodyStream;
            NSMutableData *data = [NSMutableData data];
            [stream open];
            uint8_t buffer[1024];
            NSInteger count;
            while((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) [data appendBytes:buffer length:count];
            [stream close];
            body = data;
        }
        NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL];
        XCTAssertEqual([payload[@"locations"] count], 2);
        for(NSDictionary *point in payload[@"locations"]) XCTAssertEqualObjects(point[@"properties"][@"locations_in_payload"], @2);
        [request respond:@"{\"result\":\"ok\"}" status:200];
    };
    self.manager.sendingInterval = @60;
    [self.manager sendQueueIfTimeElapsed];
    [self waitForSend];
    XCTAssertEqual(self.count, 1);
    XCTAssertNotNil([self queued:@"three"]);
}
- (void)testUploadBackoffAndRetryAfter {
    XCTAssertEqual([GLManager uploadBackoffForFailure:1 jitter:0], 5);
    XCTAssertEqual([GLManager uploadBackoffForFailure:2 jitter:0], 10);
    XCTAssertEqual([GLManager uploadBackoffForFailure:1 jitter:1], 6.25);
    XCTAssertEqual([GLManager uploadBackoffForFailure:32 jitter:1], 3600);
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:0];
    XCTAssertEqual([GLManager retryAfter:@"120" now:now], 120);
    XCTAssertEqual([GLManager retryAfter:@"Thu, 01 Jan 1970 00:02:00 GMT" now:now], 120);
    XCTAssertEqual([GLManager retryAfter:@"garbage" now:now], 0);
    XCTAssertEqual([GLManager retryAfter:@"-1" now:now], 0);
}
- (void)testRetryAfterPreventsAutomaticAndManualEarlyRetry {
    [self queue:@{@"properties": @{}} key:@"one"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    self.manager.sendingInterval = @1;
    __block int requests = 0;
    requestHandler = ^(OverlandTestProtocol *request) {
        requests++;
        [request respond:@"busy" status:429 headers:@{@"Retry-After": @"120"}];
    };
    [self.manager sendQueueNow];
    [self waitForSend];
    NSDate *deadline = [self.manager valueForKey:@"nextUploadDate"];
    XCTAssertGreaterThan(deadline.timeIntervalSinceNow, 115);
    [self.manager sendQueueIfTimeElapsed];
    [self.manager sendQueueNow];
    XCTAssertFalse(self.manager.sendInProgress);
    XCTAssertEqual(requests, 1);
    XCTAssertEqual(self.count, 1);
}
- (void)testAuthFailureBlocksAutomaticRetries {
    [self queue:@{@"properties": @{}} key:@"one"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    self.manager.sendingInterval = @0;
    requestHandler = ^(OverlandTestProtocol *request) { [request respond:@"unauthorized" status:401]; };
    [self.manager sendQueueNow];
    [self waitForSend];
    [self.manager sendQueueIfTimeElapsed];
    XCTAssertFalse(self.manager.sendInProgress);
    XCTAssertTrue([[self.manager valueForKey:@"uploadBlocked"] boolValue]);
    XCTAssertEqual(self.count, 1);
}
- (void)testMissingAcknowledgementRetainsQueueAndSchedulesAutomaticRetry {
    for(NSString *body in @[@"not JSON", @"{}", @"{\"result\":\"error\"}"]) {
        [self queue:@{@"properties": @{}} key:@"one"];
        [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
        requestHandler = ^(OverlandTestProtocol *request) { [request respond:body status:200]; };
        [self.manager sendQueueNow];
        [self waitForSend];
        XCTAssertEqual(self.count, 1);
        XCTAssertFalse([[self.manager valueForKey:@"uploadBlocked"] boolValue]);
        XCTAssertTrue([[self.manager valueForKey:@"uploadPending"] boolValue]);
        XCTAssertNotNil([self.manager valueForKey:@"nextUploadDate"]);
        XCTAssertGreaterThanOrEqual(((TestUploadManager *)self.manager).scheduledUploadDelay, 5);
        XCTAssertEqualObjects([self.manager valueForKey:@"nextUploadDate"],
                              [NSUserDefaults.standardUserDefaults dictionaryForKey:@"GLUploadRetryState"][@"retry"]);
        XCTAssertFalse([[NSUserDefaults.standardUserDefaults dictionaryForKey:@"GLUploadRetryState"][@"blocked"] boolValue]);
    }
}
- (void)testBackgroundExpirationRetainsQueueAndFlushForRetry {
    [self queue:@{@"properties": @{}} key:@"one"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    requestHandler = ^(OverlandTestProtocol *request) {};
    [self.manager sendQueueNow];
    XCTAssertTrue(self.manager.sendInProgress);
    [self.manager sendTimeExpired];
    XCTAssertFalse(self.manager.sendInProgress);
    XCTAssertTrue([[self.manager valueForKey:@"uploadPending"] boolValue]);
    XCTAssertTrue([[self.manager valueForKey:@"drainAll"] boolValue]);
    XCTAssertGreaterThan([[self.manager valueForKey:@"nextUploadDate"] timeIntervalSinceNow], 0);
    XCTAssertEqual(self.count, 1);
}
- (void)testManualSendDrainsEveryBatchWithoutAnotherFix {
    for(int i = 0; i < 7; i++) [self queue:@{@"properties": @{}} key:[NSString stringWithFormat:@"%d", i]];
    self.manager.pointsPerBatch = 2;
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    __block int requests = 0;
    requestHandler = ^(OverlandTestProtocol *request) {
        requests++;
        [request respond:@"{\"result\":\"ok\"}" status:200];
    };
    [self.manager sendQueueNow];
    [self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return self.count == 0 && !self.manager.sendInProgress;
    }] evaluatedWithObject:self.manager handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertEqual(requests, 4);
}
- (void)testSendNowDuringAutomaticSendRemembersFlush {
    self.manager.pointsPerBatch = 2;
    for(int i = 0; i < 3; i++) [self queue:@{@"properties": @{}} key:[NSString stringWithFormat:@"%d", i]];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    self.manager.sendingInterval = @60;
    __block OverlandTestProtocol *pending;
    XCTestExpectation *first = [self expectationWithDescription:@"First request"];
    requestHandler = ^(OverlandTestProtocol *request) { pending = request; [first fulfill]; };
    [self.manager sendQueueIfTimeElapsed];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    [self.manager sendQueueNow];
    requestHandler = ^(OverlandTestProtocol *request) { [request respond:@"{\"result\":\"ok\"}" status:200]; };
    [pending respond:@"{\"result\":\"ok\"}" status:200];
    [self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return self.count == 0 && !self.manager.sendInProgress;
    }] evaluatedWithObject:self.manager handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
}
- (id<GLWifiOnlySendingTesting>)wifiOnlyOnCellular {
    id<GLWifiOnlySendingTesting> wifi = [NSClassFromString(@"GLWifiOnlySending") performSelector:@selector(shared)];
    [wifi setForTestingWithEnabled:YES expensive:@YES];
    [self addTeardownBlock:^{ [wifi setForTestingWithEnabled:NO expensive:nil]; }];
    return wifi;
}
- (void)testWifiOnlyHoldsAutomaticSendsAndFlushesOnWifi {
    id<GLWifiOnlySendingTesting> wifi = [self wifiOnlyOnCellular];
    for(int i = 0; i < 5; i++) [self queue:@{@"properties": @{}} key:[NSString stringWithFormat:@"%d", i]];
    self.manager.pointsPerBatch = 2;
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    self.manager.sendingInterval = @60;
    __block int requests = 0;
    requestHandler = ^(OverlandTestProtocol *request) {
        requests++;
        [request respond:@"{\"result\":\"ok\"}" status:200];
    };
    XCTAssertTrue(self.manager.waitingForWifi);
    [self.manager sendQueueIfTimeElapsed];
    [self.manager sendQueueIfNotInProgress];
    XCTAssertFalse(self.manager.sendInProgress);
    XCTAssertTrue(self.manager.pendingUploads);
    [wifi setForTestingWithEnabled:YES expensive:@NO];
    XCTAssertFalse(self.manager.waitingForWifi);
    [self.manager wifiOnlySendingChanged];
    [self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return self.count == 0 && !self.manager.sendInProgress;
    }] evaluatedWithObject:self.manager handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertEqual(requests, 3);
}
- (void)testSendNowDrainsWhileWaitingForWifi {
    [self wifiOnlyOnCellular];
    for(int i = 0; i < 5; i++) [self queue:@{@"properties": @{}} key:[NSString stringWithFormat:@"%d", i]];
    self.manager.pointsPerBatch = 2;
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    __block int requests = 0;
    requestHandler = ^(OverlandTestProtocol *request) {
        requests++;
        [request respond:@"{\"result\":\"ok\"}" status:200];
    };
    [self.manager sendQueueNow];
    [self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return self.count == 0 && !self.manager.sendInProgress;
    }] evaluatedWithObject:self.manager handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertEqual(requests, 3);
    XCTAssertFalse(self.manager.pendingUploads);
}
- (void)testReminderEligibilityRespectsCoarseAndPausedModesButNotNormalTripSettings {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:GLNotificationsEnabledDefaultsName];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    for(NSNumber *mode in @[@(kGLTrackingModeOff), @(kGLTrackingModeSignificant)]) {
        [NSUserDefaults.standardUserDefaults setInteger:mode.integerValue forKey:GLSignificantLocationModeDefaultsName];
        XCTAssertFalse(self.manager.reminderEligible);
    }
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:GLVisitTrackingEnabledDefaultsName];
    XCTAssertFalse(self.manager.reminderEligible);
    [NSUserDefaults.standardUserDefaults setInteger:kGLTrackingModeStandard forKey:GLSignificantLocationModeDefaultsName];
    XCTAssertTrue(self.manager.reminderEligible);
    [self.manager setValue:@YES forKey:@"engineStationary"];
    XCTAssertFalse(self.manager.reminderEligible);
    [self.manager setValue:@NO forKey:@"engineStationary"];
    [NSUserDefaults.standardUserDefaults setInteger:kGLTrackingModeStandardAndSignificant forKey:GLSignificantLocationModeDefaultsName];
    [NSUserDefaults.standardUserDefaults setDouble:50 forKey:GLStopsAutomaticallyDefaultsName];
    XCTAssertFalse(self.manager.reminderEligible);
    [NSUserDefaults.standardUserDefaults setObject:NSDate.date forKey:GLTripStartTimeDefaultsName];
    XCTAssertTrue(self.manager.reminderEligible);
    [self.manager setValue:@YES forKey:@"didPauseByRadius"];
    XCTAssertFalse(self.manager.reminderEligible);
}
- (void)testReminderCancellationClearsRateLimitAndNotificationsOffCancels {
    [self.manager setValue:NSDate.date forKey:@"lastScheduledNotificationDate"];
    [self.manager cancelLocalNotification];
    XCTAssertNil([self.manager valueForKey:@"lastScheduledNotificationDate"]);
    [self.manager setValue:NSDate.date forKey:@"lastScheduledNotificationDate"];
    self.manager.notificationsEnabled = NO;
    XCTAssertNil([self.manager valueForKey:@"lastScheduledNotificationDate"]);
    XCTAssertFalse(self.manager.reminderEligible);
}
- (void)testFutureFixCannotPoisonAcceptedBaseline {
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    CLLocation *current = [self location:45.5 time:now];
    [self.manager processLocations:@[[self location:45.6 time:now + 3600],
        [self location:45.6 time:now + 30], [self location:45.6 time:now + 0.5], current]];
    XCTAssertEqual(self.count, 1);
    XCTAssertEqual(self.manager.lastLocation, current);
}
- (void)testEqualFixesDeduplicateWithFiltersOffButDistinctSameTimeFixesRemain {
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    self.manager.discardPointsWithinSeconds = 0;
    self.manager.discardPointsWithinDistance = -1;
    CLLocation *first = [self location:45.5 time:1000];
    [self.manager processLocations:@[first, [self location:45.5 time:1000], [self location:45.501 time:1000]]];
    XCTAssertEqual(self.count, 2);
    [self.manager processLocations:@[[self location:45.501 time:1000]]];
    XCTAssertEqual(self.count, 2);
}
- (void)testOldDeliveredBatchHasNoBlanketAgeCutoff {
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    [self.manager processLocations:@[[self location:45.5 time:1000], [self location:45.501 time:1010]]];
    XCTAssertEqual(self.count, 2);
}
- (void)testMovementDetectorUsesRawFixesRejectedByRecordingFilters {
    [self.manager applyUsageProfile:3];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    self.manager.discardPointsWithinSeconds = 600;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    CLLocation *first = [self location:45.5 time:now - 10];
    CLLocation *moving = [self location:45.51 time:now];
    [self.manager processLocations:@[first]];
    self.manager.lastTimeMovedBeyondStopThreshold = [NSDate dateWithTimeIntervalSinceNow:-200];
    [self.manager processLocations:@[moving]];
    XCTAssertEqual(self.count, 1);
    XCTAssertEqual(self.manager.lastLocation, first);
    XCTAssertEqual(self.manager.lastLocationMovedBeyondStopThreshold, moving);
    XCTAssertFalse(self.manager.didPauseByRadius);
}
- (void)testDelayedOrInvalidMovementFixCannotResumeRadiusPause {
    [self.manager applyUsageProfile:3];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    self.manager.didPauseByRadius = YES;
    [self.manager setValue:NSDate.date forKey:@"radiusPauseDate"];
    [self.manager processLocations:@[[self location:45.5 time:NSDate.date.timeIntervalSince1970 - 300],
        [self location:45.6 time:NSDate.date.timeIntervalSince1970 + 3600]]];
    XCTAssertTrue(self.manager.didPauseByRadius);
    XCTAssertNil(self.manager.lastLocationMovedBeyondStopThreshold);
}
- (void)testStationaryAnchorsResetAcrossProfilesAndTrackingTransitions {
    [self.manager applyUsageProfile:3];
    self.manager.lastLocationMovedBeyondStopThreshold = [self location:45.5 time:1000];
    self.manager.lastTimeMovedBeyondStopThreshold = NSDate.date;
    [self.manager applyUsageProfile:1];
    XCTAssertNil(self.manager.lastLocationMovedBeyondStopThreshold);
    XCTAssertNil(self.manager.lastTimeMovedBeyondStopThreshold);
    self.manager.lastTimeMovedBeyondStopThreshold = NSDate.date;
    [self.manager stopAllUpdates];
    XCTAssertNil(self.manager.lastTimeMovedBeyondStopThreshold);
}
- (void)testDelayedPostPauseFixRetainsHistoryAndFreshFixResumes {
    [self.manager setValue:[TestLocationManager new] forKey:@"locationManager"];
    [self.manager applyUsageProfile:3];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    self.manager.didPauseByRadius = YES;
    [self.manager setValue:[NSDate dateWithTimeIntervalSinceNow:-60] forKey:@"radiusPauseDate"];
    [self.manager processLocations:@[[self location:45.5 time:NSDate.date.timeIntervalSince1970 - 30]]];
    XCTAssertTrue(self.manager.didPauseByRadius);
    XCTAssertNil(self.manager.lastLocationMovedBeyondStopThreshold);
    XCTAssertNil(self.manager.lastTimeMovedBeyondStopThreshold);
    XCTAssertEqual(self.count, 1);
    [self.manager processLocations:@[[self location:45.501 time:NSDate.date.timeIntervalSince1970 - 1]]];
    XCTAssertFalse(self.manager.didPauseByRadius);
    XCTAssertNotNil(self.manager.lastLocationMovedBeyondStopThreshold);
}
- (void)testUncertainRawLocationCannotCauseRadiusPause {
    [self.manager applyUsageProfile:3];
    self.manager.lastTimeMovedBeyondStopThreshold = [NSDate dateWithTimeIntervalSinceNow:-200];
    CLLocation *uncertain = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(45.5, -122.67)
        altitude:0 horizontalAccuracy:100 verticalAccuracy:-1 timestamp:NSDate.date];
    XCTAssertTrue([self.manager observeMovementLocation:uncertain]);
    XCTAssertLessThan(-self.manager.lastTimeMovedBeyondStopThreshold.timeIntervalSinceNow, 1);
}
- (void)testOwntracksRetainsDeliveredBatchAndDrainsSingleObjectsOnArrayResponse {
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    self.manager.loggingMode = kGLLoggingModeOwntracks;
    [self.manager processLocations:@[[self location:45.5 time:1000], [self location:45.501 time:1010], [self location:45.502 time:1020]]];
    XCTAssertEqual(self.count, 3);
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    self.manager.sendingInterval = @60;
    __block int requests = 0;
    requestHandler = ^(OverlandTestProtocol *request) {
        requests++;
        [request respond:@"[]" status:200];
    };
    [self.manager sendQueueIfTimeElapsed];
    [self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return self.count == 0 && !self.manager.sendInProgress;
    }] evaluatedWithObject:self.manager handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertEqual(requests, 3);
}
- (void)testOwntracksAcceptsEmpty204AndKeepsRecordsOnServerFailure {
    [self queue:@{@"_type": @"location", @"tst": @1000} key:@"one"];
    [self queue:@{@"_type": @"transition", @"tst": @1010} key:@"event"];
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:nil];
    __block int requests = 0;
    requestHandler = ^(OverlandTestProtocol *request) {
        requests++;
        [request respond:@"" status:requests == 1 ? 204 : 503];
    };
    [self.manager sendQueueNow];
    [self expectationForPredicate:[NSPredicate predicateWithBlock:^BOOL(id object, NSDictionary *bindings) {
        return requests == 2 && !self.manager.sendInProgress;
    }] evaluatedWithObject:self.manager handler:nil];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertNil([self queued:@"one"]);
    XCTAssertNotNil([self queued:@"event"]);
}
- (void)testOnlyLatestPreservesEventsSummariesAndNewerQueuedLocations {
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    self.manager.loggingMode = kGLLoggingModeOnlyLatest;
    [self queue:@{@"_type": @"location", @"tst": @900} key:@"older"];
    [self queue:@{@"_type": @"location", @"tst": @1100} key:@"newer"];
    [self queue:@{@"_type": @"transition", @"tst": @900} key:@"transition"];
    [self queue:@{@"type": @"Feature", @"properties": @{@"type": @"trip", @"timestamp": @"1970-01-01T00:15:00Z"}} key:@"trip"];
    [self queue:@{@"type": @"Feature", @"properties": @{@"action": @"visit", @"timestamp": @"1970-01-01T00:15:00Z"}} key:@"visit"];
    [self.manager processLocations:@[[self location:45.5 time:1000]]];
    XCTAssertNil([self queued:@"older"]);
    for(NSString *key in @[@"newer", @"transition", @"trip", @"visit"]) XCTAssertNotNil([self queued:key]);
    XCTAssertEqual(self.count, 5);
}
- (void)testNewEngineToggleDefaultsOffAndPreservesEveryPreset {
    XCTAssertFalse(self.manager.useNewLocationEngine);
    for(NSInteger profile = 1; profile <= 5; profile++) {
        [self.manager applyUsageProfile:profile];
        NSDictionary *before = [NSUserDefaults.standardUserDefaults persistentDomainForName:self.defaultsSuite];
        self.manager.useNewLocationEngine = YES;
        XCTAssertEqual(self.manager.usageProfile, profile);
        XCTAssertEqual(self.manager.shouldUseLiveUpdates, profile != 2);
        NSDictionary *after = [NSUserDefaults.standardUserDefaults persistentDomainForName:self.defaultsSuite];
        for(NSString *key in before) {
            if(![key isEqual:GLUseNewLocationEngineDefaultsName]) XCTAssertEqualObjects(before[key], after[key]);
        }
        self.manager.useNewLocationEngine = NO;
        XCTAssertFalse(self.manager.shouldUseLiveUpdates);
    }
}
- (void)testNewEngineOffPreservesCustomBestAutomaticPausePath {
    [self.manager applyUsageProfile:1];
    self.manager.pausesAutomatically = YES;
    XCTAssertTrue(self.manager.shouldUseLiveUpdates);
    self.manager.pausesAutomatically = NO;
    XCTAssertFalse(self.manager.shouldUseLiveUpdates);
    self.manager.useNewLocationEngine = YES;
    XCTAssertTrue(self.manager.shouldUseLiveUpdates);
    [self.manager applyUsageProfile:2];
    XCTAssertTrue(self.manager.useNewLocationEngine);
    XCTAssertFalse(self.manager.hasContinuousUpdates);
    XCTAssertFalse(self.manager.shouldUseLiveUpdates);
    [NSUserDefaults.standardUserDefaults setObject:NSDate.date forKey:GLTripStartTimeDefaultsName];
    XCTAssertTrue(self.manager.hasContinuousUpdates);
    XCTAssertTrue(self.manager.shouldUseLiveUpdates);
}

- (void)testAdvancedOptionsDefaultToLegacyBehaviorAndSurviveEveryPreset {
    NSDictionary *options = self.manager.advancedTrackingOptions;
    for(NSString *key in @[@"adaptive", @"motion_assist", @"motion_resume_radius", @"any_threshold", @"reject_jumps",
        @"background_uploads", @"connectivity_retry", @"explicit_service_session"]) XCTAssertFalse([options[key] boolValue]);
    [self.manager setAdvancedTrackingOption:@YES forKey:@"any_threshold"];
    NSDictionary *saved = self.manager.advancedTrackingOptions;
    for(NSInteger profile = 1; profile <= 5; profile++) {
        [self.manager applyUsageProfile:profile];
        XCTAssertEqual(self.manager.usageProfile, profile);
        XCTAssertEqualObjects(self.manager.advancedTrackingOptions, saved);
    }
}

- (void)testMalformedAdvancedOptionsAreIgnoredOrClamped {
    [self.manager updateSettingsFromResponse:@{@"set": @{@"advanced_tracking": @{
        @"adaptive": @YES, @"adaptive_radius": @-50, @"adaptive_idle_accuracy": @90000,
        @"motion_confidence": @100, @"reject_jumps": @"yes", @"unknown": @YES}}}];
    NSDictionary *options = self.manager.advancedTrackingOptions;
    XCTAssertTrue([options[@"adaptive"] boolValue]);
    XCTAssertEqual([options[@"adaptive_radius"] doubleValue], 10);
    XCTAssertEqual([options[@"adaptive_idle_accuracy"] doubleValue], 3000);
    XCTAssertEqual([options[@"motion_confidence"] integerValue], 2);
    XCTAssertFalse([options[@"reject_jumps"] boolValue]);
    XCTAssertNil(options[@"unknown"]);
}

- (void)testOnlyLatestSafelyHandlesACompletelyRejectedBatch {
    self.manager.loggingMode = kGLLoggingModeOnlyLatest;
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    CLLocation *future = [self location:45 time:NSDate.date.timeIntervalSince1970 + 60];
    XCTAssertNoThrow([self.manager processLocations:@[future]]);
    XCTAssertEqual(self.count, 0);
    self.manager.discardPointsOutsideAccuracy = 1;
    [self.manager setAdvancedTrackingOption:@YES forKey:@"reject_jumps"];
    CLLocation *inaccurate = [self location:45 time:NSDate.date.timeIntervalSince1970 - 1];
    XCTAssertNoThrow([self.manager processLocations:@[inaccurate]]);
    XCTAssertEqual(self.count, 0);
    XCTAssertNotNil(self.manager.lastReceivedLocation);
    XCTAssertNil(self.manager.lastLocation);
}

- (void)testOptionalORSelectionRecordsDistanceBeforeFiveSeconds {
    self.manager.discardPointsWithinDistance = 10;
    self.manager.discardPointsWithinSeconds = 5;
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    [self.manager processLocations:@[[self location:45 time:now - 10]]];
    [self.manager processLocations:@[[self location:45.001 time:now - 9]]];
    XCTAssertEqual(self.count, 1);
    [self.manager setAdvancedTrackingOption:@YES forKey:@"any_threshold"];
    [self.manager processLocations:@[[self location:45.001 time:now - 8]]];
    XCTAssertEqual(self.count, 2);
}

- (void)testModeTransitionsRestartTheManagerAndEquivalentSettingsDoNot {
    TestLocationManager *location = [TestLocationManager new];
    [self.manager setValue:location forKey:@"locationManager"];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    [self.manager applyTrackingConfiguration];
    XCTAssertEqual(location.startCount, 1);
    [self.manager applyTrackingConfiguration];
    XCTAssertEqual(location.startCount, 1);
    self.manager.trackingMode = kGLTrackingModeSignificant;
    self.manager.trackingMode = kGLTrackingModeStandard;
    XCTAssertEqual(location.startCount, 2);
}

- (void)testRemoteSettingsCoalesceAcquisitionReconfiguration {
    TestLocationManager *location = [TestLocationManager new];
    [self.manager setValue:location forKey:@"locationManager"];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    [self.manager applyTrackingConfiguration];
    NSUInteger before = location.startCount;
    [self.manager updateSettingsFromResponse:@{@"set": @{@"main": @{
        @"tracking_mode": @"both", @"activity_type": @"car", @"desired_accuracy": @"10m"}}}];
    XCTAssertEqual(location.startCount, before + 1);
    XCTAssertEqual(self.manager.trackingMode, kGLTrackingModeStandardAndSignificant);
    XCTAssertEqual(self.manager.desiredAccuracy, 10);
}

- (void)testRadiusPauseSurvivesRestoreAndDelayedFixCannotResumeIt {
    TestLocationManager *location = [TestLocationManager new];
    [self.manager setValue:location forKey:@"locationManager"];
    self.manager.trackingMode = kGLTrackingModeStandardAndSignificant;
    self.manager.stopsAutomaticallyRadius = 50;
    self.manager.didPauseByRadius = YES;
    NSDate *pause = [NSDate dateWithTimeIntervalSinceNow:-300];
    [self.manager setValue:pause forKey:@"radiusPauseDate"];
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:GLTrackingStateDefaultsName];
    XCTAssertTrue([NSUserDefaults.standardUserDefaults boolForKey:GLTrackingStateDefaultsName]);
    XCTAssertTrue(self.manager.didPauseByRadius);
    XCTAssertTrue(self.manager.stopsAutomaticallyActive);
    // Reopen the persisted domain as a fresh launch would, without the prior defaults cache.
    XCTAssertTrue([fixtureDefaults synchronize]);
    fixtureDefaults = [[NSUserDefaults alloc] initWithSuiteName:self.defaultsSuite];
    [self.manager restoreTrackingState];
    XCTAssertTrue(self.manager.trackingEnabled);
    XCTAssertTrue(self.manager.didPauseByRadius);
    XCTAssertEqual(location.startCount, 0);
    CLLocation *delayed = [self location:45 time:[pause timeIntervalSince1970] + 1];
    XCTAssertFalse([self.manager observeMovementLocation:delayed]);
    XCTAssertTrue(self.manager.didPauseByRadius);
    XCTAssertEqual(location.startCount, 0);
}

- (void)testMotionLabelsUseThePointTimestampRatherThanLatestActivity {
    TestMotionManager *manager = [TestMotionManager new];
    NSDate *now = NSDate.date;
    TestMotionActivity *walking = [TestMotionActivity new];
    walking.date = [now dateByAddingTimeInterval:-20];
    TestMotionActivity *driving = [TestMotionActivity new];
    driving.date = [now dateByAddingTimeInterval:-5];
    driving.inCar = YES;
    [manager rememberMotion:walking];
    [manager rememberMotion:driving];
    [manager setValue:driving forKey:@"lastMotion"];
    XCTAssertEqualObjects([manager motionArrayForDate:[now dateByAddingTimeInterval:-10]], (@[@"walking"]));
    XCTAssertEqualObjects([manager motionArrayForDate:now], (@[@"driving"]));
    XCTAssertEqualObjects([manager motionArrayForDate:[now dateByAddingTimeInterval:-30]], @[]);
}

- (void)testQueuedMotionCannotUndoRadiusPauseOrExplicitStop {
    TestMotionManager *manager = [TestMotionManager new];
    TestLocationManager *location = [TestLocationManager new];
    [manager setValue:location forKey:@"locationManager"];
    manager.trackingMode = kGLTrackingModeStandardAndSignificant;
    manager.stopsAutomaticallyRadius = 50;
    [manager setAdvancedTrackingOption:@YES forKey:@"motion_assist"];
    [manager setAdvancedTrackingOption:@YES forKey:@"motion_resume_radius"];
    [manager setValue:@YES forKey:@"trackingEnabled"];
    manager.didPauseByRadius = YES;
    NSDate *pause = [NSDate dateWithTimeIntervalSinceNow:-5];
    [manager setValue:pause forKey:@"radiusPauseDate"];
    TestMotionActivity *queued = [TestMotionActivity new];
    queued.date = [pause dateByAddingTimeInterval:-1];
    [manager processMotionActivity:queued];
    XCTAssertTrue(manager.didPauseByRadius);
    XCTAssertEqual(location.startCount, 0);
    TestMotionActivity *departure = [TestMotionActivity new];
    departure.date = [pause dateByAddingTimeInterval:1];
    [manager processMotionActivity:departure];
    XCTAssertFalse(manager.didPauseByRadius);
    XCTAssertEqual(location.startCount, 1);
    [manager stopAllUpdates];
    [manager processMotionActivity:departure];
    XCTAssertFalse(manager.trackingEnabled);
    XCTAssertEqual(location.startCount, 1);
}

- (void)testRadiusPauseClearsAdaptiveQuietStateAndRegion {
    TestLocationManager *location = [TestLocationManager new];
    [self.manager setValue:location forKey:@"locationManager"];
    [self.manager applyUsageProfile:3];
    [self.manager setAdvancedTrackingOption:@YES forKey:@"adaptive"];
    [self.manager setAdvancedTrackingOption:@NO forKey:@"adaptive_require_motion"];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    GLAdaptivePolicy *policy = [self.manager valueForKey:@"adaptivePolicy"];
    NSDate *now = NSDate.date;
    CLLocation *fix;
    for(NSNumber *offset in @[@-130, @-65, @-1]) {
        fix = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(45.5, -122.67)
            altitude:0 horizontalAccuracy:5 verticalAccuracy:-1 timestamp:[now dateByAddingTimeInterval:offset.doubleValue]];
        [policy observeLocation:fix motion:GLMovementStationary now:fix.timestamp dwell:120 radius:30 maxAccuracy:25 requireMotion:NO];
    }
    XCTAssertTrue(policy.stationary);
    CLCircularRegion *region = [[CLCircularRegion alloc] initWithCenter:fix.coordinate radius:100 identifier:@"adaptive-stationary"];
    [location startMonitoringForRegion:region];
    self.manager.lastLocationMovedBeyondStopThreshold = fix;
    self.manager.lastTimeMovedBeyondStopThreshold = [now dateByAddingTimeInterval:-400];
    fix = [[CLLocation alloc] initWithCoordinate:fix.coordinate altitude:0 horizontalAccuracy:5 verticalAccuracy:-1 timestamp:now];
    [self.manager processLocations:@[fix]];
    XCTAssertTrue(self.manager.didPauseByRadius);
    XCTAssertFalse(policy.stationary);
    XCTAssertEqual(location.monitoredRegions.count, 0);
}

- (void)testReconcileCannotStartContinuousUpdatesWithoutAuthorization {
    TestLocationManager *location = [TestLocationManager new];
    [self.manager setValue:location forKey:@"locationManager"];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    for(NSNumber *status in @[@(kCLAuthorizationStatusDenied), @(kCLAuthorizationStatusRestricted), @(kCLAuthorizationStatusNotDetermined)]) {
        location.authorizationOverride = status;
        [self.manager reconcileTracking];
        XCTAssertEqual(location.startCount, 0);
    }
    location.authorizationOverride = @(kCLAuthorizationStatusAuthorizedAlways);
    [self.manager reconcileTracking];
    XCTAssertEqual(location.startCount, 1);
}

- (void)testConnectivityRetryCannotOverrideServerRetryAfter {
    [self.manager saveNewAPIEndpoint:@"https://overland.test/" andAccessToken:@"test"];
    self.manager.sendingInterval = @60;
    [self.manager setAdvancedTrackingOption:@YES forKey:@"connectivity_retry"];
    [self.manager setValue:@YES forKey:@"uploadPending"];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://overland.test/"]
        statusCode:503 HTTPVersion:@"HTTP/1.1" headerFields:@{@"Retry-After": @"600"}];
    [self.manager deferUploadForResponse:response error:nil];
    NSDate *retry = self.manager.uploadRetryDate;
    [self.manager resumeUploadAfterConnectivity];
    XCTAssertEqualObjects(self.manager.uploadRetryDate, retry);
    XCTAssertGreaterThan(self.manager.uploadRetryDate.timeIntervalSinceNow, 590);
}
- (TestCloudWriter *)cloudWriterWithQueuedPoint {
    TestCloudWriter *writer = [TestCloudWriter new];
    [self.manager setValue:writer forKey:@"cloudWriter"];
    self.manager.savesToICloudDrive = YES;
    [self queue:@{@"type": @"Feature", @"geometry": NSNull.null, @"properties": @{@"timestamp": @"2026-10-19T12:00:00Z"}} key:@"cloud-point"];
    return writer;
}
- (void)testCloudExportAcknowledgesTheQueuedPointWithoutAServer {
    TestCloudWriter *writer = [self cloudWriterWithQueuedPoint];
    [self.manager sendQueueNow];
    XCTAssertTrue(self.manager.sendInProgress);
    XCTAssertEqualObjects(writer.captured.firstObject[@"id"], @"cloud-point");
    writer.finish(nil);
    writer.finish = nil;
    XCTAssertFalse(self.manager.sendInProgress);
    XCTAssertEqual(self.count, 0);
}
- (void)testCloudExportFailureKeepsQueuedRecordsAndRetryIntent {
    TestCloudWriter *writer = [self cloudWriterWithQueuedPoint];
    [self.manager sendQueueNow];
    writer.finish(@"iCloud is temporarily unavailable");
    writer.finish = nil;
    XCTAssertFalse(self.manager.sendInProgress);
    XCTAssertEqual(self.count, 1);
    XCTAssertTrue(self.manager.pendingUploads);
    XCTAssertGreaterThan(self.manager.uploadRetryDate.timeIntervalSinceNow, 0);
}
- (void)testCloudExportKeepsRecordsWhenQueueAcknowledgementCannotCommit {
    TestCloudWriter *writer = [self cloudWriterWithQueuedPoint];
    [self.manager sendQueueNow];
    [self failCommits:YES];
    writer.finish(nil);
    writer.finish = nil;
    [self failCommits:NO];
    XCTAssertEqual(self.count, 1);
    XCTAssertFalse(self.manager.sendInProgress);
    XCTAssertTrue(self.manager.pendingUploads);
}
- (void)testStationaryFilterKeepsTheStopAndHourlyHeartbeatDespiteDistanceLimit {
    self.manager = [TestMotionManager new];
    [self.manager setValue:self.db forKey:@"db"];
    [self.manager setValue:@(UIBackgroundTaskInvalid) forKey:@"sendBackgroundTask"];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    self.manager.sendingInterval = @-1;
    self.manager.discardPointsWhileStationary = YES;
    self.manager.discardPointsWithinDistance = 100;
    NSDate *start = [NSDate dateWithTimeIntervalSinceNow:-7200];
    TestStationaryActivity *activity = [TestStationaryActivity new];
    activity.date = start;
    [self.manager rememberMotion:activity];
    for(NSNumber *offset in @[@0, @60, @3600]) {
        CLLocation *point = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(45, -122)
            altitude:1 horizontalAccuracy:5 verticalAccuracy:5 course:0 speed:0
            timestamp:[start dateByAddingTimeInterval:offset.doubleValue]];
        [self.manager processLocations:@[point]];
    }
    XCTAssertEqual(self.count, 2);
}
- (void)testGPSHeuristicFilterLeavesTheCommittedBaselineUnchangedForRejectedFixes {
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    self.manager.discardPointsWithoutGPS = YES;
    CLLocation *point = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(45, -122)
        altitude:0 horizontalAccuracy:5 verticalAccuracy:-1 course:-1 speed:-1 timestamp:NSDate.date];
    [self.manager processLocations:@[point]];
    XCTAssertEqual(self.count, 0);
    XCTAssertNil(self.manager.lastLocation);
    self.manager.discardPointsWithoutGPS = NO;
    [self.manager processLocations:@[point]];
    XCTAssertEqual(self.count, 1);
    XCTAssertEqualObjects(self.manager.lastLocation, point);
}

- (NSDictionary *)workoutImportPoint {
    return @{@"type": @"Feature", @"id": @"healthkit:workout:point", @"geometry": @{@"type": @"Point", @"coordinates": @[@(-122), @45]},
             @"properties": @{@"source": @"healthkit", @"timestamp": @"2020-01-01T00:00:00.125Z"}};
}
- (void)testWorkoutImportDoesNotAdvanceLiveLocationOrStartTrackingAndRetriesDoNotDuplicate {
    self.manager.loggingMode = kGLLoggingModeAllData;
    CLLocation *baseline = [self location:45.5 time:NSDate.date.timeIntervalSince1970];
    [self.manager setValue:baseline forKey:@"lastLocation"];
    BOOL tracking = self.manager.trackingEnabled;
    XCTestExpectation *done = [self expectationWithDescription:@"Historical route queued"];
    [self.manager enqueueWorkoutImportRecords:@[[self workoutImportPoint]] completion:^(NSUInteger inserted, NSString *error) {
        XCTAssertNil(error); XCTAssertEqual(inserted, 1);
        XCTAssertEqualObjects(self.manager.lastLocation, baseline);
        XCTAssertEqual(self.manager.trackingEnabled, tracking);
        [self.manager enqueueWorkoutImportRecords:@[[self workoutImportPoint]] completion:^(NSUInteger repeated, NSString *retryError) {
            XCTAssertNil(retryError); XCTAssertEqual(repeated, 0); [done fulfill];
        }];
    }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertEqual(self.count, 1);
}
- (void)testOnlyLatestDoesNotPrunePreviouslyQueuedWorkoutImports {
    self.manager.loggingMode = kGLLoggingModeAllData;
    XCTestExpectation *done = [self expectationWithDescription:@"Import committed"];
    [self.manager enqueueWorkoutImportRecords:@[[self workoutImportPoint]] completion:^(NSUInteger inserted, NSString *error) {
        XCTAssertNil(error); [done fulfill];
    }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    self.manager.loggingMode = kGLLoggingModeOnlyLatest;
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    [self.manager processLocations:@[[self location:45.5 time:NSDate.date.timeIntervalSince1970 - 1]]];
    XCTAssertEqual(self.count, 2);
}
- (void)testWorkoutImportRequiresFullHistoryLoggingBeforeQueueing {
    self.manager.loggingMode = kGLLoggingModeOwntracks;
    XCTestExpectation *done = [self expectationWithDescription:@"Incompatible mode explained"];
    [self.manager enqueueWorkoutImportRecords:@[[self workoutImportPoint]] completion:^(NSUInteger inserted, NSString *error) {
        XCTAssertNotNil(error); XCTAssertEqual(inserted, 0); [done fulfill];
    }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    XCTAssertEqual(self.count, 0);
}

- (TestLocationManager *)recoveryLocationManager {
    TestLocationManager *location = [TestLocationManager new];
    [self.manager setValue:location forKey:@"locationManager"];
    self.manager.trackingMode = kGLTrackingModeStandard;
    self.manager.desiredAccuracy = kCLLocationAccuracyBest;
    self.manager.pausesAutomatically = NO;
    return location;
}
- (void)testRecoveryMonitoringDefaultsOffAndDoesNotChangeStandardTracking {
    TestLocationManager *location = [self recoveryLocationManager];
    XCTAssertFalse([self.manager.advancedTrackingOptions[@"background_recovery"] boolValue]);
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    [self.manager applyTrackingConfiguration];
    XCTAssertEqual(location.startCount, 1);
    XCTAssertEqual(location.significantStartCount, 0);
    XCTAssertGreaterThan(location.significantStopCount, 0);
}
- (void)testRecoveryMonitoringAddsRelaunchSourceDuringStandardTrackingAndTrips {
    TestLocationManager *location = [self recoveryLocationManager];
    [self.manager setAdvancedTrackingOption:@YES forKey:@"background_recovery"];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    [self.manager applyTrackingConfiguration];
    XCTAssertEqual(location.startCount, 1);
    XCTAssertEqual(location.significantStartCount, 1);
    [NSUserDefaults.standardUserDefaults setObject:NSDate.date forKey:GLTripStartTimeDefaultsName];
    [self.manager applyTrackingConfiguration];
    XCTAssertEqual(location.significantStartCount, 2);
}
- (void)testRecoveryMonitoringRequiresAlwaysAndCanBeDisabledWithoutRestartingGPS {
    TestLocationManager *location = [self recoveryLocationManager];
    [self.manager setAdvancedTrackingOption:@YES forKey:@"background_recovery"];
    location.authorizationOverride = @(kCLAuthorizationStatusAuthorizedWhenInUse);
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    [self.manager applyTrackingConfiguration];
    XCTAssertEqual(location.significantStartCount, 0);
    location.authorizationOverride = @(kCLAuthorizationStatusAuthorizedAlways);
    [self.manager applyTrackingConfiguration];
    XCTAssertEqual(location.significantStartCount, 1);
    NSUInteger starts = location.startCount;
    [self.manager setAdvancedTrackingOption:@NO forKey:@"background_recovery"];
    XCTAssertEqual(location.significantStartCount, 1);
    XCTAssertGreaterThan(location.significantStopCount, 0);
    XCTAssertEqual(location.startCount, starts);
}
- (void)testRecoveryMonitoringDoesNotOverrideStopOrEventOnlyMode {
    TestLocationManager *location = [self recoveryLocationManager];
    [self.manager setAdvancedTrackingOption:@YES forKey:@"background_recovery"];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    [self.manager applyTrackingConfiguration];
    [self.manager stopAllUpdates];
    NSUInteger starts = location.significantStartCount;
    NSUInteger stops = location.significantStopCount;
    XCTAssertGreaterThan(stops, 0);
    [self.manager applyTrackingConfiguration];
    XCTAssertEqual(location.significantStartCount, starts);
    self.manager.trackingMode = kGLTrackingModeOff;
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    [self.manager applyTrackingConfiguration];
    XCTAssertEqual(location.significantStartCount, starts);
}
- (void)testRecoveryMonitoringHonorsDeviceSupportAndPreservesPresetSelection {
    TestUnavailableRecoveryManager *location = [TestUnavailableRecoveryManager new];
    [self.manager setValue:location forKey:@"locationManager"];
    [self.manager setAdvancedTrackingOption:@YES forKey:@"background_recovery"];
    [self.manager setValue:@YES forKey:@"trackingEnabled"];
    [self.manager applyUsageProfile:1];
    [self.manager applyTrackingConfiguration];
    XCTAssertEqual(location.significantStartCount, 0);
    XCTAssertEqual(self.manager.usageProfile, 1);
    XCTAssertTrue([self.manager.advancedTrackingOptions[@"background_recovery"] boolValue]);
}

- (void)testChangingDestinationIgnoresLateCloudAcknowledgement {
    TestCloudWriter *writer = [self cloudWriterWithQueuedPoint];
    [self.manager sendQueueNow];
    void (^completion)(NSString *) = writer.finish;
    self.manager.savesToICloudDrive = NO;
    completion(nil);
    writer.finish = nil;
    XCTAssertEqual(self.count, 1);
    XCTAssertFalse(self.manager.sendInProgress);
}
- (void)testUnchangedDestinationKeepsTheActiveCloudExport {
    TestCloudWriter *writer = [self cloudWriterWithQueuedPoint];
    [self.manager sendQueueNow];
    self.manager.savesToICloudDrive = YES;
    XCTAssertTrue(self.manager.sendInProgress);
    writer.finish(nil);
    writer.finish = nil;
    XCTAssertEqual(self.count, 0);
}

@end
