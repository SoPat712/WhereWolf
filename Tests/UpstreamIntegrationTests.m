#import <XCTest/XCTest.h>
#import "GLManager.h"
#import "GLCloudFileWriter.h"
#import "LOLDatabase.h"

@interface GLManager (UpstreamTesting)
+ (NSData *)dataWithJSONObject:(id)object error:(NSError **)error;
- (void)processLocations:(NSArray *)locations;
- (void)rememberMotion:(CMMotionActivity *)activity;
- (NSDictionary *)cloudFeature:(NSDictionary *)record key:(NSString *)key;
@end

@interface IntegrationMotion : CMMotionActivity
@property NSDate *date;
@end
@implementation IntegrationMotion
- (NSDate *)startDate { return self.date; }
- (BOOL)stationary { return YES; }
- (CMMotionActivityConfidence)confidence { return CMMotionActivityConfidenceLow; }
@end

@interface UpstreamIntegrationTests : XCTestCase
@property NSURL *directory;
@property GLCloudFileWriter *writer;
@property NSDictionary *savedDefaults;
@end

@implementation UpstreamIntegrationTests
- (void)setUp {
    [super setUp];
    self.savedDefaults = [NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier] ?: @{};
    self.directory = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    self.writer = [[GLCloudFileWriter alloc] initWithDocumentsURL:self.directory];
}
- (void)tearDown {
    [NSFileManager.defaultManager removeItemAtURL:self.directory error:nil];
    [NSUserDefaults.standardUserDefaults setPersistentDomain:self.savedDefaults forName:NSBundle.mainBundle.bundleIdentifier];
    [super tearDown];
}
- (NSDictionary *)feature:(NSString *)identifier timestamp:(NSString *)timestamp {
    return @{@"id": identifier, @"type": @"Feature", @"geometry": @{@"type": @"Point", @"coordinates": @[@(-122), @45]},
             @"properties": @{@"timestamp": timestamp}};
}
- (NSString *)write:(NSArray *)features mode:(GLCloudFileMode)mode {
    XCTestExpectation *done = [self expectationWithDescription:@"File export completed"];
    __block NSString *message;
    [self.writer writeFeatures:features mode:mode completion:^(NSString *error) { message = error; [done fulfill]; }];
    [self waitForExpectationsWithTimeout:5 handler:nil];
    return message;
}
- (NSArray *)featuresAt:(NSString *)relative {
    NSData *data = [NSData dataWithContentsOfURL:[self.directory URLByAppendingPathComponent:relative]];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil][@"features"] : nil;
}
- (LOLDatabase *)importDatabase {
    LOLDatabase *db = [[LOLDatabase alloc] initWithPath:@":memory:"];
    db.serializer = ^NSData *(id object) {
        return [NSJSONSerialization isValidJSONObject:object] ? [NSJSONSerialization dataWithJSONObject:object options:0 error:nil] : nil;
    };
    db.deserializer = ^id(NSData *data) { return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]; };
    return db;
}
- (void)testWorkoutImportReceiptsSurviveQueueDeletionAndAllowOnlyNewPoints {
    LOLDatabase *db = [self importDatabase];
    NSArray *records = @[[self feature:@"healthkit:a" timestamp:@"2026-10-19T12:00:00Z"],
                         [self feature:@"healthkit:b" timestamp:@"2026-10-19T12:00:05Z"]];
    NSUInteger count = 0;
    XCTAssertTrue(([db importRecords:records keys:@[@"healthkit:a", @"healthkit:b"] intoCollection:@"queue" insertedCount:&count]));
    XCTAssertEqual(count, 2);
    XCTAssertTrue([db accessCollection:@"queue" withBlock:^(id<LOLDatabaseAccessor> accessor) { [accessor deleteAllData]; }]);
    XCTAssertTrue(([db importRecords:records keys:@[@"healthkit:a", @"healthkit:b"] intoCollection:@"queue" insertedCount:&count]));
    XCTAssertEqual(count, 0);
    XCTAssertTrue(([db importRecords:@[records[0], [self feature:@"healthkit:c" timestamp:@"2026-10-19T12:00:10Z"]]
                              keys:@[@"healthkit:a", @"healthkit:c"] intoCollection:@"queue" insertedCount:&count]));
    XCTAssertEqual(count, 1);
}
- (void)testWorkoutImportSerializationFailureRollsBackRecordsAndReceipts {
    LOLDatabase *db = [self importDatabase];
    NSDictionary *valid = [self feature:@"healthkit:a" timestamp:@"2026-10-19T12:00:00Z"];
    NSUInteger count = 100;
    XCTAssertFalse(([db importRecords:@[valid, @{@"invalid": NSDate.date}] keys:@[@"healthkit:a", @"healthkit:b"]
                      intoCollection:@"queue" insertedCount:&count]));
    XCTAssertEqual(count, 0);
    XCTAssertTrue([db accessCollection:@"queue" withBlock:^(id<LOLDatabaseAccessor> accessor) {
        [accessor countObjectsUsingBlock:^(long num) { XCTAssertEqual(num, 0); }];
    }]);
    XCTAssertTrue(([db importRecords:@[valid, valid] keys:@[@"healthkit:a", @"healthkit:b"]
                     intoCollection:@"queue" insertedCount:&count]));
    XCTAssertEqual(count, 2);
}
- (void)testImportedFractionalTimestampsUseTheOriginalCloudDay {
    XCTAssertNil(([self write:@[[self feature:@"healthkit:a" timestamp:@"2026-10-19T23:59:59.125Z"]] mode:GLCloudFileModeDaily]));
    XCTAssertEqual([self featuresAt:@"2026/10/2026-10-19.geojson"].count, 1);
}
- (void)testDailyCloudExportRetriesDoNotDuplicateRecordsAcrossDays {
    NSArray *features = @[[self feature:@"a" timestamp:@"2026-10-19T23:59:59Z"],
                         [self feature:@"b" timestamp:@"2026-10-20T00:00:01Z"]];
    XCTAssertNil([self write:features mode:GLCloudFileModeDaily]);
    XCTAssertNil([self write:features mode:GLCloudFileModeDaily]);
    XCTAssertEqual([self featuresAt:@"2026/10/2026-10-19.geojson"].count, 1);
    XCTAssertEqual([self featuresAt:@"2026/10/2026-10-20.geojson"].count, 1);
}
- (void)testPartialCloudFailureRetainsTheExistingFileAndRetryIsIdempotent {
    NSURL *bad = [self.directory URLByAppendingPathComponent:@"2026/10/2026-10-20.geojson"];
    [NSFileManager.defaultManager createDirectoryAtURL:bad.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *original = [@"an externally damaged file" dataUsingEncoding:NSUTF8StringEncoding];
    [original writeToURL:bad atomically:YES];
    NSArray *features = @[[self feature:@"a" timestamp:@"2026-10-19T12:00:00Z"],
                         [self feature:@"b" timestamp:@"2026-10-20T12:00:00Z"]];
    XCTAssertNotNil([self write:features mode:GLCloudFileModeDaily]);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:bad], original);
    XCTAssertEqual([self featuresAt:@"2026/10/2026-10-19.geojson"].count, 1);
    [NSFileManager.defaultManager removeItemAtURL:bad error:nil];
    XCTAssertNil([self write:features mode:GLCloudFileModeDaily]);
    XCTAssertEqual([self featuresAt:@"2026/10/2026-10-19.geojson"].count, 1);
    XCTAssertEqual([self featuresAt:@"2026/10/2026-10-20.geojson"].count, 1);
}
- (void)testTripCloudExportGroupsPointsAndSummaryAndOmitsNonTripRecords {
    NSMutableDictionary *point = [[self feature:@"point" timestamp:@"2026-10-19T12:00:01Z"] mutableCopy];
    point[@"properties"] = @{@"timestamp": @"2026-10-19T12:00:01Z", @"trip_id": @"2026-10-19T12:00:00Z"};
    NSDictionary *summary = @{@"id": @"trip", @"type": @"Feature", @"geometry": NSNull.null,
                              @"properties": @{@"type": @"trip", @"start": @"2026-10-19T12:00:00Z"}};
    XCTAssertNil(([self write:@[point, summary, [self feature:@"outside" timestamp:@"2026-10-19T11:00:00Z"]] mode:GLCloudFileModeTrips]));
    XCTAssertEqual([self featuresAt:@"Trips/2026-10-19T12-00-00Z.geojson"].count, 2);
}
- (void)testCloudWriterRejectsUnrepresentableDataWithoutAcknowledgingIt {
    XCTAssertNotNil(([self write:@[@{@"type": @"Feature", @"properties": @{@"value": @(NAN)}}] mode:GLCloudFileModeDaily]));
}
- (void)testNonfiniteJSONMetadataBecomesNullAndUnsupportedObjectsStillFail {
    NSData *data = [GLManager dataWithJSONObject:@{@"values": @[@(NAN), @(INFINITY), @1], @"nested": @{@"negative": @(-INFINITY)}} error:nil];
    NSDictionary *decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    XCTAssertEqualObjects(decoded[@"values"], (@[NSNull.null, NSNull.null, @1]));
    XCTAssertEqualObjects(decoded[@"nested"][@"negative"], NSNull.null);
    XCTAssertNil(([GLManager dataWithJSONObject:@{@"bad": NSSet.set} error:nil]));
}
- (void)testOwnTracksCloudConversionPreservesIdentityAndRecordedTime {
    GLManager *manager = [GLManager new];
    NSDictionary *feature = [manager cloudFeature:@{@"_type": @"location", @"tst": @1700000000, @"lat": @45, @"lon": @(-122), @"tid": @"ab"} key:@"queue-key"];
    XCTAssertEqualObjects(feature[@"id"], @"queue-key");
    XCTAssertEqualObjects(feature[@"geometry"][@"coordinates"], (@[@(-122), @45]));
    XCTAssertEqualObjects(feature[@"properties"][@"tid"], @"ab");
    XCTAssertEqualObjects(feature[@"properties"][@"timestamp"], @"2023-11-14T22:13:20Z");
}
- (void)testNewOptionsAreOffAndDoNotReplaceExistingPresets {
    [NSUserDefaults.standardUserDefaults removePersistentDomainForName:NSBundle.mainBundle.bundleIdentifier];
    GLManager *manager = [GLManager new];
    XCTAssertFalse(manager.savesToICloudDrive);
    XCTAssertFalse(manager.discardPointsWithoutGPS);
    XCTAssertFalse(manager.discardPointsWhileStationary);
    XCTAssertFalse(manager.discardPointsWithoutGPSDuringTrip);
    XCTAssertFalse(manager.discardPointsWhileStationaryDuringTrip);
    XCTAssertFalse(manager.tripLiveActivityEnabled);
    for(NSInteger profile = 1; profile <= 5; profile++) {
        [manager applyUsageProfile:profile];
        XCTAssertEqual(manager.usageProfile, profile);
        XCTAssertFalse(manager.savesToICloudDrive);
        XCTAssertFalse(manager.discardPointsWhileStationary);
    }
}
@end
