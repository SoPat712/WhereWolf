//
//  GLManager.m
//  GPSLogger
//
//  Created by Aaron Parecki on 9/17/15.
//  Copyright © 2015 Esri. All rights reserved.
//  Copyright © 2017 Aaron Parecki. All rights reserved.
//

#import "GLManager.h"
#import "GLCloudFileWriter.h"
#import "LOLDatabase.h"
#import "fmdb/FMDatabase.h"
#import <UIKit/UIKit.h>
#import "GLTrackingPolicy.h"
#import "GLLocationHealth.h"
#import "SystemConfiguration/CaptiveNetwork.h"
#import <Security/Security.h>
#import <sqlite3.h>
#import <float.h>
#import "WhereWolf-Swift.h"
@import UserNotifications;
@import NetworkExtension;

const CLLocationDistance GLWifiPlaceMatchDistance = 300;
const NSTimeInterval GLWifiPlaceHeartbeatInterval = 300;

@interface GLManager()

- (void)postLocalNotification:(NSString *)message title:(NSString *)title;
- (void)applyTrackingConfiguration;
- (void)requestTrackingReconfiguration;
- (void)updateMotionTracking;
- (void)removeAdaptiveRegion;
- (void)updateAdaptiveRegion;
- (NSArray *)motionArrayForDate:(NSDate *)date;
- (void)queryMotionHistoryRequestingPermission:(BOOL)request;
- (void)rememberWifiNetworkInfo:(NSDictionary *)info;
- (void)rememberWifiNetworkInfo:(NSDictionary *)info location:(CLLocation *)fix date:(NSDate *)now;
- (NSDictionary *)wifiNetworkInfoForBatch;
+ (NSArray<NSDictionary *> *)knownWifiNetworksAtDate:(NSDate *)now;
+ (NSArray<NSDictionary *> *)frequentWifiNetworksAtDate:(NSDate *)now places:(NSArray<NSDictionary *> *)places;
- (NSDictionary *)currentWifiPlaceForLocations:(NSArray<CLLocation *> *)locations networkInfo:(NSDictionary *)info;
- (NSArray<CLLocation *> *)locationsByApplyingWifiPlace:(NSArray<CLLocation *> *)locations networkInfo:(NSDictionary *)info;
- (void)reconcileLocationHealth;
- (void)evaluateLocationHealth;
- (NSTimeInterval)locationHealthUptime;
+ (void)initializeUsageProfileDefaults:(NSUserDefaults *)defaults domainName:(NSString *)domainName;

@property (strong, nonatomic) CLLocationManager *locationManager;
@property (strong, nonatomic) CMMotionActivityManager *motionActivityManager;
@property (strong, nonatomic) CMPedometer *pedometer;

@property BOOL trackingEnabled;
@property BOOL sendInProgress;
@property BOOL batchInProgress;
@property (strong, nonatomic) CLLocation *lastLocation;
@property (strong, nonatomic) CMMotionActivity *lastMotion;
@property (strong, nonatomic) NSDate *lastSentDate;
@property (strong, nonatomic) NSString *lastLocationName;

@property (strong, nonatomic) NSDictionary *lastLocationDictionary;
@property (strong, nonatomic) NSDictionary *batchWifiInfo;
@property (strong, nonatomic) NSString *wifiPlaceMatchID;
@property (strong, nonatomic) NSString *observedWifiSSID;
@property (strong, nonatomic) NSDate *observedWifiDate;
@property (strong, nonatomic) NSDictionary *tripStartLocationDictionary;

@property (strong, nonatomic) LOLDatabase *db;
@property (strong, nonatomic) FMDatabase *tripdb;

@property (strong, nonatomic) NSDate *lastScheduledNotificationDate;
@property NSUInteger reminderRevision;
@property NSUInteger notificationPermissionRevision;
@property BOOL reminderCancellationSent;

@property (strong, nonatomic) NSMutableArray<NSDictionary *> *sendResultsLog;
@property (nonatomic, assign) UIBackgroundTaskIdentifier sendBackgroundTask;
@property (strong, nonatomic) NSURLSessionDataTask *sendTask;
@property (strong, nonatomic) NSURLSession *httpSession;
@property (strong, nonatomic) GLCloudFileWriter *cloudWriter;
@property NSUInteger sendGeneration;
@property (strong, nonatomic) NSString *lastSendErrorTitle;
@property (strong, nonatomic) NSString *lastSendErrorMessage;
@property BOOL inStationaryStop;
@property (strong, nonatomic) NSDate *lastStationaryPointDate;
@property BOOL endingTrip;
@property BOOL tripDistanceLoaded;
@property CLLocationDistance tripDistanceCached;
@property (strong, nonatomic) CLLocation *lastTripLocation;
@property BOOL engineStationary;
@property (strong, nonatomic) CLLocation *lastMovementLocation;
@property (strong, nonatomic) NSDate *radiusPauseDate;
@property (strong, nonatomic) NSDate *lastSendAttempt;
@property (strong, nonatomic) NSDate *nextUploadDate;
@property (strong, nonatomic) NSDate *lastUploadErrorNotification;
@property (strong, nonatomic) NSTimer *uploadTimer;
@property NSUInteger uploadFailures;
@property NSUInteger drainRequests;
@property BOOL uploadBlocked;
@property BOOL uploadPending;
@property BOOL drainAll;
// Send Now drains the queue even while automatic sends wait for Wi-Fi.
@property BOOL userDrain;
@property BOOL waitingForNetwork;
@property (strong, nonatomic) CLLocation *lastReceivedLocation;
@property (nonatomic) NSUInteger rejectedJumpCount;
@property (strong, nonatomic) GLAdaptivePolicy *adaptivePolicy;
@property (strong, nonatomic) GLPointQualityPolicy *qualityPolicy;
@property (strong, nonatomic) CLLocation *qualityObservation;
@property (strong, nonatomic) NSMutableArray<CMMotionActivity *> *motionHistory;
@property BOOL motionQueryInProgress;
@property BOOL motionTrackingStarted;
@property (strong, nonatomic) NSNumber *motionAuthorizationAtStart;
@property NSUInteger motionGeneration;
@property (strong, nonatomic) NSDictionary *runningConfiguration;
@property NSUInteger settingsChangeDepth;
@property BOOL trackingReconfigurationPending;
@property BOOL httpReconfigurationPending;
@property (strong, nonatomic) NSNumber *lastAuthorization;
@property (strong, nonatomic) GLLocationHealthPolicy *locationHealthPolicy;
@property (strong, nonatomic) GLLocationHealthLog *locationHealthLog;
@property (strong, nonatomic) NSTimer *locationHealthTimer;


@end

@implementation GLManager

static NSString *const GLUploadRetryStateDefaultsName = @"GLUploadRetryState";
static NSString *const GLLocationQueueName = @"GLLocationQueue";
static NSString *const GLNotificationCategoryReminderName = @"REMINDER";
static NSString *const GLNotificationActionResumeTracking = @"RESUME_TRACKING";
static NSString *const GLCustomHTTPHeadersDefaultsName = @"GLCustomHTTPHeadersDefaults";
static NSString *const GLProblemNotificationsOnlyDefaultsName = @"GLProblemNotificationsOnly";
static NSString *const GLAdvancedTrackingDefaultsName = @"GLAdvancedTrackingOptions";
static NSString *const GLRadiusPauseDateDefaultsName = @"GLRadiusPauseDate";
static NSString *const GLAdaptiveRegionName = @"adaptive-stationary";
static NSUInteger const GLWifiKnownNetworkLimit = 64;

static void GLCountLocationRejection(NSMutableDictionary *counts, NSString *reason) {
    counts[reason] = @([counts[reason] unsignedIntegerValue] + 1);
}

static NSNumber *_sendingInterval;

static bool _storeNextLocationAsTripStart = NO;
static long _currentPointsInQueue;
static NSString *_deviceId;


static NSString *GLWifiCoordinateString(id value) {
    if([value isKindOfClass:NSNumber.class]) {
        if(CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return nil;
        return isfinite([value doubleValue]) ? [value stringValue] : nil;
    }
    if(![value isKindOfClass:NSString.class] || [value length] == 0) return nil;
    double number = 0;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    if(![scanner scanDouble:&number] || !scanner.isAtEnd || !isfinite(number)) return nil;
    return value;
}

static BOOL GLValidWifiSSID(id value) {
    if(![value isKindOfClass:NSString.class]) return NO;
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    return data.length >= 1 && data.length <= 32;
}

static NSString *GLWifiSSID(NSDictionary *entry) {
    if(![entry isKindOfClass:NSDictionary.class]) return nil;
    id value = entry[@"name"];
    if(!GLValidWifiSSID(value)) value = entry[@"SSID"];
    return GLValidWifiSSID(value) ? value : nil;
}

static NSDictionary *GLNormalizedWifiPlace(id object) {
    if(![object isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *place = object;
    NSString *identifier = place[@"id"], *name = place[@"name"];
    if(![identifier isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:identifier]) return nil;
    if(![name isKindOfClass:NSString.class]) return nil;
    name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(name.length == 0) return nil;
    NSString *latitude = GLWifiCoordinateString(place[@"latitude"]);
    NSString *longitude = GLWifiCoordinateString(place[@"longitude"]);
    if(!latitude || !longitude || !CLLocationCoordinate2DIsValid(CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue))) return nil;
    if(![place[@"networks"] isKindOfClass:NSArray.class] || [place[@"networks"] count] == 0) return nil;
    NSMutableOrderedSet *networks = [NSMutableOrderedSet orderedSet];
    for(id ssid in place[@"networks"]) {
        if(!GLValidWifiSSID(ssid)) return nil;
        [networks addObject:ssid];
    }
    NSString *symbol = place[@"symbol"] ?: [GLManager autoWifiPlaceSymbolForName:name];
    NSString *color = place[@"color"] ?: @"blue";
    NSString *record = place[@"record"] ?: @"point";
    if(![@[@"house.fill", @"building.2.fill", @"briefcase.fill", @"graduationcap.fill", @"cup.and.saucer.fill",
           @"dumbbell.fill", @"cart.fill", @"fork.knife", @"bed.double.fill", @"heart.fill", @"tree.fill", @"airplane",
           @"car.fill", @"books.vertical.fill", @"cross.case.fill", @"star.fill", @"mappin", @"wifi"] containsObject:symbol]
       || ![@[@"blue", @"green", @"orange", @"red", @"purple", @"pink", @"teal", @"gray"] containsObject:color]
       || ![@[@"point", @"nothing"] containsObject:record]) return nil;
    NSMutableDictionary *result = [@{@"id": identifier, @"name": name,
        @"latitude": @(latitude.doubleValue), @"longitude": @(longitude.doubleValue),
        @"networks": networks.array,
        @"symbol": symbol, @"color": color, @"record": record} mutableCopy];
    if(place[@"symbolChosen"]) {
        id chosen = place[@"symbolChosen"];
        if(![chosen isKindOfClass:NSNumber.class] || ([chosen doubleValue] != 0 && [chosen doubleValue] != 1)) return nil;
        result[@"symbolChosen"] = @([chosen boolValue]);
    }
    return result.copy;
}

static BOOL GLWifiPlaceContainsFix(NSDictionary *place, CLLocation *fix) {
    if(!fix || !CLLocationCoordinate2DIsValid(fix.coordinate) || !isfinite(fix.horizontalAccuracy) || fix.horizontalAccuracy < 0) return NO;
    CLLocation *center = [[CLLocation alloc] initWithLatitude:[place[@"latitude"] doubleValue] longitude:[place[@"longitude"] doubleValue]];
    return [center distanceFromLocation:fix] <= GLWifiPlaceMatchDistance + MIN(fix.horizontalAccuracy, 200);
}

static NSString *GLWifiDay(NSTimeInterval time) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"yyyy-MM-dd";
    });
    @synchronized(formatter) { return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:time]]; }
}

static NSDictionary *GLWifiDays(id raw, NSDate *now) {
    NSMutableDictionary *days = [NSMutableDictionary dictionary];
    if(![raw isKindOfClass:NSDictionary.class]) return days;
    NSTimeInterval today = floor(now.timeIntervalSince1970 / 86400) * 86400;
    for(int i = 0; i < 7; i++) {
        NSString *key = GLWifiDay(today - i * 86400);
        id seconds = raw[key];
        if([seconds isKindOfClass:NSNumber.class] && isfinite([seconds doubleValue]) && [seconds doubleValue] > 0) {
            days[key] = @(MIN(86400, [seconds doubleValue]));
        }
    }
    return days.copy;
}

static NSArray<NSDictionary *> *GLNormalizedWifiCatalog(NSArray *catalog, NSDate *now) {
    NSMutableArray<NSMutableDictionary *> *networks = [NSMutableArray array];
    BOOL legacy = NO;
    for(id object in catalog) if(GLWifiSSID(object) && !object[@"lastSeen"]) { legacy = YES; break; }
    // The old catalog was oldest first and had no timestamps.
    NSArray *ordered = legacy ? catalog.reverseObjectEnumerator.allObjects : catalog;
    for(id object in ordered) {
        NSString *ssid = GLWifiSSID(object);
        if(!ssid) continue;
        NSDictionary *raw = object;
        id seen = raw[@"lastSeen"];
        NSTimeInterval timestamp = [seen isKindOfClass:NSNumber.class] && isfinite([seen doubleValue]) ? MAX(0, [seen doubleValue]) : 0;
        NSMutableDictionary *entry;
        for(NSMutableDictionary *known in networks) if([known[@"name"] isEqual:ssid]) { entry = known; break; }
        if(!entry) {
            entry = [@{@"name": ssid, @"lastSeen": @(timestamp), @"days": @{}} mutableCopy];
            [networks addObject:entry];
        }
        NSDictionary *days = GLWifiDays(raw[@"days"], now);
        NSMutableDictionary *merged = [entry[@"days"] mutableCopy];
        for(NSString *day in days) merged[day] = @(MIN(86400, [merged[day] doubleValue] + [days[day] doubleValue]));
        entry[@"days"] = merged.copy;
        NSString *latitude = GLWifiCoordinateString(raw[@"latitude"]), *longitude = GLWifiCoordinateString(raw[@"longitude"]);
        if(latitude && longitude && CLLocationCoordinate2DIsValid(CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue))
           && (!entry[@"latitude"] || timestamp >= [entry[@"lastSeen"] doubleValue])) {
            entry[@"latitude"] = @(latitude.doubleValue);
            entry[@"longitude"] = @(longitude.doubleValue);
        }
        entry[@"lastSeen"] = @(MAX(timestamp, [entry[@"lastSeen"] doubleValue]));
    }
    [networks sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"lastSeen"] compare:a[@"lastSeen"]];
    }];
    if(networks.count > GLWifiKnownNetworkLimit) [networks removeObjectsInRange:NSMakeRange(GLWifiKnownNetworkLimit, networks.count - GLWifiKnownNetworkLimit)];
    return networks.copy;
}

static dispatch_queue_t GLNotificationQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("me.joshpatra.WhereWolf.notifications", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

- (instancetype)init {
    if((self = [super init])) {
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(liveUpdatesFailed:)
            name:@"WhereWolfLiveUpdatesFailed" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(locationHealthWake)
            name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [self.locationHealthTimer invalidate];
    [self.httpSession invalidateAndCancel];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)liveUpdatesFailed:(NSNotification *)notification {
    if(notification.object != WhereWolfLocationEngine.shared || !self.trackingEnabled
       || !self.hasContinuousUpdates || self.didPauseByRadius) return;
    [self runEngineStandardUpdates];
}

+ (GLManager *)sharedManager {
    static GLManager *_instance = nil;
    
    @synchronized (self) {
        if (_instance == nil) {
            _instance = [[self alloc] init];
            [self initializeUsageProfileDefaults:NSUserDefaults.standardUserDefaults domainName:NSBundle.mainBundle.bundleIdentifier];
            _instance.sendBackgroundTask = UIBackgroundTaskInvalid;
            [NSNotificationCenter.defaultCenter addObserver:_instance selector:@selector(wifiOnlySendingChanged)
                name:GLWifiOnlySending.changedNotification object:nil];
            
            _instance.db = [[LOLDatabase alloc] initWithPath:[self cacheDatabasePath]];
            _instance.db.serializer = ^(id object){
                NSError *error;
                NSData *data = [self dataWithJSONObject:object error:&error];
                if(!data) NSLog(@"Queue serialization failed: %@", error.localizedDescription);
                return data;
            };
            _instance.db.deserializer = ^(NSData *data) {
                return [self objectFromJSONData:data error:NULL];
            };
            
            _instance.tripdb = [FMDatabase databaseWithPath:[self tripDatabasePath]];
            [_instance setUpTripDB];
            
            [_instance setupHTTPClient];
            [_instance restoreTrackingState];
            dispatch_async(GLNotificationQueue(), ^{ [_instance initializeNotifications]; });
            [_instance numberOfLocationsInQueue:^(long num) {}];
            
            _instance.pedometer = [[CMPedometer alloc] init];
        }
    }
    
    return _instance;
}

#pragma mark - GLManager control (public)

+ (BOOL)isValidEndpoint:(NSString *)endpoint {
    if(endpoint.length == 0) return NO;
    NSURLComponents *url = [NSURLComponents componentsWithString:endpoint];
    NSString *scheme = url.scheme.lowercaseString;
    return ([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"]) && url.host.length > 0 && url.URL != nil;
}

- (NSDictionary<NSString *, NSString *> *)customHTTPHeaders {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *headers = [defaults dictionaryForKey:GLCustomHTTPHeadersDefaultsName];
    if(headers) return headers;
    NSMutableDictionary *legacy = [NSMutableDictionary dictionary];
    for(id header in [defaults arrayForKey:@"GLCustomHeadersDefaults"]) {
        if([header isKindOfClass:[NSDictionary class]] && [header[@"key"] isKindOfClass:[NSString class]] && [header[@"value"] isKindOfClass:[NSString class]]) {
            legacy[header[@"key"]] = header[@"value"];
        }
    }
    if(legacy.count == 0) return @{};
    self.customHTTPHeaders = legacy;
    return [defaults dictionaryForKey:GLCustomHTTPHeadersDefaultsName] ?: @{};
}

- (void)setCustomHTTPHeaders:(NSDictionary<NSString *, NSString *> *)headers {
    NSCharacterSet *invalidName = [[NSCharacterSet characterSetWithCharactersInString:@"!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"] invertedSet];
    NSMutableDictionary *valid = [NSMutableDictionary dictionary];
    NSMutableSet *names = [NSMutableSet set];
    for(NSString *name in headers) {
        NSString *value = headers[name];
        if(![name isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]) continue;
        NSString *lower = name.lowercaseString;
        if(name.length == 0 || [name rangeOfCharacterFromSet:invalidName].location != NSNotFound) continue;
        if([value rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) continue;
        if([@[@"host", @"content-length", @"connection", @"transfer-encoding", @"authorization"] containsObject:lower] || [names containsObject:lower]) continue;
        [names addObject:lower];
        valid[[lower isEqualToString:@"authorization"] ? @"Authorization" : name] = value;
    }
    [[NSUserDefaults standardUserDefaults] setObject:valid forKey:GLCustomHTTPHeadersDefaultsName];
    [self resetUploadRetry];
    if(self.uploadPending) [self scheduleUploadAfter:0];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
}

- (BOOL)saveNewAPIEndpoint:(NSString *)endpoint andAccessToken:(NSString *)accessToken {
    if(endpoint.length > 0 && ![GLManager isValidEndpoint:endpoint]) return NO;
    if(![GLServerCredentials saveEndpoint:endpoint ?: @"" token:accessToken ?: @""]) return NO;
    [self reloadServerCredentials];
    return YES;
}

- (void)reloadServerCredentials {
    [self resetUploadRetry];
    [self setupHTTPClient];
}

- (NSString *)apiEndpointURL {
    return [GLServerCredentials endpoint];
}

- (NSString *)apiAccessToken {
    return [GLServerCredentials token];
}

- (void)performSettingsBatch:(void (^)(void))changes {
    self.settingsChangeDepth++;
    @try { changes(); }
    @finally {
        self.settingsChangeDepth--;
        if(self.settingsChangeDepth == 0) {
            if(self.httpReconfigurationPending) {
                self.httpReconfigurationPending = NO;
                [self setupHTTPClient];
            }
            if(self.trackingReconfigurationPending) {
                self.trackingReconfigurationPending = NO;
                [self requestTrackingReconfiguration];
            }
            [self scheduleLocalNotification];
            [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
        }
    }
}

+ (NSArray<NSDictionary *> *)validatedWifiPlaces:(NSArray *)places {
    if(![places isKindOfClass:NSArray.class] || places.count > 256) return nil;
    NSMutableArray *safe = [NSMutableArray array];
    NSMutableSet *identifiers = [NSMutableSet set];
    for(id place in places) {
        NSDictionary *valid = GLNormalizedWifiPlace(place);
        NSString *identifier = [valid[@"id"] lowercaseString];
        if(!valid || [identifiers containsObject:identifier]) return nil;
        [identifiers addObject:identifier];
        [safe addObject:valid];
    }
    return safe.copy;
}

+ (NSString *)autoWifiPlaceSymbolForName:(NSString *)name {
    NSString *folded = [[name stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"]] lowercaseString];
    NSArray *rules = @[
        @[@[@"home", @"house"], @"house.fill"], @[@[@"work", @"office"], @"building.2.fill"],
        @[@[@"school", @"campus", @"university", @"college"], @"graduationcap.fill"],
        @[@[@"gym", @"fitness"], @"dumbbell.fill"], @[@[@"cafe", @"coffee"], @"cup.and.saucer.fill"],
        @[@[@"shop", @"store", @"market"], @"cart.fill"], @[@[@"restaurant"], @"fork.knife"],
        @[@[@"hotel"], @"bed.double.fill"], @[@[@"mom", @"dad", @"family", @"parents"], @"heart.fill"],
        @[@[@"park"], @"tree.fill"], @[@[@"airport"], @"airplane"], @[@[@"library"], @"books.vertical.fill"],
        @[@[@"hospital", @"clinic"], @"cross.case.fill"]];
    NSRegularExpression *words = [NSRegularExpression regularExpressionWithPattern:@"[\\p{L}\\p{N}_]+" options:0 error:NULL];
    NSMutableSet *tokens = [NSMutableSet set];
    for(NSTextCheckingResult *match in [words matchesInString:folded options:0 range:NSMakeRange(0, folded.length)]) {
        [tokens addObject:[folded substringWithRange:match.range]];
    }
    for(NSArray *rule in rules) for(NSString *word in rule[0]) if([tokens containsObject:word]) return rule[1];
    return @"mappin";
}

+ (NSArray<NSDictionary *> *)placesFromLegacyWifiZones:(NSArray *)zones {
    if(![zones isKindOfClass:NSArray.class] || zones.count > 10000) return nil;
    NSMutableArray<NSMutableDictionary *> *places = [NSMutableArray array];
    for(id zone in zones) {
        NSString *ssid = GLWifiSSID(zone);
        if(!ssid) return nil;
        NSString *latitude = GLWifiCoordinateString(zone[@"latitude"]), *longitude = GLWifiCoordinateString(zone[@"longitude"]);
        if(!latitude || !longitude || !CLLocationCoordinate2DIsValid(CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue))) return nil;
        NSMutableDictionary *group;
        for(NSMutableDictionary *place in places) {
            if([place[@"latitude"] doubleValue] == latitude.doubleValue && [place[@"longitude"] doubleValue] == longitude.doubleValue) { group = place; break; }
        }
        if(!group) {
            group = [@{@"id": NSUUID.UUID.UUIDString, @"name": ssid, @"latitude": @(latitude.doubleValue),
                @"longitude": @(longitude.doubleValue), @"networks": @[],
                @"symbol": [self autoWifiPlaceSymbolForName:ssid], @"color": @"blue", @"record": @"point"} mutableCopy];
            [places addObject:group];
        }
        if(![group[@"networks"] containsObject:ssid]) group[@"networks"] = [group[@"networks"] arrayByAddingObject:ssid];
    }
    return [self validatedWifiPlaces:places];
}

- (BOOL)replaceWifiPlaces:(NSArray<NSDictionary *> *)places {
    NSArray *valid = [GLManager validatedWifiPlaces:places];
    if(!valid) return NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    @try {
        if(![valid isEqual:[defaults objectForKey:GLWifiPlacesDefaultsName]]) [defaults setObject:valid forKey:GLWifiPlacesDefaultsName];
        if(![valid isEqual:[defaults objectForKey:GLWifiPlacesDefaultsName]]) return NO;
    } @catch(NSException *exception) { return NO; }
    for(NSString *key in @[GLWifiZonesDefaultsName, @"WifiZoneName", @"WifiZoneLatitude", @"WifiZoneLongitude"]) {
        if([defaults objectForKey:key]) [defaults removeObjectForKey:key];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
    return YES;
}

- (void)saveNewDeviceId:(NSString *)deviceId {
    _deviceId = deviceId;
    [[NSUserDefaults standardUserDefaults] setObject:deviceId forKey:GLDeviceIdDefaultsName];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
}

- (NSString *)deviceId {
    NSString *d = [[NSUserDefaults standardUserDefaults] stringForKey:GLDeviceIdDefaultsName];
    if(d == nil) {
        d = @"";
    }
    return d;
}

#pragma mark - Optional tracking policies

static NSDictionary<NSString *, NSNumber *> *GLAdvancedDefaults(void) {
    return @{@"any_threshold": @NO, @"turn_degrees": @0, @"reject_jumps": @NO, @"maximum_speed": @100,
        @"motion_assist": @NO, @"motion_resume_radius": @NO, @"motion_confidence": @2,
        @"adaptive": @NO, @"adaptive_in_trips": @NO, @"adaptive_require_motion": @YES,
        @"adaptive_dwell": @120, @"adaptive_radius": @30, @"adaptive_max_error": @25,
        @"adaptive_idle_accuracy": @100, @"adaptive_resume_radius": @100,
        @"background_uploads": @NO, @"connectivity_retry": @NO, @"explicit_service_session": @NO,
        @"background_recovery": @NO, @"automatic_location_retry": @NO,
        @"location_health_log": @NO, @"location_retry_after": @120};
}

+ (NSDictionary *)normalizedTrackingOptions:(NSDictionary *)options {
    NSDictionary *ranges = @{@"turn_degrees": @[@0, @180], @"maximum_speed": @[@5, @500],
        @"motion_confidence": @[@1, @2], @"adaptive_dwell": @[@30, @3600],
        @"adaptive_radius": @[@10, @500], @"adaptive_max_error": @[@5, @200],
        @"adaptive_idle_accuracy": @[@50, @3000], @"adaptive_resume_radius": @[@25, @1000],
        @"location_retry_after": @[@60, @1800]};
    NSMutableDictionary *result = [GLAdvancedDefaults() mutableCopy];
    if(![options isKindOfClass:NSDictionary.class]) return result;
    for(NSString *key in result.allKeys) {
        NSNumber *value = options[key];
        if(![value isKindOfClass:NSNumber.class] || !isfinite(value.doubleValue)) continue;
        NSArray *range = ranges[key];
        result[key] = range ? @(MIN([range[1] doubleValue], MAX([range[0] doubleValue], value.doubleValue))) : @(value.boolValue);
        if([key isEqual:@"motion_confidence"]) result[key] = @((NSInteger)round([result[key] doubleValue]));
    }
    return result;
}

- (NSDictionary<NSString *, NSNumber *> *)advancedTrackingOptions {
    return [GLManager normalizedTrackingOptions:[NSUserDefaults.standardUserDefaults dictionaryForKey:GLAdvancedTrackingDefaultsName]];
}

- (void)setAdvancedTrackingOption:(NSNumber *)value forKey:(NSString *)key {
    if(!GLAdvancedDefaults()[key] || ![value isKindOfClass:NSNumber.class]) return;
    NSMutableDictionary *options = [self.advancedTrackingOptions mutableCopy];
    options[key] = value;
    self.advancedTrackingOptions = options;
}

- (void)setAdvancedTrackingOptions:(NSDictionary<NSString *, NSNumber *> *)options {
    NSDictionary *previous = self.advancedTrackingOptions;
    NSDictionary *next = [GLManager normalizedTrackingOptions:options];
    if([previous isEqual:next]) return;
    [NSUserDefaults.standardUserDefaults setObject:next forKey:GLAdvancedTrackingDefaultsName];
    if(![previous[@"location_health_log"] boolValue] && [next[@"location_health_log"] boolValue]) {
        [self recordLocationHealthEvent:@{@"kind": @"logging_started"}];
    }
    if(![previous[@"automatic_location_retry"] isEqual:next[@"automatic_location_retry"]]
       || ![previous[@"location_retry_after"] isEqual:next[@"location_retry_after"]]) {
        self.locationHealthPolicy.retryAfter = [next[@"location_retry_after"] doubleValue];
        [self.locationHealthPolicy resetAtUptime:[self locationHealthUptime]];
    }
    NSArray *adaptiveKeys = @[@"adaptive", @"adaptive_in_trips", @"adaptive_require_motion", @"adaptive_dwell",
        @"adaptive_radius", @"adaptive_max_error", @"adaptive_idle_accuracy", @"adaptive_resume_radius", @"motion_confidence"];
    for(NSString *key in adaptiveKeys) {
        if(![previous[key] isEqual:next[key]]) {
            [self.adaptivePolicy reset];
            [self removeAdaptiveRegion];
            break;
        }
    }
    if(![previous[@"reject_jumps"] isEqual:next[@"reject_jumps"]]
       || ![previous[@"maximum_speed"] isEqual:next[@"maximum_speed"]]) {
        [self.qualityPolicy reset];
        self.qualityObservation = nil;
    }
    [self requestTrackingReconfiguration];
    [self reconcileLocationHealth];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
}

- (GLAdaptivePolicy *)adaptivePolicy {
    if(!_adaptivePolicy) _adaptivePolicy = [[GLAdaptivePolicy alloc] init];
    return _adaptivePolicy;
}

- (GLPointQualityPolicy *)qualityPolicy {
    if(!_qualityPolicy) _qualityPolicy = [[GLPointQualityPolicy alloc] init];
    return _qualityPolicy;
}

- (BOOL)adaptiveEnabled {
    NSDictionary *options = self.advancedTrackingOptions;
    return [options[@"adaptive"] boolValue] && self.hasContinuousUpdates
        && (!self.tripInProgress || [options[@"adaptive_in_trips"] boolValue]);
}

- (NSString *)adaptiveTrackingStatus {
    if(![self.advancedTrackingOptions[@"adaptive"] boolValue]) return @"Off";
    if(!self.hasContinuousUpdates) return @"Requires continuous updates";
    if(self.tripInProgress && ![self.advancedTrackingOptions[@"adaptive_in_trips"] boolValue]) return @"Trip uses its own settings";
    if(self.didPauseByRadius) return @"Paused by stationary radius";
    if(self.adaptivePolicy.stationary) return @"Stationary · lower accuracy";
    if([self.advancedTrackingOptions[@"adaptive_require_motion"] boolValue]
       && CMMotionActivityManager.authorizationStatus != CMAuthorizationStatusAuthorized) return @"Detailed · motion confirmation unavailable";
    return @"Detailed · waiting for a confirmed stop";
}

- (void)removeAdaptiveRegion {
    for(CLRegion *region in self.locationManager.monitoredRegions) {
        if([region.identifier isEqual:GLAdaptiveRegionName]) [self.locationManager stopMonitoringForRegion:region];
    }
}

- (void)updateAdaptiveRegion {
    [self removeAdaptiveRegion];
    if(!self.trackingEnabled || !self.adaptiveEnabled || !self.adaptivePolicy.stationary
       || self.locationManager.authorizationStatus != kCLAuthorizationStatusAuthorizedAlways
       || ![CLLocationManager isMonitoringAvailableForClass:CLCircularRegion.class] || !self.adaptivePolicy.anchor) return;
    CLLocationDistance radius = [self.advancedTrackingOptions[@"adaptive_resume_radius"] doubleValue];
    radius = MIN(radius, MAX(25, self.locationManager.maximumRegionMonitoringDistance));
    CLCircularRegion *region = [[CLCircularRegion alloc] initWithCenter:self.adaptivePolicy.anchor.coordinate
        radius:radius identifier:GLAdaptiveRegionName];
    region.notifyOnEntry = NO;
    region.notifyOnExit = YES;
    [self.locationManager startMonitoringForRegion:region];
}

- (void)requestTrackingReconfiguration {
    if(self.settingsChangeDepth > 0) {
        self.trackingReconfigurationPending = YES;
        return;
    }
    if(self.trackingEnabled) [self applyTrackingConfiguration];
}

- (void)reconcileTracking {
    if(self.trackingEnabled) {
        [self requestTrackingReconfiguration];
        [self queryMotionHistoryRequestingPermission:NO];
        [self resumePendingUpload];
    }
}

#pragma mark - Motion and Fitness

- (NSString *)motionAuthorizationStatus {
    if(!CMMotionActivityManager.isActivityAvailable) return @"Unavailable";
    switch(CMMotionActivityManager.authorizationStatus) {
        case CMAuthorizationStatusAuthorized: return @"Allowed";
        case CMAuthorizationStatusDenied: return @"Denied";
        case CMAuthorizationStatusRestricted: return @"Restricted";
        default: return @"Not Requested";
    }
}

- (CLLocation *)lastDeviceLocation { return self.lastReceivedLocation; }

- (NSString *)motionSummary {
    if(![self.motionAuthorizationStatus isEqual:@"Allowed"]) return self.motionAuthorizationStatus;
    NSArray *motion = [self motionArrayForDate:NSDate.date];
    return motion.count > 0 ? [[motion componentsJoinedByString:@", "] capitalizedString] : @"Unknown";
}

- (CMMotionActivity *)motionAtDate:(NSDate *)date {
    if(![self.motionAuthorizationStatus isEqual:@"Allowed"]) return nil;
    CMMotionActivity *best;
    for(CMMotionActivity *activity in self.motionHistory) {
        if([activity.startDate compare:date] != NSOrderedDescending) best = activity;
        else break;
    }
    if(!best && self.lastMotion && [self.lastMotion.startDate compare:date] != NSOrderedDescending) best = self.lastMotion;
    return best;
}

- (GLMovementState)movementAtDate:(NSDate *)date {
    CMMotionActivity *activity = [self motionAtDate:date];
    if(!activity || activity.confidence < [self.advancedTrackingOptions[@"motion_confidence"] integerValue]) return GLMovementUnknown;
    if(activity.stationary) return GLMovementStationary;
    if(activity.walking || activity.running || activity.cycling || activity.automotive) return GLMovementMoving;
    return GLMovementUnknown;
}

- (BOOL)deviceIsStationaryAtDate:(NSDate *)date {
    CMMotionActivity *motion = [self motionAtDate:date];
    return motion.stationary && !motion.walking && !motion.running && !motion.cycling && !motion.automotive;
}

- (BOOL)deviceIsMovingAtDate:(NSDate *)date {
    CMMotionActivity *motion = [self motionAtDate:date];
    return motion.confidence >= CMMotionActivityConfidenceMedium &&
        (motion.walking || motion.running || motion.cycling || motion.automotive);
}

- (void)rememberMotion:(CMMotionActivity *)activity {
    if(!activity || !activity.startDate || activity.startDate.timeIntervalSinceNow > 0) return;
    if(!self.motionHistory) self.motionHistory = [NSMutableArray array];
    NSIndexSet *same = [self.motionHistory indexesOfObjectsPassingTest:^BOOL(CMMotionActivity *old, NSUInteger index, BOOL *stop) {
        return [old.startDate isEqual:activity.startDate];
    }];
    [self.motionHistory removeObjectsAtIndexes:same];
    [self.motionHistory addObject:activity];
    [self.motionHistory sortUsingComparator:^NSComparisonResult(CMMotionActivity *a, CMMotionActivity *b) {
        return [a.startDate compare:b.startDate];
    }];
    while(self.motionHistory.count > 512) [self.motionHistory removeObjectAtIndex:0];
}

- (void)processMotionActivity:(CMMotionActivity *)activity {
    if(!self.trackingEnabled || !activity.startDate || activity.startDate.timeIntervalSinceNow > 0) return;
    self.lastMotion = activity;
    [self rememberMotion:activity];
    NSDictionary *options = self.advancedTrackingOptions;
    if([self movementAtDate:activity.startDate] == GLMovementMoving) {
        BOOL adaptiveChanged = [self.adaptivePolicy movementDetected];
        if(adaptiveChanged) [self removeAdaptiveRegion];
        BOOL afterPause = !self.radiusPauseDate || [activity.startDate compare:self.radiusPauseDate] == NSOrderedDescending;
        BOOL resumeRadius = self.didPauseByRadius && afterPause && [options[@"motion_assist"] boolValue]
            && [options[@"motion_resume_radius"] boolValue];
        if(resumeRadius) [self resetStationaryAnchors];
        if(adaptiveChanged || resumeRadius || ([options[@"motion_assist"] boolValue]
           && self.engineStationary && !self.didPauseByRadius)) {
            self.runningConfiguration = nil;
            [self requestTrackingReconfiguration];
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:GLNewActivityNotification object:self];
}

- (void)queryMotionHistoryRequestingPermission:(BOOL)request {
    if(self.motionQueryInProgress || !CMMotionActivityManager.isActivityAvailable) return;
    CMAuthorizationStatus status = CMMotionActivityManager.authorizationStatus;
    if(!request && status != CMAuthorizationStatusAuthorized) return;
    if(status == CMAuthorizationStatusDenied || status == CMAuthorizationStatusRestricted) return;
    self.motionQueryInProgress = YES;
    NSUInteger generation = self.motionGeneration;
    NSDate *end = NSDate.date;
    __weak typeof(self) weakSelf = self;
    [self.motionActivityManager queryActivityStartingFromDate:[end dateByAddingTimeInterval:-24 * 3600] toDate:end
        toQueue:NSOperationQueue.mainQueue withHandler:^(NSArray<CMMotionActivity *> *activities, NSError *error) {
        typeof(self) self = weakSelf;
        if(!self) return;
        if(generation == self.motionGeneration) {
            self.motionQueryInProgress = NO;
            if(self.trackingEnabled) {
                NSUInteger start = activities.count > 512 ? activities.count - 512 : 0;
                for(NSUInteger i = start; i < activities.count; i++) [self rememberMotion:activities[i]];
                if(activities.lastObject) self.lastMotion = activities.lastObject;
                [self updateMotionTracking];
            }
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:GLNewActivityNotification object:self];
    }];
}

- (void)requestMotionPermission { [self queryMotionHistoryRequestingPermission:YES]; }

- (void)updateMotionTracking {
    if(!self.trackingEnabled || !CMMotionActivityManager.isActivityAvailable) return;
    NSNumber *authorization = @(CMMotionActivityManager.authorizationStatus);
    if(self.motionTrackingStarted && [self.motionAuthorizationAtStart isEqual:authorization]) return;
    [self.motionActivityManager stopActivityUpdates];
    self.motionAuthorizationAtStart = authorization;
    self.motionTrackingStarted = NO;
    if(authorization.integerValue != CMAuthorizationStatusAuthorized) {
        self.lastMotion = nil;
        return;
    }
    self.motionTrackingStarted = YES;
    NSUInteger generation = self.motionGeneration;
    __weak typeof(self) weakSelf = self;
    [self.motionActivityManager startActivityUpdatesToQueue:NSOperationQueue.mainQueue withHandler:^(CMMotionActivity *activity) {
        typeof(self) self = weakSelf;
        if(!self || !self.trackingEnabled || self.motionGeneration != generation) return;
        [self processMotionActivity:activity];
    }];
    [self queryMotionHistoryRequestingPermission:NO];
}

- (NSArray *)motionArrayForDate:(NSDate *)date {
    CMMotionActivity *activity = [self motionAtDate:date];
    NSMutableArray *motion = [NSMutableArray array];
    if(activity.walking) [motion addObject:@"walking"];
    if(activity.running) [motion addObject:@"running"];
    if(activity.cycling) [motion addObject:@"cycling"];
    if(activity.automotive) [motion addObject:@"driving"];
    if(activity.stationary) [motion addObject:@"stationary"];
    return motion;
}

#pragma mark - Usage profiles

static NSDictionary *GLUsageProfileSettings(NSInteger profile) {
    if(profile < 1 || profile > 6) return nil;
    BOOL lowPower = profile == 2;
    BOOL balanced = profile == 3;
    BOOL everyday = profile == 6;
    CLLocationAccuracy accuracy = lowPower || balanced ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyBest;
    CLActivityType activity = CLActivityTypeOther;
    if(profile == 4) activity = CLActivityTypeFitness;
    if(profile == 5) {
        activity = CLActivityTypeAutomotiveNavigation;
        accuracy = kCLLocationAccuracyBestForNavigation;
    }
    return @{
        GLSignificantLocationModeDefaultsName: @(lowPower ? kGLTrackingModeSignificant : balanced ? kGLTrackingModeStandardAndSignificant : kGLTrackingModeStandard),
        GLDesiredAccuracyDefaultsName: @(accuracy),
        GLActivityTypeDefaultsName: @(activity),
        GLPausesAutomaticallyDefaultsName: @(lowPower),
        GLResumesAutomaticallyDefaultsName: @(lowPower ? 500 : -1),
        GLStopsAutomaticallyDefaultsName: @(balanced ? 50 : -1),
        GLStopsAutomaticallyAfterDefaultsName: @180,
        GLDiscardPointsWithinDistanceDefaultsName: @(everyday ? 10 : -1),
        GLDiscardPointsWithinSecondsDefaultsName: @(everyday ? 5 : 0),
        GLDiscardPointsOutsideAccuracyDefaultsName: @-1,
        GLBackgroundIndicatorDefaultsName: @(!lowPower && !everyday),
        GLVisitTrackingEnabledDefaultsName: @NO
    };
}

+ (void)initializeUsageProfileDefaults:(NSUserDefaults *)defaults domainName:(NSString *)domainName {
    // Sparse saved preferences still belong to an existing installation; preserve its getter fallbacks.
    if(domainName.length == 0 || [defaults persistentDomainForName:domainName].count != 0) return;
    [defaults setPersistentDomain:GLUsageProfileSettings(6) forName:domainName];
}

- (NSInteger)usageProfile {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for(NSInteger profile = 1; profile <= 6; profile++) {
        NSDictionary *settings = GLUsageProfileSettings(profile);
        BOOL matches = YES;
        for(NSString *key in settings) {
            if(![[defaults objectForKey:key] isEqual:settings[key]]) {
                matches = NO;
                break;
            }
        }
        if(matches) return profile;
    }
    return 0;
}

- (void)applyUsageProfile:(NSInteger)profile {
    NSDictionary *settings = GLUsageProfileSettings(profile);
    if(!settings || self.tripInProgress) return;
    [self resetStationaryAnchors];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for(NSString *key in settings) {
        [defaults setObject:settings[key] forKey:key];
    }
    [defaults removeObjectForKey:GLLastTimeMovedBeyondStopThresholdDefaultsName];
    for(CLRegion *region in self.locationManager.monitoredRegions) {
        if([region.identifier isEqualToString:@"resume-from-pause"]) {
            [self.locationManager stopMonitoringForRegion:region];
        }
    }
    if(self.trackingEnabled) [self enableTracking];
}

#pragma mark - Tracking

- (void)startAllUpdates {
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:GLTrackingStateDefaultsName];
    if(self.locationManager.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
        [self requestAuthorizationPermission];
    }
    [self enableTracking];
}

- (void)stopAllUpdates {
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLTrackingStateDefaultsName];
    [self disableTracking];
}

- (void)refreshLocation {
    NSLog(@"Trying to update location now");
    if(!self.trackingEnabled) {
        return;
    }
    [self.locationHealthPolicy resetAtUptime:[self locationHealthUptime]];
    [self recordLocationHealthEvent:@{@"kind": @"manual_retry"}];
    [WhereWolfLocationEngine.shared resetLiveUpdatesFailure];
    self.runningConfiguration = nil;
    [[WhereWolfLocationEngine shared] stopLiveUpdates];
    [self performSelector:@selector(runEngineStandardUpdates) withObject:nil afterDelay:1.0];
}

- (BOOL)useNewLocationEngine {
    return [NSUserDefaults.standardUserDefaults boolForKey:GLUseNewLocationEngineDefaultsName];
}

- (void)setUseNewLocationEngine:(BOOL)enabled {
    if(enabled == self.useNewLocationEngine) return;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:GLUseNewLocationEngineDefaultsName];
    [WhereWolfLocationEngine.shared resetLiveUpdatesFailure];
    if(self.trackingEnabled && !self.didPauseByRadius) [self requestTrackingReconfiguration];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
}

- (BOOL)hasContinuousUpdates {
    return self.tripInProgress || self.trackingMode == kGLTrackingModeStandard || self.trackingMode == kGLTrackingModeStandardAndSignificant;
}

- (BOOL)shouldUseLiveUpdates {
    if(self.adaptiveEnabled && self.adaptivePolicy.stationary) return NO;
    CLLocationAccuracy accuracy = self.tripInProgress ? self.desiredAccuracyDuringTrip : self.desiredAccuracy;
    BOOL pauses = self.tripInProgress ? self.pausesAutomaticallyDuringTrip : self.pausesAutomatically;
    return self.hasContinuousUpdates && (self.useNewLocationEngine || (accuracy == kCLLocationAccuracyBest && pauses));
}

- (BOOL)prepareLiveUpdates {
    if(!self.shouldUseLiveUpdates) {
        [WhereWolfLocationEngine.shared endBackgroundSession];
        return NO;
    }
    BOOL indicator = self.tripInProgress ? self.showBackgroundLocationIndicatorDuringTrip : self.showBackgroundLocationIndicator;
    return [WhereWolfLocationEngine.shared prepareLiveUpdatesWithBackgroundIndicator:indicator];
}

- (void)updateLocationEngine {
    if(self.settingsChangeDepth > 0) { self.trackingReconfigurationPending = YES; return; }
    if(!self.trackingEnabled || !self.hasContinuousUpdates || self.didPauseByRadius) {
        [WhereWolfLocationEngine.shared endBackgroundSession];
        return;
    }
    BOOL live = [self prepareLiveUpdates];
    if(live != WhereWolfLocationEngine.shared.usingLiveUpdates) [self runEngineStandardUpdates];
}

- (void)runEngineStandardUpdates {
    if(self.settingsChangeDepth > 0) { self.trackingReconfigurationPending = YES; return; }
    if(!self.trackingEnabled || self.didPauseByRadius || !self.hasContinuousUpdates) return;
    CLAuthorizationStatus authorization = self.locationManager.authorizationStatus;
    if(authorization != kCLAuthorizationStatusAuthorizedAlways && authorization != kCLAuthorizationStatusAuthorizedWhenInUse) return;

    CLActivityType activity = self.tripInProgress ? self.activityTypeDuringTrip : self.activityType;
    CLLocationAccuracy accuracy = self.tripInProgress ? self.desiredAccuracyDuringTrip : self.desiredAccuracy;
    BOOL pauses = self.tripInProgress ? self.pausesAutomaticallyDuringTrip : self.pausesAutomatically;
    if(self.adaptiveEnabled && self.adaptivePolicy.stationary) {
        accuracy = [self.advancedTrackingOptions[@"adaptive_idle_accuracy"] doubleValue];
        pauses = NO;
    }
    BOOL indicator = self.tripInProgress ? self.showBackgroundLocationIndicatorDuringTrip : self.showBackgroundLocationIndicator;
    BOOL live = [self prepareLiveUpdates];
    NSDictionary *configuration = @{@"live": @(live), @"activity": @(activity), @"accuracy": @(accuracy),
        @"pauses": @(pauses), @"indicator": @(indicator)};
    if([self.runningConfiguration isEqual:configuration]) return;
    self.runningConfiguration = configuration;
    self.engineStationary = NO;
    self.locationManager.showsBackgroundLocationIndicator = indicator;
    self.locationManager.activityType = activity;
    self.locationManager.desiredAccuracy = accuracy;
    self.locationManager.pausesLocationUpdatesAutomatically = pauses;

    // liveUpdates has no custom accuracy or pause-policy parameter.
    if(!live) {
        [[WhereWolfLocationEngine shared] stopLiveUpdates];
        [self.locationManager startUpdatingLocation];
    } else {
        [self.locationManager stopUpdatingLocation];
        [[WhereWolfLocationEngine shared] runLiveUpdatesWithActivityType:activity];
    }
    [self reconcileLocationHealth];
}

- (void)processEngineStationary:(BOOL)stationary {
    if(!self.trackingEnabled || stationary == self.engineStationary) return;
    self.engineStationary = stationary;
    if(stationary) {
        [self locationManagerDidPauseLocationUpdates:self.locationManager];
    } else {
        [self locationManagerDidResumeLocationUpdates:self.locationManager];
    }
}

- (void)processEngineLocation:(CLLocation *)location {
    if(self.trackingEnabled) {
        [self processLocations:@[location]];
    }
}

#pragma mark - Location update health

- (NSTimeInterval)locationHealthUptime { return NSProcessInfo.processInfo.systemUptime; }

- (NSString *)locationHealthPauseReason {
    if(!self.trackingEnabled) return @"tracking_off";
    if(!self.hasContinuousUpdates) return @"event_mode";
    // Status reads must not create a manager whose authorization callback starts acquisition.
    CLAuthorizationStatus authorization = _locationManager ? _locationManager.authorizationStatus : kCLAuthorizationStatusNotDetermined;
    if(authorization != kCLAuthorizationStatusAuthorizedAlways && authorization != kCLAuthorizationStatusAuthorizedWhenInUse) return @"permission";
    if(self.didPauseByRadius) return @"radius_pause";
    if(self.adaptiveEnabled && self.adaptivePolicy.stationary) return @"adaptive_pause";
    if(self.engineStationary) return @"automatic_pause";
    return nil;
}

- (BOOL)locationHealthEnabled {
    NSDictionary *options = self.advancedTrackingOptions;
    return [options[@"automatic_location_retry"] boolValue] || [options[@"location_health_log"] boolValue];
}

- (GLLocationHealthLog *)locationHealthLog {
    if(!_locationHealthLog) {
        NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        _locationHealthLog = [[GLLocationHealthLog alloc] initWithDirectory:[support URLByAppendingPathComponent:@"LocationHealth" isDirectory:YES]];
    }
    return _locationHealthLog;
}

- (void)recordLocationHealthEvent:(NSDictionary *)event {
    if(![self.advancedTrackingOptions[@"location_health_log"] boolValue]) return;
    NSMutableDictionary *entry = [event mutableCopy];
    if(!entry[@"time"]) entry[@"time"] = @(NSDate.date.timeIntervalSince1970);
    entry[@"engine"] = WhereWolfLocationEngine.shared.usingLiveUpdates ? @"new" : @"original";
    [self.locationHealthLog append:entry];
    [NSNotificationCenter.defaultCenter postNotificationName:@"WhereWolfLocationHealthChanged" object:self];
}

- (void)drainLocationHealthEvents {
    for(NSDictionary *event in [self.locationHealthPolicy takeEvents]) [self recordLocationHealthEvent:event];
}

- (void)reconcileLocationHealth {
    [TrackingTransitionLog recordTracking:self.trackingEnabled paused:[self locationHealthPauseReason] != nil || self.inStationaryStop];
    BOOL enabled = self.locationHealthEnabled;
    BOOL expected = enabled && ![self locationHealthPauseReason];
    if(enabled && !self.locationHealthPolicy) self.locationHealthPolicy = [GLLocationHealthPolicy new];
    self.locationHealthPolicy.retryAfter = [self.advancedTrackingOptions[@"location_retry_after"] doubleValue];
    BOOL wasExpected = self.locationHealthPolicy.expected;
    [self.locationHealthPolicy setExpected:expected uptime:[self locationHealthUptime]];
    if(expected != wasExpected) {
        NSMutableDictionary *event = [@{@"kind": expected ? @"monitor_resumed" : @"monitor_paused"} mutableCopy];
        NSString *reason = [self locationHealthPauseReason];
        if(reason) event[@"reason"] = reason;
        [self recordLocationHealthEvent:event];
    }
    if(!expected) {
        [self.locationHealthTimer invalidate];
        self.locationHealthTimer = nil;
        return;
    }
    if(self.locationHealthTimer) return;
    __weak typeof(self) weakSelf = self;
    self.locationHealthTimer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) {
        [weakSelf evaluateLocationHealth];
    }];
    self.locationHealthTimer.tolerance = 5;
}

- (void)evaluateLocationHealth {
    [self reconcileLocationHealth];
    if(!self.locationHealthPolicy.expected) return;
    BOOL retry = [self.locationHealthPolicy evaluateAtUptime:[self locationHealthUptime] date:NSDate.date
        automaticRetry:[self.advancedTrackingOptions[@"automatic_location_retry"] boolValue]];
    [self drainLocationHealthEvents];
    if(!retry || [self locationHealthPauseReason]) return;
    // Preserve the failed-stream latch: automatic recovery must not re-enter its retry loop.
    [WhereWolfLocationEngine.shared stopLiveUpdates];
    [self.locationManager stopUpdatingLocation];
    self.runningConfiguration = nil;
    [self runEngineStandardUpdates];
}

- (void)locationHealthWake {
    if(self.locationHealthEnabled) [self evaluateLocationHealth];
}

- (NSDictionary<NSString *, id> *)locationUpdateHealth {
    if(!self.locationHealthEnabled) return @{@"state": @"off", @"attempts": @0, @"limit": @3};
    NSMutableDictionary *snapshot = [[self.locationHealthPolicy snapshotAtUptime:[self locationHealthUptime]] mutableCopy]
        ?: [@{@"state": @"waiting", @"attempts": @0, @"limit": @3} mutableCopy];
    NSString *reason = [self locationHealthPauseReason];
    if(reason) { snapshot[@"state"] = @"paused"; snapshot[@"reason"] = reason; }
    return snapshot;
}

- (void)loadLocationHealthLog:(void (^)(NSArray<NSDictionary *> *))completion {
    [self.locationHealthLog load:completion];
}

- (void)clearLocationHealthLog:(void (^)(void))completion {
    [self.locationHealthLog clear:completion];
}

- (void)noteLocationLaunch:(BOOL)locationEvent {
    [self recordLocationHealthEvent:@{@"kind": @"app_launched", @"reason": locationEvent ? @"location_event" : @"other_launch"}];
}

- (GLLocationSaveAllowance *)newLocationSaveAllowance {
    __weak typeof(self) weakSelf = self;
    return [[GLLocationSaveAllowance alloc] initWithBegin:^UIBackgroundTaskIdentifier(void (^expiration)(void)) {
        return [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Save Received Locations" expirationHandler:^{
            expiration();
            [weakSelf recordLocationHealthEvent:@{@"kind": @"save_time_expired"}];
        }];
    } end:^(UIBackgroundTaskIdentifier identifier) {
        [UIApplication.sharedApplication endBackgroundTask:identifier];
    }];
}

- (void)enqueueWorkoutImportRecords:(NSArray<NSDictionary *> *)records
                        completion:(void (^)(NSUInteger, NSString *))completion {
    if(self.loggingModeCurrentValue != kGLLoggingModeAllData && !self.savesToICloudDrive) {
        completion(0, @"Choose All Data logging before sending workout routes. Imported routes remain saved on this phone.");
        return;
    }
    LOLDatabase *database = self.db;
    NSString *deviceId = self.deviceId;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSUInteger total = 0;
        NSString *error = nil;
        NSMutableArray *prepared = [NSMutableArray arrayWithCapacity:records.count];
        NSMutableArray *keys = [NSMutableArray arrayWithCapacity:records.count];
        for(NSDictionary *record in records) {
            if(![record isKindOfClass:NSDictionary.class]) {
                error = @"The imported route contains an invalid record."; break;
            }
            NSString *key = record[@"id"];
            NSDictionary *properties = record[@"properties"];
            if(![properties isKindOfClass:NSDictionary.class] || ![key isKindOfClass:NSString.class] || ![key hasPrefix:@"healthkit:"]
               || ![record[@"type"] isEqual:@"Feature"] || ![properties[@"source"] isEqual:@"healthkit"]
               || ![NSJSONSerialization isValidJSONObject:record]) {
                error = @"The imported route contains an invalid record."; break;
            }
            NSMutableDictionary *copy = [record mutableCopy];
            NSMutableDictionary *metadata = [properties mutableCopy];
            if(deviceId.length) metadata[@"device_id"] = deviceId;
            copy[@"properties"] = metadata;
            [prepared addObject:copy];
            [keys addObject:key];
        }
        for(NSUInteger offset = 0; !error && offset < prepared.count; offset += 200) {
            NSRange range = NSMakeRange(offset, MIN(200, prepared.count - offset));
            NSUInteger inserted = 0;
            if(![database importRecords:[prepared subarrayWithRange:range] keys:[keys subarrayWithRange:range]
                        intoCollection:GLLocationQueueName insertedCount:&inserted]) {
                error = @"The route could not be fully queued. Retry to continue; committed points will not be duplicated.";
                break;
            }
            total += inserted;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self numberOfLocationsInQueue:^(long num) {}];
            [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];
            completion(total, error);
            [self sendQueueIfTimeElapsed];
        });
    });
}

- (void)sendQueueNow {
    self.userDrain = YES;
    [self flushQueue];
}

// Trip boundaries and pauses flush the queue too. While sending waits for Wi-Fi, the flush intent
// persists and goes out on the first Wi-Fi path.
- (void)flushQueue {
    self.drainAll = YES;
    self.uploadPending = YES;
    self.uploadBlocked = NO;
    [self persistUploadState];
    if(self.waitingForWifi && !self.userDrain) return;
    [self sendNextBatch];
}

- (BOOL)waitingForWifi {
    return !self.savesToICloudDrive && [GLWifiOnlySending shared].waitsOnCurrentPath;
}

- (void)wifiOnlySendingChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:GLUploadStateChangedNotification object:self];
    if(self.waitingForWifi) return;
    if(self.uploadPending) [self resumePendingUpload];
    else [self sendQueueIfTimeElapsed];
}

- (void)sendNextBatch {
    if(self.sendInProgress || self.uploadBlocked) return;
    if(self.nextUploadDate.timeIntervalSinceNow > 0) {
        [self scheduleUploadAfter:self.nextUploadDate.timeIntervalSinceNow];
        return;
    }
    [self.uploadTimer invalidate];
    self.uploadTimer = nil;

    NSMutableArray *syncedUpdates = [NSMutableArray array];
    NSMutableArray *locationUpdates = [NSMutableArray array];
    
    NSString *endpoint = self.apiEndpointURL;
    
    if(!self.savesToICloudDrive && ![GLManager isValidEndpoint:endpoint]) {
        NSLog(@"No API endpoint is set, not sending data");
        [self endSendBackgroundTask];
        return;
    }
    
    __block long _numInQueue = 0;
    __block BOOL owntracks = NO;
    __block BOOL segmentEnded = NO;
    int batchSize = MAX(1, self.pointsPerBatchCurrentValue);
    BOOL acceptHTTP = self.shouldConsiderHTTP200Success;
    
    BOOL loaded = [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        
        [accessor enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *object) {
            if(key && [object isKindOfClass:[NSDictionary class]]) {
                BOOL isOwntracks = [object[@"_type"] isKindOfClass:NSString.class];
                if(locationUpdates.count == 0) owntracks = isOwntracks;
                if(isOwntracks != owntracks) { segmentEnded = YES; return YES; }
                [syncedUpdates addObject:key];
                [locationUpdates addObject:object];
            } else if(key) {
                // Remove nil objects
                [accessor removeDictionaryForKey:key];
            }
            return (BOOL)(owntracks || locationUpdates.count >= batchSize);
        }];
        
        [accessor countObjectsUsingBlock:^(long num) {
            _numInQueue = num;
        }];
    }];
    if(!loaded) {
        self.uploadPending = YES;
        [self deferUploadForResponse:nil error:self.db.lastError ?: [NSError errorWithDomain:@"LOLDatabase" code:1 userInfo:nil]];
        [self endSendBackgroundTask];
        return;
    }
    
    NSDictionary *postData;

    if(locationUpdates.count == 0) {
        self.batchInProgress = NO;
        self.uploadPending = NO;
        self.drainAll = NO;
        [self persistUploadState];
        [self endSendBackgroundTask];
        return;
    }

    if(owntracks) {
        postData = locationUpdates[0];
    } else {
        NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:@{@"locations": locationUpdates}];
        postData = payload;

        // Recount the outgoing batch; the stored count describes the original callback.
        // Database records need mutable copies before their metadata can change.
        for(int i=0; i<(int)locationUpdates.count; i++) {
            NSDictionary *update = locationUpdates[i];
            NSDictionary *properties = [update objectForKey:@"properties"];
            if(![properties isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *newProperties = [properties mutableCopy];
            [newProperties setValue:[NSNumber numberWithLong:locationUpdates.count] forKey:@"locations_in_payload"];
            NSMutableDictionary *newUpdate = [update mutableCopy];
            [newUpdate setValue:newProperties forKey:@"properties"];
            [locationUpdates replaceObjectAtIndex:i withObject:newUpdate];
        }
        
        // Include the latest fix separately so a backlog does not hide the current location.
        if(_numInQueue > batchSize && self.lastLocation) {
            [payload setObject:[self currentDictionaryFromLocation:self.lastLocation] forKey:@"current"];
        }
        
        if(self.tripInProgress) {
            NSDictionary *currentTripInfo = [self currentTripDictionary];
            [payload setObject:currentTripInfo forKey:@"trip"];
        }
    }
    
    // If there are any template strings in the URL, replace the values with the data from the most recent location
    // TS, LAT, LON, ACC, SPD, ALT, BAT
    if(self.savesToICloudDrive) {
        [self saveCloudRecords:locationUpdates keys:syncedUpdates batchSize:batchSize owntracks:owntracks segmentEnded:segmentEnded];
        return;
    }

    NSString *endpointURL = [self endpoint:endpoint forLocation:self.lastLocation];
    
    NSLog(@"Updates in post: %lu", (unsigned long)locationUpdates.count);
    
    self.uploadPending = YES;
    self.drainRequests++;
    [self persistUploadState];
    [self sendingStarted];

    self.lastSendAttempt = NSDate.date;
    NSUInteger generation = ++self.sendGeneration;
    NSDictionary *headers = [self requestHeadersForOwntracks:owntracks];
    self.sendTask = [self postPayload:postData endpoint:endpointURL headers:headers success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
        if(generation != self.sendGeneration) return;
        if([responseObject isKindOfClass:[NSData class]]) {
            responseObject = [GLManager objectFromJSONData:responseObject error:NULL];
        }
        BOOL requestWasSuccessfullySent = NO;
        if(acceptHTTP || owntracks) {
            // OwnTracks acknowledges any 2xx, including an empty response or a JSON array.
            requestWasSuccessfullySent = YES;
        } else {
            // Response must be JSON
            if(![responseObject respondsToSelector:@selector(objectForKey:)]) {
                self.batchInProgress = NO;
                [self recordSendResult:GLSendStatusServerError];
                [self notifyUploadError:@"Server did not return a JSON object" title:@"Server Error"];
                [self deferUploadForResponse:nil error:nil];
                [self sendingFinished];
                return;
            }

            // Response JSON must include {"result":"ok"}
            requestWasSuccessfullySent = [[responseObject objectForKey:@"result"] isEqual:@"ok"];
        }
        
        
        if(requestWasSuccessfullySent) {
            [self acknowledgeKeys:syncedUpdates response:responseObject batchSize:batchSize
                       owntracks:owntracks segmentEnded:segmentEnded];
        } else {

            self.batchInProgress = NO;
            [self recordSendResult:GLSendStatusServerError];

            if([[responseObject objectForKey:@"error"] isKindOfClass:[NSString class]]) {
                [self notifyUploadError:[responseObject objectForKey:@"error"] title:@"Server Error"];
            } else {
                [self notifyUploadError:@"Server did not acknowledge the data was received, and did not return an error message" title:@"Server Error"];
            }

            [self deferUploadForResponse:nil error:nil];
            [self sendingFinished];
        }
    } failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
        if(generation != self.sendGeneration) return;
        self.batchInProgress = NO;
        NSInteger status = [(NSHTTPURLResponse *)task.response statusCode];
        [self recordSendResult:status >= 400 ? GLSendStatusServerError : GLSendStatusNetworkError];
        NSLog(@"Send failed (%@, %ld), HTTP %ld", error.domain, (long)error.code, (long)status);
        if(error.code == NSURLErrorServerCertificateUntrusted
           || error.code == NSURLErrorServerCertificateHasUnknownRoot
           || error.code == NSURLErrorServerCertificateHasBadDate
           || error.code == NSURLErrorClientCertificateRejected) {
            NSString *certMessage = [GLManager certificateFailureExplanation:error];
            NSLog(@"%@", certMessage);
            [self notifyUploadError:certMessage title:@"Certificate Error"];
        } else {
            [self notifyUploadError:error.localizedDescription title:@"HTTP Error"];
        }
        [self deferUploadForResponse:(NSHTTPURLResponse *)task.response error:error];
        [self sendingFinished];
    }];

}


- (void)acknowledgeKeys:(NSArray *)syncedUpdates response:(id)response batchSize:(int)batchSize
      owntracks:(BOOL)owntracks segmentEnded:(BOOL)segmentEnded {
    self.lastSendErrorTitle = nil;
    self.lastSendErrorMessage = nil;
    [self recordSendResult:GLSendStatusSuccess];
    self.lastSentDate = NSDate.date;
    NSDictionary *geocode = [response isKindOfClass:[NSDictionary class]] ? response[@"geocode"] : nil;
    id name = [geocode isKindOfClass:[NSDictionary class]] ? geocode[@"full_name"] : nil;
    self.lastLocationName = [name isKindOfClass:[NSString class]] ? name : @"";

    __block long remaining = 0;
    BOOL removed = [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        for(NSString *key in syncedUpdates) {
            [accessor removeDictionaryForKey:key];
        }
        [accessor countObjectsUsingBlock:^(long num) { remaining = num; }];
    }];

    if(!removed) {
        self.batchInProgress = NO;
        [self deferUploadForResponse:nil error:[NSError errorWithDomain:@"LOLDatabase" code:1 userInfo:nil]];
        [self sendingFinished];
        return;
    }

    _currentPointsInQueue = remaining;
    self.batchInProgress = remaining >= batchSize || (remaining > 0 && (owntracks || segmentEnded));

    self.uploadFailures = 0;
    self.waitingForNetwork = NO;
    self.nextUploadDate = nil;
    self.uploadBlocked = NO;
    self.lastUploadErrorNotification = nil;
    self.uploadPending = _currentPointsInQueue > 0 && (self.drainAll || self.batchInProgress);
    if(!self.uploadPending) {
        self.drainAll = NO;
        self.userDrain = NO;
    }
    [self persistUploadState];
    [self sendingFinished];
    [self updateSettingsFromResponse:response];
    if(self.uploadPending) [self scheduleUploadAfter:self.drainRequests >= 20 ? 1 : 0];
}


- (NSDictionary *)cloudFeature:(NSDictionary *)record key:(NSString *)key {
    NSMutableDictionary *feature;
    if([record[@"type"] isEqual:@"Feature"]) {
        feature = [record mutableCopy];
    } else {
        NSMutableDictionary *properties = [record mutableCopy];
        id seconds = properties[@"tst"];
        if([seconds isKindOfClass:NSNumber.class] && isfinite([seconds doubleValue])) {
            properties[@"timestamp"] = [GLManager iso8601DateStringFromDate:[NSDate dateWithTimeIntervalSince1970:[seconds doubleValue]]];
        }
        id lat = properties[@"lat"], lon = properties[@"lon"];
        id geometry = NSNull.null;
        if([lat isKindOfClass:NSNumber.class] && [lon isKindOfClass:NSNumber.class]
           && CLLocationCoordinate2DIsValid(CLLocationCoordinate2DMake([lat doubleValue], [lon doubleValue]))) {
            geometry = @{@"type": @"Point", @"coordinates": @[lon, lat]};
        }
        feature = [@{@"type": @"Feature", @"geometry": geometry, @"properties": properties} mutableCopy];
    }
    feature[@"id"] = key;
    return [GLManager JSONSafeObject:feature];
}

- (void)saveCloudRecords:(NSArray *)records keys:(NSArray *)keys batchSize:(int)batchSize
              owntracks:(BOOL)owntracks segmentEnded:(BOOL)segmentEnded {
    NSMutableArray *features = [NSMutableArray arrayWithCapacity:records.count];
    for(NSUInteger i = 0; i < records.count; i++) [features addObject:[self cloudFeature:records[i] key:keys[i]]];
    self.uploadPending = YES;
    self.drainRequests++;
    [self persistUploadState];
    [self sendingStarted];
    self.lastSendAttempt = NSDate.date;
    NSUInteger generation = ++self.sendGeneration;
    [(self.cloudWriter ?: GLCloudFileWriter.sharedWriter) writeFeatures:features mode:self.cloudFileMode completion:^(NSString *errorMessage) {
        if(generation != self.sendGeneration) return;
        if(errorMessage) {
            self.batchInProgress = NO;
            [self recordSendResult:GLSendStatusServerError];
            [self notifyUploadError:errorMessage title:@"iCloud Drive"];
            [self deferUploadForResponse:nil error:[NSError errorWithDomain:@"WhereWolfCloud" code:1 userInfo:nil]];
            [self sendingFinished];
            return;
        }
        [self acknowledgeKeys:keys response:nil batchSize:batchSize owntracks:owntracks segmentEnded:segmentEnded];
    }];
}

- (NSURLSessionDataTask *)postPayload:(NSDictionary *)payload endpoint:(NSString *)endpoint
                             headers:(NSDictionary *)headers
                             success:(void (^)(NSURLSessionDataTask *, id))success
                             failure:(void (^)(NSURLSessionDataTask *, NSError *))failure {
    NSError *error;
    NSData *body = [GLManager dataWithJSONObject:payload error:&error];
    NSURL *url = [NSURL URLWithString:endpoint];
    if(!body || !url) {
        dispatch_async(dispatch_get_main_queue(), ^{
            failure(nil, error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil]);
        });
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    for(NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];
    __block NSURLSessionDataTask *task;
    task = [self.httpSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *transportError) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSError *resultError = transportError;
            if(!resultError && (!http || http.statusCode < 200 || http.statusCode >= 300)) {
                resultError = [NSError errorWithDomain:@"WhereWolfHTTP" code:http.statusCode userInfo:@{
                    NSLocalizedDescriptionKey: [NSHTTPURLResponse localizedStringForStatusCode:http.statusCode]
                }];
            }
            if(resultError) failure(task, resultError);
            else success(task, data ?: NSData.data);
            task = nil;
        });
    }];
    [task resume];
    return task;
}

#pragma mark - Upload scheduling

- (void)persistUploadState {
    NSMutableDictionary *state = [@{@"pending": @(self.uploadPending), @"flush": @(self.drainAll),
        @"blocked": @(self.uploadBlocked), @"failures": @(self.uploadFailures), @"network": @(self.waitingForNetwork)} mutableCopy];
    if(self.nextUploadDate) state[@"retry"] = self.nextUploadDate;
    [NSUserDefaults.standardUserDefaults setObject:state forKey:GLUploadRetryStateDefaultsName];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLUploadStateChangedNotification object:self];
}

- (BOOL)pendingUploads {
    return self.uploadPending && (self.drainAll || self.sendingInterval.integerValue >= 0)
        && self.hasDestination;
}

- (BOOL)uploadsBlocked { return self.uploadBlocked; }
- (NSDate *)uploadRetryDate { return self.nextUploadDate; }

- (void)resumeUploadAfterConnectivity {
    if(![self.advancedTrackingOptions[@"connectivity_retry"] boolValue] || !self.waitingForNetwork
       || !self.pendingUploads || self.uploadBlocked) return;
    self.waitingForNetwork = NO;
    self.nextUploadDate = nil;
    [self persistUploadState];
    [self resumePendingUpload];
}

- (void)resetUploadRetry {
    [self.uploadTimer invalidate];
    self.uploadTimer = nil;
    self.nextUploadDate = nil;
    self.uploadFailures = 0;
    self.uploadBlocked = NO;
    self.waitingForNetwork = NO;
    self.drainRequests = 0;
    [self persistUploadState];
}

- (void)resumePendingUpload {
    if(!self.uploadPending || self.uploadBlocked || (!self.drainAll && self.sendingInterval.integerValue < 0)
       || (self.waitingForWifi && !self.userDrain)) {
        if(!self.sendInProgress) [self endSendBackgroundTask];
        return;
    }
    [self sendNextBatch];
}

- (void)scheduleUploadAfter:(NSTimeInterval)delay {
    [self.uploadTimer invalidate];
    if(delay >= 1) self.drainRequests = 0;
    __weak typeof(self) weakSelf = self;
    self.uploadTimer = [NSTimer scheduledTimerWithTimeInterval:MAX(0.001, delay) repeats:NO block:^(NSTimer *timer) {
        weakSelf.uploadTimer = nil;
        [weakSelf resumePendingUpload];
    }];
    self.uploadTimer.tolerance = MIN(1, MAX(0, delay) * 0.1);
}

+ (NSTimeInterval)retryAfter:(NSString *)value now:(NSDate *)now {
    if(![value isKindOfClass:NSString.class] || value.length == 0) return 0;
    NSScanner *scanner = [NSScanner scannerWithString:value];
    double seconds;
    if([scanner scanDouble:&seconds] && scanner.isAtEnd && isfinite(seconds) && seconds >= 0) return seconds;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
    NSDate *date = [formatter dateFromString:value];
    return date ? MAX(0, [date timeIntervalSinceDate:now]) : 0;
}

+ (NSTimeInterval)uploadBackoffForFailure:(NSUInteger)failure jitter:(double)jitter {
    double base = MIN(3600, 5 * pow(2, MIN(10, failure > 0 ? failure - 1 : 0)));
    return MIN(3600, base * (1 + MIN(1, MAX(0, jitter)) * 0.25));
}

- (void)deferUploadForResponse:(NSHTTPURLResponse *)response error:(NSError *)error {
    NSInteger status = response.statusCode;
    BOOL certificate = [error.domain isEqualToString:NSURLErrorDomain] &&
        (error.code == NSURLErrorServerCertificateUntrusted || error.code == NSURLErrorServerCertificateHasUnknownRoot ||
         error.code == NSURLErrorServerCertificateHasBadDate || error.code == NSURLErrorClientCertificateRejected ||
         error.code == NSURLErrorSecureConnectionFailed || error.code == NSURLErrorBadURL || error.code == NSURLErrorUnsupportedURL);
    BOOL transient = !certificate && (status == 0 || status == 408 || status == 429 || status >= 500);
    self.waitingForNetwork = transient && status == 0 && [error.domain isEqual:NSURLErrorDomain];
    self.uploadBlocked = !transient;
    // A blocked upload ends the user's drain, so later automatic sends wait for Wi-Fi again.
    if(!transient) self.userDrain = NO;
    self.uploadFailures = MIN(self.uploadFailures + 1, 32);
    self.drainRequests = 0;
    if(transient) {
        NSTimeInterval delay = [GLManager uploadBackoffForFailure:self.uploadFailures jitter:(double)arc4random_uniform(10001) / 10000];
        if(status == 429 || status == 503) {
            NSString *retryAfter = [response valueForHTTPHeaderField:@"Retry-After"];
            delay = MAX(delay, [GLManager retryAfter:retryAfter now:NSDate.date]);
        }
        self.nextUploadDate = [NSDate dateWithTimeIntervalSinceNow:delay];
        [self scheduleUploadAfter:delay];
    }
    [self persistUploadState];
}

- (void)notifyUploadError:(NSString *)message title:(NSString *)title {
    [TrackingTransitionLog recordErrorCategory:title];
    self.lastSendErrorTitle = title;
    self.lastSendErrorMessage = message;
    if(self.lastUploadErrorNotification && -self.lastUploadErrorNotification.timeIntervalSinceNow < 300) return;
    self.lastUploadErrorNotification = NSDate.date;
    [self postLocalNotification:message title:title];
}

// Include trust-evaluation errors to help diagnose the server's certificate setup.
+ (NSString *)certificateFailureExplanation:(NSError *)error {
    NSMutableString *message = [NSMutableString stringWithString:@"The server's certificate could not be verified."];

    SecTrustRef trust = (__bridge SecTrustRef)error.userInfo[NSURLErrorFailingURLPeerTrustErrorKey];
    if(trust) {
        CFErrorRef evaluateError = NULL;
        if(!SecTrustEvaluateWithError(trust, &evaluateError) && evaluateError) {
            NSError *current = (__bridge NSError *)evaluateError;
            int depth = 0;
            while(current && depth < 5) {
                NSString *reason = current.localizedDescription;
                if(reason.length > 0 && ![message containsString:reason]) {
                    [message appendFormat:@" %@", reason];
                }
                current = current.userInfo[NSUnderlyingErrorKey];
                depth++;
            }
            CFRelease(evaluateError);
        }
    } else {
        [message appendFormat:@" %@", error.localizedDescription];
    }

    [message appendString:@" iOS does not download missing intermediate certificates, so the server must present the complete chain with a certificate that matches the domain and is not expired."];
    return message;
}

- (BOOL)savesToICloudDrive {
    return [[[NSUserDefaults standardUserDefaults] stringForKey:GLDestinationDefaultsName] isEqualToString:@"icloud"];
}
- (void)setSavesToICloudDrive:(BOOL)iCloud {
    if(self.savesToICloudDrive == iCloud) return;
    [[NSUserDefaults standardUserDefaults] setObject:(iCloud ? @"icloud" : @"server") forKey:GLDestinationDefaultsName];
    [self resetUploadRetry];
    [self setupHTTPClient];
}

- (GLCloudFileMode)cloudFileMode {
    if([[[NSUserDefaults standardUserDefaults] stringForKey:GLCloudFileModeDefaultsName] isEqualToString:@"trips"]) {
        return GLCloudFileModeTrips;
    }
    return GLCloudFileModeDaily;
}
- (void)setCloudFileMode:(GLCloudFileMode)mode {
    if(self.cloudFileMode == mode) return;
    [[NSUserDefaults standardUserDefaults] setObject:(mode == GLCloudFileModeTrips ? @"trips" : @"daily") forKey:GLCloudFileModeDefaultsName];
    if(self.savesToICloudDrive) {
        [self resetUploadRetry];
        [self setupHTTPClient];
    }
}

- (BOOL)hasDestination {
    return self.savesToICloudDrive || [GLManager isValidEndpoint:self.apiEndpointURL];
}

// The OwnTracks format is only for sending to a server. Files in iCloud Drive are always GeoJSON.
- (BOOL)usesOwntracksFormat {
    return self.loggingModeCurrentValue == kGLLoggingModeOwntracks && !self.savesToICloudDrive;
}

+ (NSNumber *)booleanSetting:(id)value {
    if([value isKindOfClass:NSNumber.class] && ([value doubleValue] == 0 || [value doubleValue] == 1)) return @([value boolValue]);
    if([value isKindOfClass:NSString.class]) {
        NSString *text = [value lowercaseString];
        if([@[@"true", @"1"] containsObject:text]) return @YES;
        if([@[@"false", @"0"] containsObject:text]) return @NO;
    }
    return nil;
}

- (void)updateSettingsFromResponse:(id _Nullable)responseObject {
    if(![responseObject respondsToSelector:@selector(objectForKey:)]) {
        return;
    }
    NSDictionary *settings = [responseObject objectForKey:@"set"];
    if(settings == nil) {
        return;
    }
    
    if(![settings respondsToSelector:@selector(objectForKey:)]) {
        return;
    }
    

    
    [self performSettingsBatch:^{
    NSDictionary *sendIntervalBlocks = @{
        @"1s": ^{ self.sendingInterval = @1; },
        @"5s": ^{ self.sendingInterval = @5; },
        @"10s": ^{ self.sendingInterval = @10; },
        @"15s": ^{ self.sendingInterval = @15; },
        @"30s": ^{ self.sendingInterval = @30; },
        @"1m": ^{ self.sendingInterval = @60; },
        @"2m": ^{ self.sendingInterval = @120; },
        @"5m": ^{ self.sendingInterval = @300; },
        @"10m": ^{ self.sendingInterval = @600; },
        @"30m": ^{ self.sendingInterval = @1800; },
        @"off": ^{ self.sendingInterval = @-1; },
    };
    [self runBlock:sendIntervalBlocks fromDictionary:settings forKey:@"send_interval"];

    id wifiOnly = settings[@"send_wifi_only"];
    if([wifiOnly isKindOfClass:NSNumber.class]) [GLWifiOnlySending shared].enabled = [wifiOnly boolValue];

    id tripMode = settings[@"trip_mode"];
    if([tripMode isKindOfClass:NSString.class]) {
        NSString *mode = [GLTripModeStore modeIDForServerValue:tripMode];
        if(mode) self.currentTripMode = mode;
    }

    NSDictionary *main = [settings objectForKey:@"main"];
    if([main isKindOfClass:[NSDictionary class]]) {
        NSNumber *gpsOnly = [GLManager booleanSetting:main[@"discard_no_gps"]];
        NSNumber *stationaryOnly = [GLManager booleanSetting:main[@"discard_stationary"]];
        if(gpsOnly) self.discardPointsWithoutGPS = gpsOnly.boolValue;
        if(stationaryOnly) self.discardPointsWhileStationary = stationaryOnly.boolValue;
        
        NSDictionary *trackingModeBlocks = @{
            @"off": ^{ self.trackingMode = kGLTrackingModeOff; },
            @"standard": ^{ self.trackingMode = kGLTrackingModeStandard; },
            @"significant": ^{ self.trackingMode = kGLTrackingModeSignificant; },
            @"both": ^{ self.trackingMode = kGLTrackingModeStandardAndSignificant; },
        };
        [self runBlock:trackingModeBlocks fromDictionary:main forKey:@"tracking_mode"];

        if([[main objectForKey:@"visit_tracking"] respondsToSelector:@selector(boolValue)]) {
            self.visitTrackingEnabled = [[main objectForKey:@"visit_tracking"] boolValue];
        }
        
        NSDictionary *desiredAccuracyBlocks = @{
            @"nav": ^{ self.desiredAccuracy = kCLLocationAccuracyBestForNavigation; },
            @"best": ^{ self.desiredAccuracy = kCLLocationAccuracyBest; },
            @"10m": ^{ self.desiredAccuracy = kCLLocationAccuracyNearestTenMeters; },
            @"100m": ^{ self.desiredAccuracy = kCLLocationAccuracyHundredMeters; },
            @"1km": ^{ self.desiredAccuracy = kCLLocationAccuracyKilometer; },
            @"3km": ^{ self.desiredAccuracy = kCLLocationAccuracyThreeKilometers; },
        };
        [self runBlock:desiredAccuracyBlocks fromDictionary:main forKey:@"desired_accuracy"];

         NSMutableDictionary *activityTypeBlocks = [@{
            @"other": ^{ self.activityType = CLActivityTypeOther; },
            @"car": ^{ self.activityType = CLActivityTypeAutomotiveNavigation; },
            @"fitness": ^{ self.activityType = CLActivityTypeFitness; },
            @"nav": ^{ self.activityType = CLActivityTypeOtherNavigation; },
            @"air": ^{ self.activityType = CLActivityTypeAirborne; },
        } mutableCopy];
        if(@available(iOS 27.0, *)) { activityTypeBlocks[@"boat"] = ^{ self.activityType = CLActivityTypeMaritime; }; }
        [self runBlock:activityTypeBlocks fromDictionary:main forKey:@"activity_type"];

        if([[main objectForKey:@"background_indicator"] respondsToSelector:@selector(boolValue)]) {
            self.showBackgroundLocationIndicator = [[main objectForKey:@"background_indicator"] boolValue];
        }

        if([[main objectForKey:@"pause_automatically"] respondsToSelector:@selector(boolValue)]) {
            self.pausesAutomatically = [[main objectForKey:@"pause_automatically"] boolValue];
        }

        NSDictionary *loggingModeBlocks = @{
            @"all": ^{ self.loggingMode = kGLLoggingModeAllData; },
            @"latest": ^{ self.loggingMode = kGLLoggingModeOnlyLatest; },
            @"owntracks": ^{ self.loggingMode = kGLLoggingModeOwntracks; },
        };
        [self runBlock:loggingModeBlocks fromDictionary:main forKey:@"logging_mode"];
        
        NSDictionary *batchSizeBlocks = @{
            @50: ^{ self.pointsPerBatch = 50; },
            @100: ^{ self.pointsPerBatch = 100; },
            @200: ^{ self.pointsPerBatch = 200; },
            @500: ^{ self.pointsPerBatch = 500; },
            @1000: ^{ self.pointsPerBatch = 1000; },
        };
        [self runBlock:batchSizeBlocks fromDictionary:main forKey:@"batch_size"];

        NSDictionary *resumeWithGeofenceBlocks = @{
            @"off": ^{ self.resumesAfterDistance = -1; },
            @"100m": ^{ self.resumesAfterDistance = 100; },
            @"200m": ^{ self.resumesAfterDistance = 200; },
            @"500m": ^{ self.resumesAfterDistance = 500; },
            @"1km": ^{ self.resumesAfterDistance = 1000; },
            @"2km": ^{ self.resumesAfterDistance = 2000; },
        };
        [self runBlock:resumeWithGeofenceBlocks fromDictionary:main forKey:@"resume_with_geofence"];

        NSDictionary *minDistanceBlocks = @{
            @"off": ^{ self.discardPointsWithinDistance = -1; },
            @"1m": ^{ self.discardPointsWithinDistance = 1; },
            @"10m": ^{ self.discardPointsWithinDistance = 10; },
            @"50m": ^{ self.discardPointsWithinDistance = 50; },
            @"100m": ^{ self.discardPointsWithinDistance = 100; },
            @"500m": ^{ self.discardPointsWithinDistance = 500; },
        };
        [self runBlock:minDistanceBlocks fromDictionary:main forKey:@"min_distance"];

        NSDictionary *minTimeBlocks = @{
            @"1s": ^{ self.discardPointsWithinSeconds = 1; },
            @"5s": ^{ self.discardPointsWithinSeconds = 5; },
            @"10s": ^{ self.discardPointsWithinSeconds = 10; },
            @"30s": ^{ self.discardPointsWithinSeconds = 30; },
            @"1m": ^{ self.discardPointsWithinSeconds = 60; },
            @"5m": ^{ self.discardPointsWithinSeconds = 300; },
        };
        [self runBlock:minTimeBlocks fromDictionary:main forKey:@"min_time"];
        
        NSDictionary *maxAccuracyBlocks = @{
            @"off": ^{ self.discardPointsOutsideAccuracy = -1; },
            @"10m": ^{ self.discardPointsOutsideAccuracy = 10; },
            @"50m": ^{ self.discardPointsOutsideAccuracy = 50; },
            @"100m": ^{ self.discardPointsOutsideAccuracy = 100; },
            @"500m": ^{ self.discardPointsOutsideAccuracy = 500; },
            @"1000m": ^{ self.discardPointsOutsideAccuracy = 1000; },
        };
        [self runBlock:maxAccuracyBlocks fromDictionary:main forKey:@"max_accuracy"];
        
        NSDictionary *stopsRadiusBlocks = @{
            @"off": ^{ self.stopsAutomaticallyRadius = -1; },
            @"10m": ^{ self.stopsAutomaticallyRadius = 10; },
            @"20m": ^{ self.stopsAutomaticallyRadius = 20; },
            @"50m": ^{ self.stopsAutomaticallyRadius = 50; },
            @"100m": ^{ self.stopsAutomaticallyRadius = 100; },
            @"200m": ^{ self.stopsAutomaticallyRadius = 200; },
        };
        [self runBlock:stopsRadiusBlocks fromDictionary:main forKey:@"stop_radius"];

        NSDictionary *stopsTimeBlocks = @{
            @"1min": ^{ self.stopsAutomaticallyAfterSeconds = 60; },
            @"2min": ^{ self.stopsAutomaticallyAfterSeconds = 60*2; },
            @"5min": ^{ self.stopsAutomaticallyAfterSeconds = 60*5; },
            @"10min": ^{ self.stopsAutomaticallyAfterSeconds = 60*10; },
            @"20min": ^{ self.stopsAutomaticallyAfterSeconds = 60*20; },
        };
        [self runBlock:stopsTimeBlocks fromDictionary:main forKey:@"stop_time"];

    }

    NSDictionary *trip = [settings objectForKey:@"trip"];
    if(trip != nil && [trip respondsToSelector:@selector(objectForKey:)]) {
        NSNumber *gpsOnly = [GLManager booleanSetting:trip[@"discard_no_gps"]];
        NSNumber *stationaryOnly = [GLManager booleanSetting:trip[@"discard_stationary"]];
        if(gpsOnly) self.discardPointsWithoutGPSDuringTrip = gpsOnly.boolValue;
        if(stationaryOnly) self.discardPointsWhileStationaryDuringTrip = stationaryOnly.boolValue;
        // Remote settings never ask for notification permission; that waits for the switch in the app.
        NSNumber *askToEnd = [GLManager booleanSetting:trip[@"ask_to_end_when_stopped"]];
        if(askToEnd) [[NSUserDefaults standardUserDefaults] setBool:askToEnd.boolValue forKey:GLTripAskToEndWhenStoppedDefaultsName];

        
        NSDictionary *desiredAccuracyDuringTripBlocks = @{
            @"nav": ^{ self.desiredAccuracyDuringTrip = kCLLocationAccuracyBestForNavigation; },
            @"best": ^{ self.desiredAccuracyDuringTrip = kCLLocationAccuracyBest; },
            @"10m": ^{ self.desiredAccuracyDuringTrip = kCLLocationAccuracyNearestTenMeters; },
            @"100m": ^{ self.desiredAccuracyDuringTrip = kCLLocationAccuracyHundredMeters; },
            @"1km": ^{ self.desiredAccuracyDuringTrip = kCLLocationAccuracyKilometer; },
            @"3km": ^{ self.desiredAccuracyDuringTrip = kCLLocationAccuracyThreeKilometers; },
        };
        [self runBlock:desiredAccuracyDuringTripBlocks fromDictionary:trip forKey:@"desired_accuracy"];

         NSMutableDictionary *activityTypeDuringTripBlocks = [@{
            @"other": ^{ self.activityTypeDuringTrip = CLActivityTypeOther; },
            @"car": ^{ self.activityTypeDuringTrip = CLActivityTypeAutomotiveNavigation; },
            @"fitness": ^{ self.activityTypeDuringTrip = CLActivityTypeFitness; },
            @"nav": ^{ self.activityTypeDuringTrip = CLActivityTypeOtherNavigation; },
            @"air": ^{ self.activityTypeDuringTrip = CLActivityTypeAirborne; },
        } mutableCopy];
        if(@available(iOS 27.0, *)) { activityTypeDuringTripBlocks[@"boat"] = ^{ self.activityTypeDuringTrip = CLActivityTypeMaritime; }; }
        [self runBlock:activityTypeDuringTripBlocks fromDictionary:trip forKey:@"activity_type"];

        if([[trip objectForKey:@"background_indicator"] respondsToSelector:@selector(boolValue)]) {
            self.showBackgroundLocationIndicatorDuringTrip = [[trip objectForKey:@"background_indicator"] boolValue];
        }

        if([[trip objectForKey:@"prevent_screen_lock"] respondsToSelector:@selector(boolValue)]) {
            [[NSUserDefaults standardUserDefaults] setBool:[[trip objectForKey:@"prevent_screen_lock"] boolValue] forKey:GLScreenLockEnabledDefaultsName];
        }

        NSDictionary *loggingModeDuringTripBlocks = @{
            @"all": ^{ self.loggingModeDuringTrip = kGLLoggingModeAllData; },
            @"latest": ^{ self.loggingModeDuringTrip = kGLLoggingModeOnlyLatest; },
            @"owntracks": ^{ self.loggingModeDuringTrip = kGLLoggingModeOwntracks; },
        };
        [self runBlock:loggingModeDuringTripBlocks fromDictionary:trip forKey:@"logging_mode"];
        
        NSDictionary *batchSizeDuringTripBlocks = @{
            @50: ^{ self.pointsPerBatchDuringTrip = 50; },
            @100: ^{ self.pointsPerBatchDuringTrip = 100; },
            @200: ^{ self.pointsPerBatchDuringTrip = 200; },
            @500: ^{ self.pointsPerBatchDuringTrip = 500; },
            @1000: ^{ self.pointsPerBatchDuringTrip = 1000; },
        };
        [self runBlock:batchSizeDuringTripBlocks fromDictionary:trip forKey:@"batch_size"];

        NSDictionary *minDistanceDuringTripBlocks = @{
            @"off": ^{ self.discardPointsWithinDistanceDuringTrip = -1; },
            @"1m": ^{ self.discardPointsWithinDistanceDuringTrip = 1; },
            @"10m": ^{ self.discardPointsWithinDistanceDuringTrip = 10; },
            @"50m": ^{ self.discardPointsWithinDistanceDuringTrip = 50; },
            @"100m": ^{ self.discardPointsWithinDistanceDuringTrip = 100; },
            @"500m": ^{ self.discardPointsWithinDistanceDuringTrip = 500; },
        };
        [self runBlock:minDistanceDuringTripBlocks fromDictionary:trip forKey:@"min_distance"];

        NSDictionary *minTimeDuringTripBlocks = @{
            @"1s": ^{ self.discardPointsWithinSecondsDuringTrip = 1; },
            @"5s": ^{ self.discardPointsWithinSecondsDuringTrip = 5; },
            @"10s": ^{ self.discardPointsWithinSecondsDuringTrip = 10; },
            @"30s": ^{ self.discardPointsWithinSecondsDuringTrip = 30; },
            @"1m": ^{ self.discardPointsWithinSecondsDuringTrip = 60; },
            @"5m": ^{ self.discardPointsWithinSecondsDuringTrip = 300; },
        };
        [self runBlock:minTimeDuringTripBlocks fromDictionary:trip forKey:@"min_time"];

    }
    
    id headers = [settings objectForKey:@"custom_headers"];
    if([headers isKindOfClass:[NSDictionary class]]) self.customHTTPHeaders = headers;
    NSDictionary *advanced = settings[@"advanced_tracking"];
    if([advanced isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *merged = [self.advancedTrackingOptions mutableCopy];
        [merged addEntriesFromDictionary:advanced];
        self.advancedTrackingOptions = merged;
    }
    [UIApplication sharedApplication].idleTimerDisabled = self.tripInProgress && [[NSUserDefaults standardUserDefaults] boolForKey:GLScreenLockEnabledDefaultsName];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
    }];
}

- (void)runBlock:(NSDictionary *)blocks fromDictionary:(NSDictionary *)dictionary forKey:(NSString *)key {
    id property = [dictionary objectForKey:key];
    if([property isKindOfClass:[NSString class]] || [property isKindOfClass:[NSNumber class]]) {
        if([blocks objectForKey:property] != nil) {
            ((CaseBlock)blocks[property])();
        }
    }
}

- (NSString *)stringForProperty:(GLLocationProperty)prop ofLocation:(CLLocation *)location {
    if(!location && prop != kGLLocationPropertyBattery) return @"";
    NSString *string;
    switch(prop) {
        case kGLLocationPropertyTimestamp:
            string = [GLManager iso8601DateStringFromDate:location.timestamp];
            break;
        case kGLLocationPropertyLatitude:
            string = [[NSNumber numberWithDouble:((int)(location.coordinate.latitude * 10000000)) / 10000000.0] stringValue];
            break;
        case kGLLocationPropertyLongitude:
            string = [[NSNumber numberWithDouble:((int)(location.coordinate.longitude * 10000000)) / 10000000.0] stringValue];
            break;
            
        case kGLLocationPropertyAccuracy:
            string = [[NSNumber numberWithInt:(int)round(location.horizontalAccuracy)] stringValue];
            break;
        case kGLLocationPropertySpeed:
            string = [[NSNumber numberWithInt:(int)round(location.speed)] stringValue];
            break;
        case kGLLocationPropertyAltitude:
            string = [[NSNumber numberWithInt:(int)round(location.altitude)] stringValue];
            break;
        case kGLLocationPropertyBattery:
            string = [[self currentBatteryLevel] stringValue];
            break;
    }
    return string;
}

- (void)logAction:(NSString *)action {
    if(!self.includeTrackingStats || self.loggingModeCurrentValue == kGLLoggingModeOwntracks) {
        return;
    }

    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        NSString *timestamp = [GLManager iso8601DateStringFromDate:[NSDate date]];
        NSMutableDictionary *update = [NSMutableDictionary dictionaryWithDictionary:@{
                                                                                      @"type": @"Feature",
                                                                                      @"properties": [NSMutableDictionary dictionaryWithDictionary:@{
                                                                                              @"timestamp": timestamp,
                                                                                              @"action": action,
                                                                                              }]
                                                                                      }];
        [self addMetadataToUpdate:update];
        
        if(self.lastLocation) {
            [update setObject:@{
                                @"type": @"Point",
                                @"coordinates": @[
                                        [NSNumber numberWithDouble:self.lastLocation.coordinate.longitude],
                                        [NSNumber numberWithDouble:self.lastLocation.coordinate.latitude]
                                        ]
                                } forKey:@"geometry"];
        }
        [accessor setDictionary:update forKey:[NSString stringWithFormat:@"%@-log-%@", timestamp, NSUUID.UUID.UUIDString]];
    }];
}

#pragma mark - Connection test

- (NSString *)endpoint:(NSString *)endpoint forLocation:(CLLocation *)location {
    NSMutableString *endpointURL = [endpoint mutableCopy];
    [endpointURL replaceOccurrencesOfString:@"%TS"
                                 withString:[self stringForProperty:kGLLocationPropertyTimestamp ofLocation:location] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%LAT"
                                 withString:[self stringForProperty:kGLLocationPropertyLatitude ofLocation:location] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%LON"
                                 withString:[self stringForProperty:kGLLocationPropertyLongitude ofLocation:location] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%ACC"
                                 withString:[self stringForProperty:kGLLocationPropertyAccuracy ofLocation:location] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%SPD"
                                 withString:[self stringForProperty:kGLLocationPropertySpeed ofLocation:location] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%ALT"
                                 withString:[self stringForProperty:kGLLocationPropertyAltitude ofLocation:location] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];
    [endpointURL replaceOccurrencesOfString:@"%BAT"
                                 withString:[self stringForProperty:kGLLocationPropertyBattery ofLocation:location] options:NSLiteralSearch
                                      range:NSMakeRange(0, endpointURL.length)];


    return endpointURL;
}

- (NSURLRequest *)connectionTestRequestForLocation:(CLLocation *)location {
    if(!location || ![GLManager isValidEndpoint:self.apiEndpointURL] || ![self isValidLocation:location]) return nil;
    BOOL owntracks = self.loggingModeCurrentValue == kGLLoggingModeOwntracks;
    NSMutableDictionary *point = [(owntracks ? [self owntracksDictionaryFromLocation:location]
        : [self currentDictionaryFromLocation:location rememberWifi:NO]) mutableCopy];
    if(!owntracks) {
        NSMutableDictionary *properties = [point[@"properties"] mutableCopy];
        properties[@"test"] = @YES;
        properties[@"locations_in_payload"] = @1;
        point[@"properties"] = properties;
    }
    NSDictionary *payload = owntracks ? point : @{@"locations": @[point]};
    NSData *data = [GLManager dataWithJSONObject:payload error:NULL];
    NSURL *url = [NSURL URLWithString:[self endpoint:self.apiEndpointURL forLocation:location]];
    if(!data || !url) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = data;
    request.timeoutInterval = 15;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    NSDictionary *headers = [self requestHeadersForOwntracks:owntracks];
    for(NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];
    return request;
}

- (NSURLSessionDataTask *)testConnectionAtLocation:(CLLocation *)location
    completion:(void (^)(NSInteger status, BOOL acknowledged, NSError *error))completion {
    NSURLRequest *request = [self connectionTestRequestForLocation:location];
    if(!request) {
        completion(0, NO, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil]);
        return nil;
    }
    NSURLSessionDataTask *task = [self.httpSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        id body = data ? [GLManager objectFromJSONData:data error:NULL] : nil;
        BOOL acknowledged = [body isKindOfClass:NSDictionary.class] && [body[@"result"] isEqual:@"ok"];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(status, acknowledged, error); });
    }];
    [task resume];
    return task;
}

- (NSDictionary *)requestHeadersForOwntracks:(BOOL)owntracks {
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:self.customHTTPHeaders];
    if(self.apiAccessToken.length > 0) {
        headers[@"Authorization"] = [(owntracks ? @"Basic " : @"Bearer ") stringByAppendingString:self.apiAccessToken];
    }
    return headers;
}

- (void)accountInfo:(void(^)(NSString *name))block {
    if(![GLManager isValidEndpoint:self.apiEndpointURL]) { block(nil); return; }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:self.apiEndpointURL]];
    NSDictionary *headers = [self requestHeadersForOwntracks:self.usesOwntracksFormat];
    for(NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];
    [[self.httpSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        id object = !error && http.statusCode >= 200 && http.statusCode < 300 ? [GLManager objectFromJSONData:data error:NULL] : nil;
        id name = [object isKindOfClass:NSDictionary.class] ? object[@"name"] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ block([name isKindOfClass:NSString.class] ? name : nil); });
    }] resume];
}

- (void)numberOfLocationsInQueue:(void(^)(long num))callback {
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        [accessor countObjectsUsingBlock:^(long num) {
            _currentPointsInQueue = num;
            callback(num);
        }];
    }];
}

- (void)numberOfObjectsInQueue:(void(^)(long locations, long trips, long stats))callback {
    [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        __block long locations = 0;
        __block long trips = 0;
        __block long stats = 0;
        [accessor enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *object) {
            NSDictionary *properties = [object objectForKey:@"properties"];
            if([properties objectForKey:@"action"]) {
                stats++;
            } else if([[properties objectForKey:@"type"] isEqualToString:@"trip"]) {
                trips++;
            } else {
                locations++;
            }
            return NO;
        }];
        callback(locations, trips, stats);
    }];
}


- (void)requestAuthorizationPermission {
    bool isFirstRequest = false;
    if (@available(iOS 14.0, *)) {
        if(self.locationManager.authorizationStatus == kCLAuthorizationStatusNotDetermined) {
            isFirstRequest = true;
        }
    }
    if(isFirstRequest) {
        NSLog(@"Requesting WhenInUse Permission");
        [self.locationManager requestWhenInUseAuthorization];
    } else {
        NSLog(@"Requesting Always Permission");
        [self.locationManager requestAlwaysAuthorization];
    }
}


#pragma mark - GLManager control (private)

- (void)setupHTTPClient {
    if(self.settingsChangeDepth > 0) { self.httpReconfigurationPending = YES; return; }
    [self.uploadTimer invalidate];
    self.uploadTimer = nil;
    self.sendGeneration++;
    [self.sendTask cancel];
    if(self.sendInProgress) [self sendingFinished];
    [self endSendBackgroundTask];
    self.batchInProgress = NO;
    [self.httpSession invalidateAndCancel];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
    configuration.timeoutIntervalForRequest = 30;
    self.httpSession = [NSURLSession sessionWithConfiguration:configuration];
    _deviceId = [self deviceId];
    NSDictionary *state = [NSUserDefaults.standardUserDefaults dictionaryForKey:GLUploadRetryStateDefaultsName];
    self.uploadPending = [state[@"pending"] boolValue];
    self.drainAll = [state[@"flush"] boolValue];
    self.uploadBlocked = [state[@"blocked"] boolValue];
    self.waitingForNetwork = [state[@"network"] boolValue];
    self.uploadFailures = [state[@"failures"] unsignedIntegerValue];
    self.nextUploadDate = [state[@"retry"] isKindOfClass:NSDate.class] ? state[@"retry"] : nil;
    if(self.uploadPending && !self.uploadBlocked) [self scheduleUploadAfter:MAX(0, self.nextUploadDate.timeIntervalSinceNow)];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
}

- (void)restoreTrackingState {
    if(self.tripInProgress) {
        [self.tripdb open];
        self.tripDistanceLoaded = NO;
        [self currentTripDistance];
        _storeNextLocationAsTripStart = self.currentTripStartLocationDictionary == nil;
    }
    [UIApplication sharedApplication].idleTimerDisabled = self.tripInProgress && [[NSUserDefaults standardUserDefaults] boolForKey:GLScreenLockEnabledDefaultsName];
    if([[NSUserDefaults standardUserDefaults] boolForKey:GLTrackingStateDefaultsName]) {
        if(self.didPauseByRadius && !self.radiusPauseDate) self.radiusPauseDate = NSDate.date;
        self.trackingEnabled = YES;
        [self applyTrackingConfiguration];
    } else {
        [self disableTracking];
    }
}

- (NSString *)engineState {
    return WhereWolfLocationEngine.shared.state;
}

- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    NSNumber *authorization = @(manager.authorizationStatus);
    if(self.lastAuthorization && ![self.lastAuthorization isEqual:authorization]
       && (manager.authorizationStatus == kCLAuthorizationStatusAuthorizedAlways || manager.authorizationStatus == kCLAuthorizationStatusAuthorizedWhenInUse)) {
        [WhereWolfLocationEngine.shared resetLiveUpdatesFailure];
    }
    self.lastAuthorization = authorization;
    [WhereWolfLocationEngine.shared updateAuthorization:manager];
    if(manager.authorizationStatus == kCLAuthorizationStatusDenied || manager.authorizationStatus == kCLAuthorizationStatusRestricted) {
        [WhereWolfLocationEngine.shared stopLiveUpdates];
        [WhereWolfLocationEngine.shared endBackgroundSession];
        [self.locationManager stopUpdatingLocation];
        self.runningConfiguration = nil;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:GLAuthorizationStatusChangedNotification object:self];
    NSLog(@"Location Authorization Changed: %@", self.authorizationStatusAsString);
    if(self.trackingEnabled && (manager.authorizationStatus == kCLAuthorizationStatusAuthorizedAlways || manager.authorizationStatus == kCLAuthorizationStatusAuthorizedWhenInUse)) {
        [self requestTrackingReconfiguration];
    }
    [self reconcileLocationHealth];
}

- (void)enableTracking {
    [self resetStationaryAnchors];
    [self.adaptivePolicy reset];
    [self removeAdaptiveRegion];
    [self.qualityPolicy reset];
    self.qualityObservation = nil;
    self.trackingEnabled = YES;
    [self.locationHealthPolicy resetAtUptime:[self locationHealthUptime]];
    [WhereWolfLocationEngine.shared resetLiveUpdatesFailure];
    self.runningConfiguration = nil;
    [self applyTrackingConfiguration];
}

- (void)applyTrackingConfiguration {
    if(!self.trackingEnabled) return;
    BOOL recovery = [self.advancedTrackingOptions[@"background_recovery"] boolValue]
        && self.locationManager.authorizationStatus == kCLAuthorizationStatusAuthorizedAlways
        && [self.locationManager.class significantLocationChangeMonitoringAvailable];
    [WhereWolfLocationEngine.shared updateAuthorization:self.locationManager];
    [WhereWolfLocationEngine.shared configureAuthorizationSessionWithEnabled:[self.advancedTrackingOptions[@"explicit_service_session"] boolValue]
        tracking:self.hasContinuousUpdates];
    if(!self.hasContinuousUpdates) {
        self.runningConfiguration = nil;
        [self.adaptivePolicy reset];
        [self removeAdaptiveRegion];
    }
    if([self.advancedTrackingOptions[@"adaptive_require_motion"] boolValue]
       && CMMotionActivityManager.authorizationStatus != CMAuthorizationStatusAuthorized) {
        [self.adaptivePolicy reset];
        [self removeAdaptiveRegion];
    }

    if(self.didPauseByRadius && self.stopsAutomaticallyActive && !self.tripInProgress) {
        self.engineStationary = YES;
        [WhereWolfLocationEngine.shared stopLiveUpdates];
        [WhereWolfLocationEngine.shared endBackgroundSession];
        [WhereWolfLocationEngine.shared recordStationary:YES];
        [self.locationManager stopUpdatingLocation];
        [self.locationManager startMonitoringSignificantLocationChanges];
    } else if(self.tripInProgress) {
        NSLog(@"Monitoring standard location changes during trip");
        [self runEngineStandardUpdates];
        if(recovery) [self.locationManager startMonitoringSignificantLocationChanges];
        else [self.locationManager stopMonitoringSignificantLocationChanges];
    } else {
        switch(self.trackingMode) {
            case kGLTrackingModeOff:
                NSLog(@"Not monitoring continuous location");
                [[WhereWolfLocationEngine shared] stopLiveUpdates];
                [[WhereWolfLocationEngine shared] endBackgroundSession];
                [self.locationManager stopUpdatingLocation];
                [self.locationManager stopUpdatingHeading];
                [self.locationManager stopMonitoringSignificantLocationChanges];
                break;
            case kGLTrackingModeStandard:
                NSLog(@"Monitoring standard location changes");
                [self runEngineStandardUpdates];
                if(recovery) [self.locationManager startMonitoringSignificantLocationChanges];
                else [self.locationManager stopMonitoringSignificantLocationChanges];
                break;
            case kGLTrackingModeSignificant:
                NSLog(@"Monitoring significant location changes");
                [self.locationManager startMonitoringSignificantLocationChanges];
                [[WhereWolfLocationEngine shared] stopLiveUpdates];
                [[WhereWolfLocationEngine shared] endBackgroundSession];
                [self.locationManager stopUpdatingLocation];
                [self.locationManager stopUpdatingHeading];
                break;
            case kGLTrackingModeStandardAndSignificant:
                NSLog(@"Monitoring both standard and significant location changes");
                [self runEngineStandardUpdates];
                [self.locationManager startMonitoringSignificantLocationChanges];
                break;
        }
    }
    
    if(self.visitTrackingEnabled) {
        [self.locationManager startMonitoringVisits];
    } else {
        [self.locationManager stopMonitoringVisits];
    }
    
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;
    
    [self updateMotionTracking];

    NSLog(@"Location Authorization Status %@", self.authorizationStatusAsString);
    
    [self scheduleLocalNotification];
    [self reconcileLocationHealth];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLTrackingStateChangedNotification object:self];
}

- (void)disableTracking {
    [self resetStationaryAnchors];
    self.trackingEnabled = NO;
    [self syncTripLiveActivity];
    self.runningConfiguration = nil;
    [self.adaptivePolicy reset];
    [self.qualityPolicy reset];
    self.qualityObservation = nil;
    [self removeAdaptiveRegion];
    self.motionGeneration++;
    self.motionQueryInProgress = NO;
    self.motionTrackingStarted = NO;
    [WhereWolfLocationEngine.shared configureAuthorizationSessionWithEnabled:NO tracking:NO];
    self.didPauseByRadius = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runEngineStandardUpdates) object:nil];
    for(CLRegion *region in self.locationManager.monitoredRegions) {
        if([region.identifier isEqualToString:@"resume-from-pause"]) [self.locationManager stopMonitoringForRegion:region];
    }
    [self.locationManager stopUpdatingLocation];
    [UIDevice currentDevice].batteryMonitoringEnabled = NO;
    [[WhereWolfLocationEngine shared] stopLiveUpdates];
    [[WhereWolfLocationEngine shared] endBackgroundSession];
    [self.locationManager stopMonitoringVisits];
    [self.locationManager stopUpdatingHeading];
    [self.locationManager stopMonitoringSignificantLocationChanges];
    if(CMMotionActivityManager.isActivityAvailable) {
        [self.motionActivityManager stopActivityUpdates];
        self.lastMotion = nil;
    }
    [self cancelLocalNotification];
    [self reconcileLocationHealth];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLTrackingStateChangedNotification object:self];
}

- (void)sendingStarted {
    self.sendInProgress = YES;
    if(self.sendBackgroundTask == UIBackgroundTaskInvalid) {
        __weak typeof(self) weakSelf = self;
        self.sendBackgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"GLSendQueue" expirationHandler:^{
            [weakSelf sendTimeExpired];
        }];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSendingStartedNotification object:self];
}

- (void)sendTimeExpired {
    self.sendGeneration++;
    [self.sendTask cancel];
    self.batchInProgress = NO;
    [self recordSendResult:GLSendStatusNetworkError];
    [self deferUploadForResponse:nil error:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]];
    [self sendingFinished];
}

- (void)endSendBackgroundTask {
    if(self.sendBackgroundTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.sendBackgroundTask];
        self.sendBackgroundTask = UIBackgroundTaskInvalid;
    }
}

- (long)currentPointsInQueue {
    return _currentPointsInQueue;
}

- (void)sendingFinished {
    self.sendInProgress = NO;
    self.sendTask = nil;
    // Keep the same execution allowance across a drain, including its short yields.
    if(!self.uploadPending || self.uploadBlocked || self.nextUploadDate.timeIntervalSinceNow > 0) [self endSendBackgroundTask];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSendingFinishedNotification object:self];
}

#pragma mark - Send results log

- (void)recordSendResult:(GLSendStatus)status {
    [TrackingTransitionLog recordSend:status];
    if(!self.sendResultsLog) {
        self.sendResultsLog = [NSMutableArray array];
    }
    [self.sendResultsLog addObject:@{@"ts": @(NSDate.date.timeIntervalSince1970),
                                     @"status": @((NSInteger)status)}];
    if(self.sendResultsLog.count > 50) {
        [self.sendResultsLog removeObjectsInRange:NSMakeRange(0, self.sendResultsLog.count - 50)];
    }
}

- (NSArray *)recentSendResults {
    return [self.sendResultsLog copy] ?: @[];
}

- (void)sendQueueIfTimeElapsed {
    BOOL sendingEnabled = [self.sendingInterval integerValue] > -1;
    if(!sendingEnabled) {
        return;
    }

    if(self.sendInProgress) {
        NSLog(@"Send is already in progress");
        return;
    }

    // The interval keeps running, so this sends at the first chance once the phone is on Wi-Fi.
    if(self.waitingForWifi) return;

    NSDate *lastAttempt = self.lastSendAttempt ?: self.lastSentDate;
    BOOL timeElapsed = !lastAttempt || -lastAttempt.timeIntervalSinceNow >= self.sendingInterval.doubleValue;

    if(timeElapsed || self.batchInProgress) {
        NSLog(@"Sending a batch now");
        [self sendNextBatch];
    }
}

- (void)sendQueueIfNotInProgress {
    [self flushQueue];
}

#pragma mark - Scheduled local notifications

- (BOOL)reminderEligible {
    if(!self.trackingEnabled || !self.notificationsEnabled || self.engineStationary || self.didPauseByRadius) return NO;
    if(self.tripInProgress) return YES;
    return (self.trackingMode == kGLTrackingModeStandard || self.trackingMode == kGLTrackingModeStandardAndSignificant)
        && !self.stopsAutomaticallyActive;
}

- (UNMutableNotificationContent *)reminderContent {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = [NSString localizedUserNotificationStringForKey:@"WhereWolf" arguments:nil];
    content.body = [NSString localizedUserNotificationStringForKey:@"Location updates were stopped. Resume tracking or open the app." arguments:nil];
    content.sound = [UNNotificationSound defaultSound];
    content.categoryIdentifier = GLNotificationCategoryReminderName;
    return content;
}

// A delivered reminder can be answered long after it fired, so it never overrides Stop or a pause.
- (BOOL)resumeTrackingFromReminder {
    if(!self.reminderEligible) return NO;
    [self refreshLocation];
    [self scheduleLocalNotification];
    return YES;
}

- (void)scheduleLocalNotification {
    if(!self.reminderEligible) {
        [self cancelLocalNotification];
        return;
    }
    NSDate *lastScheduled = self.lastScheduledNotificationDate;
    if(lastScheduled && -lastScheduled.timeIntervalSinceNow < 60) return;
    NSUInteger revision = ++self.reminderRevision;
    self.reminderCancellationSent = NO;
    self.lastScheduledNotificationDate = NSDate.date;
    UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:600 repeats:NO];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"reminder" content:self.reminderContent trigger:trigger];
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    dispatch_async(GLNotificationQueue(), ^{
        // Reusing the identifier replaces the deadline without publishing a cancellation.
        [center addNotificationRequest:request withCompletionHandler:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if(revision != self.reminderRevision) return;
                if(error) self.lastScheduledNotificationDate = nil;
                [[NSNotificationCenter defaultCenter] postNotificationName:GLReminderChangedNotification object:self];
            });
        }];
    });
}

- (void)cancelLocalNotification {
    self.lastScheduledNotificationDate = nil;
    if(self.reminderCancellationSent) return;
    self.reminderCancellationSent = YES;
    self.reminderRevision++;
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    dispatch_async(GLNotificationQueue(), ^{
        [center removePendingNotificationRequestsWithIdentifiers:@[@"reminder"]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:GLReminderChangedNotification object:self];
        });
    });
}

- (NSDate *)lastScheduledNotificationDate {
    if([self defaultsKeyExists:GLLastScheduledNotificationDateDefaultsName]) {
        return (NSDate *)[[NSUserDefaults standardUserDefaults] objectForKey:GLLastScheduledNotificationDateDefaultsName];
    } else {
        return nil;
    }
}
- (void)setLastScheduledNotificationDate:(NSDate *)date {
    [[NSUserDefaults standardUserDefaults] setObject:date forKey:GLLastScheduledNotificationDateDefaultsName];
}


- (BOOL)tripLiveActivityEnabled { return [NSUserDefaults.standardUserDefaults boolForKey:GLTripLiveActivityEnabledDefaultsName]; }
- (void)setTripLiveActivityEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:GLTripLiveActivityEnabledDefaultsName];
    [self syncTripLiveActivity];
}
- (void)syncTripLiveActivity {
    [[TripLiveActivityController shared] syncWithTripStart:(self.tripLiveActivityEnabled && self.trackingEnabled ? self.currentTripStart : nil)
        mode:self.currentTripMode distance:self.currentTripDistance speed:self.lastLocation.speed];
}

#pragma mark - Trips

+ (NSArray *)GLTripModes {
    return GLTripModeStore.allModeIDs;
}

- (BOOL)tripInProgress {
    return [[NSUserDefaults standardUserDefaults] objectForKey:GLTripStartTimeDefaultsName] != nil;
}

- (NSString *)currentTripMode {
    NSString *mode = [[NSUserDefaults standardUserDefaults] stringForKey:GLTripModeDefaultsName];
    if(mode.length == 0 || (!self.tripInProgress && ![GLTripModeStore containsModeID:mode])) {
        mode = GLTripModeStore.defaultModeID;
    }
    return mode;
}

- (void)setCurrentTripMode:(NSString *)mode {
    if(![GLTripModeStore containsModeID:mode]) return;
    [[NSUserDefaults standardUserDefaults] setObject:mode forKey:GLTripModeDefaultsName];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
}

- (NSDate *)currentTripStart {
    if(!self.tripInProgress) {
        return nil;
    }
    return (NSDate *)[[NSUserDefaults standardUserDefaults] objectForKey:GLTripStartTimeDefaultsName];
}

- (NSTimeInterval)currentTripDuration {
    if(!self.tripInProgress) {
        return -1;
    }
    
    NSDate *startDate = self.currentTripStart;
    return [startDate timeIntervalSinceNow] * -1.0;
}

- (CLLocationDistance)currentTripDistance {
    if(!self.tripInProgress) return -1;
    if(self.tripDistanceLoaded) return self.tripDistanceCached;
    FMResultSet *rows = [self.tripdb executeQuery:@"SELECT timestamp, latitude, longitude FROM trips ORDER BY timestamp, id"];
    if(!rows) return self.tripDistanceCached;
    self.tripDistanceCached = 0;
    self.lastTripLocation = nil;
    while([rows next]) {
        CLLocation *loc = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake([rows doubleForColumnIndex:1], [rows doubleForColumnIndex:2])
            altitude:0 horizontalAccuracy:0 verticalAccuracy:-1 timestamp:[NSDate dateWithTimeIntervalSince1970:[rows doubleForColumnIndex:0]]];
        if(self.lastTripLocation) self.tripDistanceCached += [self.lastTripLocation distanceFromLocation:loc];
        self.lastTripLocation = loc;
    }
    [rows close];
    self.tripDistanceLoaded = YES;
    return self.tripDistanceCached;
}

- (BOOL)appendTripLocation:(CLLocation *)loc {
    [self currentTripDistance];
    if(![self.tripdb executeUpdate:@"INSERT INTO trips (timestamp, latitude, longitude) VALUES (?, ?, ?)",
         @(loc.timestamp.timeIntervalSince1970), @(loc.coordinate.latitude), @(loc.coordinate.longitude)]) return NO;
    if(!self.lastTripLocation || [loc.timestamp compare:self.lastTripLocation.timestamp] != NSOrderedAscending) {
        if(self.lastTripLocation) self.tripDistanceCached += [self.lastTripLocation distanceFromLocation:loc];
        self.lastTripLocation = loc;
        return YES;
    }
    // A delayed batch after restoration may insert before the restored endpoint.
    FMResultSet *before = [self.tripdb executeQuery:@"SELECT latitude, longitude FROM trips WHERE timestamp <= ? AND id != ? ORDER BY timestamp DESC, id DESC LIMIT 1",
        @(loc.timestamp.timeIntervalSince1970), @(self.tripdb.lastInsertRowId)];
    CLLocation *previous = [before next] ? [[CLLocation alloc] initWithLatitude:[before doubleForColumnIndex:0] longitude:[before doubleForColumnIndex:1]] : nil;
    [before close];
    FMResultSet *after = [self.tripdb executeQuery:@"SELECT latitude, longitude FROM trips WHERE timestamp > ? ORDER BY timestamp, id LIMIT 1", @(loc.timestamp.timeIntervalSince1970)];
    CLLocation *next = [after next] ? [[CLLocation alloc] initWithLatitude:[after doubleForColumnIndex:0] longitude:[after doubleForColumnIndex:1]] : nil;
    [after close];
    if(previous) self.tripDistanceCached += [previous distanceFromLocation:loc];
    if(next) self.tripDistanceCached += [loc distanceFromLocation:next];
    if(previous && next) self.tripDistanceCached -= [previous distanceFromLocation:next];
    return YES;
}

- (NSArray *)currentTripPoints {
    NSMutableArray *points = [NSMutableArray array];
    if(!self.tripInProgress || !self.tripdb || !self.tripdb.isOpen) {
        return points;
    }

    FMResultSet *s = [self.tripdb executeQuery:@"SELECT id, timestamp, latitude, longitude FROM (SELECT id, timestamp, latitude, longitude FROM trips ORDER BY id DESC LIMIT 1000) ORDER BY id"];
    while([s next]) {
        [points addObject:@{
            @"id": @([s longLongIntForColumnIndex:0]),
            @"timestamp": @([s doubleForColumnIndex:1]),
            @"latitude": @([s doubleForColumnIndex:2]),
            @"longitude": @([s doubleForColumnIndex:3]),
        }];
    }
    [s close];
    return points;
}

- (NSDictionary *)currentTripStartLocationDictionary {
    if(!self.tripInProgress) {
        self.tripStartLocationDictionary = nil;
        return nil;
    }
    if(self.tripStartLocationDictionary == nil) {
        NSDictionary *startLocation = (NSDictionary *)[[NSUserDefaults standardUserDefaults] objectForKey:GLTripStartLocationDefaultsName];
        self.tripStartLocationDictionary = startLocation;
    }
    return self.tripStartLocationDictionary;
}

- (NSDictionary *)currentTripDictionary {
    return @{
            @"mode": [GLTripModeStore serverValueForModeID:self.currentTripMode],
            @"start": [GLManager iso8601DateStringFromDate:self.currentTripStart],
            @"distance": [NSNumber numberWithDouble:self.currentTripDistance],
            @"start_location": (self.currentTripStartLocationDictionary ?: [NSNull null]),
            @"current_location": (self.lastLocationDictionary ?: [NSNull null]),
    };
}

- (void)startTrip {
    if(self.tripInProgress) {
        return;
    }

    [self flushQueue];

    if(![self.tripdb open]) return;
    [self clearTripDB];
    [[NSUserDefaults standardUserDefaults] setBool:self.trackingEnabled forKey:GLTripTrackingEnabledDefaultsName];
    self.tripDistanceCached = 0;
    self.tripDistanceLoaded = YES;
    self.lastTripLocation = nil;
    
    NSDate *startDate = [NSDate date];
    [[NSUserDefaults standardUserDefaults] setObject:startDate forKey:GLTripStartTimeDefaultsName];
    
    _storeNextLocationAsTripStart = YES;
    NSLog(@"Store next location as trip start. Current trip start: %@", self.tripStartLocationDictionary);

    [self startAllUpdates];
    [UIApplication sharedApplication].idleTimerDisabled = [[NSUserDefaults standardUserDefaults] boolForKey:GLScreenLockEnabledDefaultsName];

    NSLog(@"Started a trip at %@", startDate);
    
    [self incrementTripMode:self.currentTripMode];
    [self syncTripLiveActivity];
}

- (void)endTrip {
    [self endTripFromAutopause:NO];
}

- (void)endTripFromAutopause:(BOOL)autopause {
    [self endTripAtDate:nil location:nil autopause:autopause];
}

- (void)endTripAtDate:(NSDate *)endDate location:(CLLocation *)location {
    [self endTripAtDate:endDate location:location autopause:NO];
}

- (void)endTripAtDate:(NSDate *)endDate location:(CLLocation *)location autopause:(BOOL)autopause {
    if(!self.tripInProgress || self.endingTrip) return;
    self.endingTrip = YES;
    _storeNextLocationAsTripStart = NO;
    if([CMPedometer isStepCountingAvailable]) {
        [self.pedometer queryPedometerDataFromDate:self.currentTripStart toDate:(endDate ?: NSDate.date) withHandler:^(CMPedometerData *data, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self writeTripToDB:autopause steps:data.numberOfSteps.integerValue endDate:endDate location:location];
            });
        }];
    } else {
        [self writeTripToDB:autopause steps:0 endDate:endDate location:location];
    }
}

// A prompt sent after the phone stopped ends the trip when it stopped, if it is still the same
// trip. Other End Trip prompts end it now.
- (void)endTripFromPrompt:(NSDictionary *)info {
    if(!self.tripInProgress) return;
    NSDate *stopDate = [self stopDateForPrompt:info];
    if(!stopDate) {
        [self endTrip];
        return;
    }
    NSNumber *latitude = info[GLEndTripPromptLatitudeKey];
    NSNumber *longitude = info[GLEndTripPromptLongitudeKey];
    CLLocation *stopLocation;
    if([latitude isKindOfClass:NSNumber.class] && [longitude isKindOfClass:NSNumber.class]) {
        stopLocation = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake(latitude.doubleValue, longitude.doubleValue)
            altitude:0 horizontalAccuracy:[info[GLEndTripPromptAccuracyKey] doubleValue] verticalAccuracy:-1 timestamp:stopDate];
    }
    [self endTripAtDate:stopDate location:stopLocation];
}

- (NSDate *)stopDateForPrompt:(NSDictionary *)info {
    NSNumber *tripStart = info[GLEndTripPromptTripStartKey];
    NSNumber *stoppedAt = info[GLEndTripPromptStoppedAtKey];
    if(![tripStart isKindOfClass:NSNumber.class] || ![stoppedAt isKindOfClass:NSNumber.class]
       || fabs(self.currentTripStart.timeIntervalSince1970 - tripStart.doubleValue) >= 1
       || stoppedAt.doubleValue <= tripStart.doubleValue) return nil;
    return [NSDate dateWithTimeIntervalSince1970:MIN(stoppedAt.doubleValue, NSDate.date.timeIntervalSince1970)];
}

- (CLLocationDistance)tripDistanceUntil:(NSDate *)end {
    FMResultSet *rows = [self.tripdb executeQuery:@"SELECT latitude, longitude FROM trips WHERE timestamp <= ? ORDER BY timestamp, id",
        @(end.timeIntervalSince1970)];
    if(!rows) return self.currentTripDistance;
    CLLocationDistance distance = 0;
    CLLocation *previous;
    while([rows next]) {
        CLLocation *loc = [[CLLocation alloc] initWithLatitude:[rows doubleForColumnIndex:0] longitude:[rows doubleForColumnIndex:1]];
        if(previous) distance += [previous distanceFromLocation:loc];
        previous = loc;
    }
    [rows close];
    return distance;
}

- (void)incrementTripMode:(NSString *)tripMode {
    NSMutableDictionary *currentStats = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:GLTripModeStatsDefaultsName] mutableCopy];
    if(currentStats == nil) {
        currentStats = [[NSMutableDictionary alloc] init];
    }
    NSNumber *count = [currentStats valueForKey:tripMode];
    NSNumber *newCount;
    if(count != nil) {
        newCount = [NSNumber numberWithInt:[count intValue] + 1];
    } else {
        newCount = @1;
    }
    [currentStats setValue:newCount forKey:tripMode];
    [[NSUserDefaults standardUserDefaults] setValue:currentStats forKey:GLTripModeStatsDefaultsName];
}

- (NSArray *)tripModesByFrequency {
    NSDictionary *currentStats = [[NSUserDefaults standardUserDefaults] dictionaryForKey:GLTripModeStatsDefaultsName];
    NSArray *tripModes = [currentStats keysSortedByValueUsingComparator:^NSComparisonResult(id  _Nonnull obj1, id  _Nonnull obj2) {
        return [(NSNumber*)obj2 compare:(NSNumber*)obj1];
    }];
    return tripModes;
}

- (void)writeTripToDB:(BOOL)autopause steps:(NSInteger)numberOfSteps {
    [self writeTripToDB:autopause steps:numberOfSteps endDate:nil location:nil];
}

- (void)writeTripToDB:(BOOL)autopause steps:(NSInteger)numberOfSteps endDate:(NSDate *)endDate location:(CLLocation *)location {

    if(!self.tripInProgress) { self.endingTrip = NO; return; }
    NSDate *end = endDate ?: NSDate.date;
    CLLocation *endLocation = location ?: self.lastLocation;
    NSDictionary *endLocationDictionary = location ? [self currentDictionaryFromLocation:location] : self.lastLocationDictionary;
    NSTimeInterval duration = endDate ? [endDate timeIntervalSinceDate:self.currentTripStart] : self.currentTripDuration;
    CLLocationDistance distance = endDate ? [self tripDistanceUntil:endDate] : self.currentTripDistance;
    BOOL committed = [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        NSString *timestamp = [GLManager iso8601DateStringFromDate:end];
        NSDictionary *currentTrip = @{
                                      @"type": @"Feature",
                                      @"geometry": endLocation ? @{
                                              @"type": @"Point",
                                              @"coordinates": @[@(endLocation.coordinate.longitude), @(endLocation.coordinate.latitude)]
                                              } : (id)[NSNull null],
                                      @"properties": [NSMutableDictionary dictionaryWithDictionary:@{
                                              @"timestamp": timestamp,
                                              @"type": @"trip",
                                              @"mode": [GLTripModeStore serverValueForModeID:self.currentTripMode],
                                              @"start": [GLManager iso8601DateStringFromDate:self.currentTripStart],
                                              @"end": timestamp,
                                              @"start_location": (self.tripStartLocationDictionary ?: [NSNull null]),
                                              @"end_location":(endLocationDictionary ?: [NSNull null]),
                                              @"duration": [NSNumber numberWithDouble:duration],
                                              @"distance": [NSNumber numberWithDouble:distance],
                                              @"stopped_automatically": @(autopause),
                                              @"steps": [NSNumber numberWithInteger:numberOfSteps],
                                              }]
                                      };
        [currentTrip[@"properties"] addEntriesFromDictionary:[GLTripModeStore iconPropertiesForModeID:self.currentTripMode]];
        [self addMetadataToUpdate:currentTrip];
        [accessor setDictionary:currentTrip forKey:[NSString stringWithFormat:@"%@-trip-%@", timestamp, NSUUID.UUID.UUIDString]];
    }];

    if(!committed) {
        self.endingTrip = NO;
        NSLog(@"Trip summary could not be saved: %@", self.db.lastError.localizedDescription);
        return;
    }
    if(autopause) [self notify:@"Trip ended automatically" withTitle:@"Tracker"];
    [self resetStationaryAnchors];
    self.lastTripLocation = nil;
    self.tripDistanceLoaded = NO;
    self.tripStartLocationDictionary = nil;
    // Before the trip start is removed, since the Health recorder reads it then.
    [[NSUserDefaults standardUserDefaults] setObject:end forKey:GLLastTripEndDefaultsName];
    [[NSUserDefaults standardUserDefaults] setObject:nil forKey:GLTripStartTimeDefaultsName];
    [[NSUserDefaults standardUserDefaults] setObject:nil forKey:GLTripStartLocationDefaultsName];

    self.tripDistanceCached = 0;
    [self clearTripDB];
    [self.tripdb close];
    
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:GLTripStartTimeDefaultsName];
    self.endingTrip = NO;
    [self syncTripLiveActivity];
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    if(self.trackingEnabled) {
        if([[NSUserDefaults standardUserDefaults] boolForKey:GLTripTrackingEnabledDefaultsName]) [self enableTracking];
        else [self stopAllUpdates];
    }
    [self numberOfLocationsInQueue:^(long num) {}];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];
    [self flushQueue];
    NSLog(@"Ended a %@ trip", self.currentTripMode);
}

#pragma mark - Properties

- (CLLocationManager *)locationManager {
    if (!_locationManager) {
        _locationManager = [[CLLocationManager alloc] init];
        _locationManager.delegate = self;
        _locationManager.distanceFilter = kCLDistanceFilterNone;
        _locationManager.allowsBackgroundLocationUpdates = YES;
        if(self.tripInProgress) {
            _locationManager.pausesLocationUpdatesAutomatically = self.pausesAutomaticallyDuringTrip;
            _locationManager.desiredAccuracy = self.desiredAccuracyDuringTrip;
            _locationManager.activityType = self.activityTypeDuringTrip;
        } else {
            _locationManager.pausesLocationUpdatesAutomatically = self.pausesAutomatically;
            _locationManager.desiredAccuracy = self.desiredAccuracy;
            _locationManager.activityType = self.activityType;
        }
    }
    
    return _locationManager;
}

- (CMMotionActivityManager *)motionActivityManager {
    if (!_motionActivityManager) {
        _motionActivityManager = [[CMMotionActivityManager alloc] init];
    }
    
    return _motionActivityManager;
}

- (NSString *)currentBatteryState {
    switch([UIDevice currentDevice].batteryState) {
        case UIDeviceBatteryStateUnknown:
            return @"unknown";
        case UIDeviceBatteryStateCharging:
            return @"charging";
        case UIDeviceBatteryStateFull:
            return @"full";
        case UIDeviceBatteryStateUnplugged:
            return @"unplugged";
    }
}

- (NSNumber *)currentBatteryLevel {
    return [NSNumber numberWithDouble:((int)([UIDevice currentDevice].batteryLevel * 100)) / 100.0];
}

- (NSString *)authorizationStatusAsString {
    if (@available(iOS 14.0, *)) {
        switch(self.locationManager.authorizationStatus) {
            case kCLAuthorizationStatusNotDetermined:
                return @"Not Determined";
            case kCLAuthorizationStatusRestricted:
                return @"Restricted";
            case kCLAuthorizationStatusDenied:
                return @"Denied";
            case kCLAuthorizationStatusAuthorizedWhenInUse:
                return @"When in Use";
            case kCLAuthorizationStatusAuthorizedAlways:
                return @"Always";
        }
    } else {
        return @"Unknown";
    }
}

- (BOOL)shouldConsiderHTTP200Success {
    NSUserDefaults *standardUserDefaults = [NSUserDefaults standardUserDefaults];
    return [standardUserDefaults boolForKey:GLConsiderHTTP200SuccessDefaultsName];
}

- (CLLocationDistance)resumesAfterDistance {
    if([self defaultsKeyExists:GLResumesAutomaticallyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLResumesAutomaticallyDefaultsName];
    } else {
        return -1;
    }
}
- (void)setResumesAfterDistance:(CLLocationDistance)resumesAfterDistance {
    [[NSUserDefaults standardUserDefaults] setDouble:resumesAfterDistance forKey:GLResumesAutomaticallyDefaultsName];
}

- (CLLocationDistance)discardPointsWithinDistance {
    if([self defaultsKeyExists:GLDiscardPointsWithinDistanceDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLDiscardPointsWithinDistanceDefaultsName];
    } else {
        return -1;
    }
}
- (void)setDiscardPointsWithinDistance:(CLLocationDistance)distance {
    [[NSUserDefaults standardUserDefaults] setDouble:distance forKey:GLDiscardPointsWithinDistanceDefaultsName];
}

- (CLLocationAccuracy)discardPointsOutsideAccuracy {
    if([self defaultsKeyExists:GLDiscardPointsOutsideAccuracyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLDiscardPointsOutsideAccuracyDefaultsName];
    } else {
        return -1;
    }
}
- (void)setDiscardPointsOutsideAccuracy:(CLLocationAccuracy)distance {
    [[NSUserDefaults standardUserDefaults] setDouble:distance forKey:GLDiscardPointsOutsideAccuracyDefaultsName];
}

- (CLLocationDistance)discardPointsWithinDistanceDuringTrip {
    if([self defaultsKeyExists:GLTripDiscardPointsWithinDistanceDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLTripDiscardPointsWithinDistanceDefaultsName];
    } else {
        return -1;
    }
}
- (void)setDiscardPointsWithinDistanceDuringTrip:(CLLocationDistance)distance {
    [[NSUserDefaults standardUserDefaults] setDouble:distance forKey:GLTripDiscardPointsWithinDistanceDefaultsName];
}

- (CLLocationDistance)discardPointsWithinDistanceCurrentValue {
    if(self.tripInProgress) {
        return self.discardPointsWithinDistanceDuringTrip;
    } else {
        return self.discardPointsWithinDistance;
    }
}

- (int)discardPointsWithinSeconds {
    if([self defaultsKeyExists:GLDiscardPointsWithinSecondsDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLDiscardPointsWithinSecondsDefaultsName];
    } else {
        return 1;
    }
}
- (void)setDiscardPointsWithinSeconds:(int)seconds {
    [[NSUserDefaults standardUserDefaults] setInteger:seconds forKey:GLDiscardPointsWithinSecondsDefaultsName];
}

- (int)discardPointsWithinSecondsDuringTrip {
    if([self defaultsKeyExists:GLTripDiscardPointsWithinSecondsDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLTripDiscardPointsWithinSecondsDefaultsName];
    } else {
        return 1;
    }
}
- (void)setDiscardPointsWithinSecondsDuringTrip:(int)seconds {
    [[NSUserDefaults standardUserDefaults] setInteger:seconds forKey:GLTripDiscardPointsWithinSecondsDefaultsName];
}

- (int)discardPointsWithinSecondsCurrentValue {
    if(self.tripInProgress) {
        return self.discardPointsWithinSecondsDuringTrip;
    } else {
        return self.discardPointsWithinSeconds;
    }
}

- (CLLocationDistance)stopsAutomaticallyRadius {
    if([self defaultsKeyExists:GLStopsAutomaticallyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLStopsAutomaticallyDefaultsName];
    } else {
        return -1;
    }
}
- (void)setStopsAutomaticallyRadius:(CLLocationDistance)distance {
    BOOL wasPaused = self.didPauseByRadius;
    [[NSUserDefaults standardUserDefaults] setDouble:distance forKey:GLStopsAutomaticallyDefaultsName];
    [self resetStationaryAnchors];
    if(wasPaused && self.trackingEnabled) [self requestTrackingReconfiguration];
    [self scheduleLocalNotification];
}

- (BOOL)stopsAutomaticallyActive {
    return self.trackingMode == kGLTrackingModeStandardAndSignificant
        && self.stopsAutomaticallyRadius != -1
        && !self.pausesAutomatically;
}

- (int)stopsAutomaticallyAfterSeconds {
    if([self defaultsKeyExists:GLStopsAutomaticallyAfterDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLStopsAutomaticallyAfterDefaultsName];
    } else {
        return 60;
    }
}
- (void)setStopsAutomaticallyAfterSeconds:(int)seconds {
    [[NSUserDefaults standardUserDefaults] setInteger:seconds forKey:GLStopsAutomaticallyAfterDefaultsName];
}

- (BOOL)didPauseByRadius {
    return [[NSUserDefaults standardUserDefaults] boolForKey:GLDidPauseByRadiusDefaultsName];
}

- (void)setDidPauseByRadius:(BOOL)didPause {
    [[NSUserDefaults standardUserDefaults] setBool:didPause forKey:GLDidPauseByRadiusDefaultsName];
}

- (NSDate *)radiusPauseDate {
    id date = [NSUserDefaults.standardUserDefaults objectForKey:GLRadiusPauseDateDefaultsName];
    return [date isKindOfClass:NSDate.class] ? date : nil;
}

- (void)setRadiusPauseDate:(NSDate *)date {
    if(date) [NSUserDefaults.standardUserDefaults setObject:date forKey:GLRadiusPauseDateDefaultsName];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:GLRadiusPauseDateDefaultsName];
}


- (BOOL)discardPointsWithoutGPS {
    return [[NSUserDefaults standardUserDefaults] boolForKey:GLDiscardPointsWithoutGPSDefaultsName];
}
- (void)setDiscardPointsWithoutGPS:(BOOL)discard {
    [[NSUserDefaults standardUserDefaults] setBool:discard forKey:GLDiscardPointsWithoutGPSDefaultsName];
}

- (BOOL)discardPointsWithoutGPSDuringTrip {
    return [[NSUserDefaults standardUserDefaults] boolForKey:GLTripDiscardPointsWithoutGPSDefaultsName];
}
- (void)setDiscardPointsWithoutGPSDuringTrip:(BOOL)discard {
    [[NSUserDefaults standardUserDefaults] setBool:discard forKey:GLTripDiscardPointsWithoutGPSDefaultsName];
}

- (BOOL)discardPointsWithoutGPSCurrentValue {
    if(self.tripInProgress) {
        return self.discardPointsWithoutGPSDuringTrip;
    } else {
        return self.discardPointsWithoutGPS;
    }
}

- (BOOL)discardPointsWhileStationary {
    return [[NSUserDefaults standardUserDefaults] boolForKey:GLDiscardPointsWhileStationaryDefaultsName];
}
- (void)setDiscardPointsWhileStationary:(BOOL)discard {
    [[NSUserDefaults standardUserDefaults] setBool:discard forKey:GLDiscardPointsWhileStationaryDefaultsName];
}

- (BOOL)discardPointsWhileStationaryDuringTrip {
    return [[NSUserDefaults standardUserDefaults] boolForKey:GLTripDiscardPointsWhileStationaryDefaultsName];
}
- (void)setDiscardPointsWhileStationaryDuringTrip:(BOOL)discard {
    [[NSUserDefaults standardUserDefaults] setBool:discard forKey:GLTripDiscardPointsWhileStationaryDefaultsName];
}

- (BOOL)discardPointsWhileStationaryCurrentValue {
    if(self.tripInProgress) {
        return self.discardPointsWhileStationaryDuringTrip;
    } else {
        return self.discardPointsWhileStationary;
    }
}


#pragma mark CLLocationManager

- (NSSet *)monitoredRegions {
    return self.locationManager.monitoredRegions;
}

- (BOOL)pausesAutomatically {
    if([self defaultsKeyExists:GLPausesAutomaticallyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLPausesAutomaticallyDefaultsName];
    } else {
        return NO;
    }
}
- (void)setPausesAutomatically:(BOOL)pausesAutomatically {
    BOOL prevValue = self.pausesAutomatically;
    if(prevValue != pausesAutomatically) {
        [[NSUserDefaults standardUserDefaults] setBool:pausesAutomatically forKey:GLPausesAutomaticallyDefaultsName];
        if(!self.tripInProgress) {
            NSLog(@"Setting pausesLocationUpdatesAutomatically %d", pausesAutomatically);
            [self requestTrackingReconfiguration];
        }
    }
}

- (BOOL)pausesAutomaticallyDuringTrip {
    if([self defaultsKeyExists:GLTripPausesAutomaticallyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLTripPausesAutomaticallyDefaultsName];
    } else {
        return NO;
    }
}
- (void)setPausesAutomaticallyDuringTrip:(BOOL)pausesAutomatically {
    BOOL prevValue = self.pausesAutomaticallyDuringTrip;
    if(prevValue != pausesAutomatically) {
        [[NSUserDefaults standardUserDefaults] setBool:pausesAutomatically forKey:GLTripPausesAutomaticallyDefaultsName];
        if(self.tripInProgress) {
            NSLog(@"Setting pausesLocationUpdatesAutomatically while trip is in progress %d", pausesAutomatically);
            [self requestTrackingReconfiguration];
        }
    }
}

- (BOOL)includeTrackingStats {
    if([self defaultsKeyExists:GLIncludeTrackingStatsDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLIncludeTrackingStatsDefaultsName];
    } else {
        return NO;
    }
}
- (void)setIncludeTrackingStats:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:GLIncludeTrackingStatsDefaultsName];
}

- (GLTrackingMode)trackingMode {
    if([self defaultsKeyExists:GLSignificantLocationModeDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLSignificantLocationModeDefaultsName];
    } else {
        return kGLTrackingModeStandard;
    }
}
- (void)setTrackingMode:(GLTrackingMode)trackingMode {
    GLTrackingMode previousTrackingMode = self.trackingMode;
    if(previousTrackingMode != trackingMode) {
        [[NSUserDefaults standardUserDefaults] setInteger:trackingMode forKey:GLSignificantLocationModeDefaultsName];
        [self resetStationaryAnchors];
        [self requestTrackingReconfiguration];
    }
}

- (BOOL)visitTrackingEnabled {
    if([self defaultsKeyExists:GLVisitTrackingEnabledDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLVisitTrackingEnabledDefaultsName];
    } else {
        return NO;
    }
}
- (void)setVisitTrackingEnabled:(BOOL)enabled {
    BOOL previousEnabled = self.visitTrackingEnabled;
    if(previousEnabled != enabled) {
        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:GLVisitTrackingEnabledDefaultsName];
        [self requestTrackingReconfiguration];
    }
}

- (GLLoggingMode)loggingMode {
    if([self defaultsKeyExists:GLLoggingModeDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLLoggingModeDefaultsName];
    } else {
        return kGLLoggingModeAllData;
    }
}
- (void)setLoggingMode:(GLLoggingMode)loggingMode {
    GLLoggingMode previousLoggingMode = self.loggingMode;
    if(previousLoggingMode != loggingMode) {
        [[NSUserDefaults standardUserDefaults] setInteger:loggingMode forKey:GLLoggingModeDefaultsName];
        [self setupHTTPClient];
    }
}

- (GLLoggingMode)loggingModeDuringTrip {
    if([self defaultsKeyExists:GLTripLoggingModeDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLTripLoggingModeDefaultsName];
    } else {
        return kGLLoggingModeAllData;
    }
}
- (void)setLoggingModeDuringTrip:(GLLoggingMode)loggingMode {
    [[NSUserDefaults standardUserDefaults] setInteger:loggingMode forKey:GLTripLoggingModeDefaultsName];
}

- (GLLoggingMode)loggingModeCurrentValue {
    if(self.tripInProgress) {
        return self.loggingModeDuringTrip;
    } else {
        return self.loggingMode;
    }
}

- (BOOL)showBackgroundLocationIndicator {
    if([self defaultsKeyExists:GLBackgroundIndicatorDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLBackgroundIndicatorDefaultsName];
    } else {
        return NO;
    }
}
- (void)setShowBackgroundLocationIndicator:(BOOL)mode {
    BOOL previousMode = self.showBackgroundLocationIndicator;
    if(previousMode != mode) {
        [[NSUserDefaults standardUserDefaults] setBool:mode forKey:GLBackgroundIndicatorDefaultsName];
        if(self.trackingEnabled && !self.tripInProgress) {
            self.locationManager.showsBackgroundLocationIndicator = mode;
            [self updateLocationEngine];
        }
    }
}

- (BOOL)showBackgroundLocationIndicatorDuringTrip {
    if([self defaultsKeyExists:GLTripBackgroundIndicatorDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLTripBackgroundIndicatorDefaultsName];
    } else {
        return YES;
    }
}
- (void)setShowBackgroundLocationIndicatorDuringTrip:(BOOL)mode {
    BOOL previousMode = self.showBackgroundLocationIndicatorDuringTrip;
    if(previousMode != mode) {
        [[NSUserDefaults standardUserDefaults] setBool:mode forKey:GLTripBackgroundIndicatorDefaultsName];
        if(self.tripInProgress) {
            self.locationManager.showsBackgroundLocationIndicator = mode;
            [self updateLocationEngine];
        }
    }
}

- (CLActivityType)activityType {
    if([self defaultsKeyExists:GLActivityTypeDefaultsName]) {
        // Map back to CLActivityType constants
        long activityInt = [[NSUserDefaults standardUserDefaults] integerForKey:GLActivityTypeDefaultsName];
        CLActivityType activityType;
        switch(activityInt) {
            case 1:
                activityType = CLActivityTypeOther;
                break;
            case 2:
                activityType = CLActivityTypeAutomotiveNavigation;
                break;
            case 3:
                activityType = CLActivityTypeFitness;
                break;
            case 4:
                activityType = CLActivityTypeOtherNavigation;
                break;
            case 5:
                if (@available(iOS 12.0, *)) {
                    activityType = CLActivityTypeAirborne;
                } else {
                    activityType = CLActivityTypeOther;
                }
                break;
            default:
                activityType = CLActivityTypeOther;
                if(@available(iOS 27.0, *)) {
                    if(activityInt == 6) activityType = CLActivityTypeMaritime;
                }
                break;
        }
        return activityType;
    } else {
        return CLActivityTypeOther;
    }
}
- (void)setActivityType:(CLActivityType)activityType {
    // Store these as integers, in the same order as the UI control
    int activityInt;
    switch(activityType) {
        case CLActivityTypeOther:
            activityInt = 1;
            break;
        case CLActivityTypeAutomotiveNavigation:
            activityInt = 2;
            break;
        case CLActivityTypeFitness:
            activityInt = 3;
            break;
        case CLActivityTypeOtherNavigation:
            activityInt = 4;
            break;
        case CLActivityTypeAirborne:
            if (@available(iOS 12.0, *)) {
                activityInt = 5;
            } else {
                activityInt = 1;
            }
            break;
        default:
            activityInt = 1;
            if(@available(iOS 27.0, *)) {
                if(activityType == CLActivityTypeMaritime) activityInt = 6;
            }
            break;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:activityInt forKey:GLActivityTypeDefaultsName];
    if(!self.tripInProgress) [self requestTrackingReconfiguration];
}

- (CLActivityType)activityTypeDuringTrip {
    if([self defaultsKeyExists:GLTripActivityTypeDefaultsName]) {
        // Map back to CLActivityType constants
        long activityInt = [[NSUserDefaults standardUserDefaults] integerForKey:GLTripActivityTypeDefaultsName];
        CLActivityType activityType;
        switch(activityInt) {
            case 1:
                activityType = CLActivityTypeOther;
                break;
            case 2:
                activityType = CLActivityTypeAutomotiveNavigation;
                break;
            case 3:
                activityType = CLActivityTypeFitness;
                break;
            case 4:
                activityType = CLActivityTypeOtherNavigation;
                break;
            case 5:
                if (@available(iOS 12.0, *)) {
                    activityType = CLActivityTypeAirborne;
                } else {
                    activityType = CLActivityTypeOther;
                }
                break;
            default:
                activityType = CLActivityTypeOther;
                if(@available(iOS 27.0, *)) {
                    if(activityInt == 6) activityType = CLActivityTypeMaritime;
                }
                break;
        }
        return activityType;
    } else {
        return CLActivityTypeOther;
    }
}
- (void)setActivityTypeDuringTrip:(CLActivityType)activityType {
    // Store these as integers, in the same order as the UI control
    int activityInt;
    switch(activityType) {
        case CLActivityTypeOther:
            activityInt = 1;
            break;
        case CLActivityTypeAutomotiveNavigation:
            activityInt = 2;
            break;
        case CLActivityTypeFitness:
            activityInt = 3;
            break;
        case CLActivityTypeOtherNavigation:
            activityInt = 4;
            break;
        case CLActivityTypeAirborne:
            if (@available(iOS 12.0, *)) {
                activityInt = 5;
            } else {
                activityInt = 1;
            }
            break;
        default:
            activityInt = 1;
            if(@available(iOS 27.0, *)) {
                if(activityType == CLActivityTypeMaritime) activityInt = 6;
            }
            break;
    }
    [[NSUserDefaults standardUserDefaults] setInteger:activityInt forKey:GLTripActivityTypeDefaultsName];
    if(self.tripInProgress) [self requestTrackingReconfiguration];
}

- (CLLocationAccuracy)desiredAccuracy {
    if([self defaultsKeyExists:GLDesiredAccuracyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLDesiredAccuracyDefaultsName];
    } else {
        return kCLLocationAccuracyHundredMeters;
    }
}
- (void)setDesiredAccuracy:(CLLocationAccuracy)desiredAccuracy {
    [[NSUserDefaults standardUserDefaults] setDouble:desiredAccuracy forKey:GLDesiredAccuracyDefaultsName];
    if(!self.tripInProgress) {
        [self requestTrackingReconfiguration];
    }
}

- (CLLocationAccuracy)desiredAccuracyDuringTrip {
    if([self defaultsKeyExists:GLTripDesiredAccuracyDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] doubleForKey:GLTripDesiredAccuracyDefaultsName];
    } else {
        return kCLLocationAccuracyHundredMeters;
    }
}
- (void)setDesiredAccuracyDuringTrip:(CLLocationAccuracy)desiredAccuracy {
    [[NSUserDefaults standardUserDefaults] setDouble:desiredAccuracy forKey:GLTripDesiredAccuracyDefaultsName];
    if(self.tripInProgress) {
        [self requestTrackingReconfiguration];
    }
}

- (int)pointsPerBatch {
    if([self defaultsKeyExists:GLPointsPerBatchDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLPointsPerBatchDefaultsName];
    } else {
        return 200;
    }
}
- (void)setPointsPerBatch:(int)points {
    [[NSUserDefaults standardUserDefaults] setInteger:MAX(1, points) forKey:GLPointsPerBatchDefaultsName];
}

- (int)pointsPerBatchDuringTrip {
    if([self defaultsKeyExists:GLTripPointsPerBatchDefaultsName]) {
        return (int)[[NSUserDefaults standardUserDefaults] integerForKey:GLTripPointsPerBatchDefaultsName];
    } else {
        return 200;
    }
}
- (void)setPointsPerBatchDuringTrip:(int)points {
    [[NSUserDefaults standardUserDefaults] setInteger:MAX(1, points) forKey:GLTripPointsPerBatchDefaultsName];
}

- (int)pointsPerBatchCurrentValue {
    if(self.tripInProgress) {
        return self.pointsPerBatchDuringTrip;
    } else {
        return self.pointsPerBatch;
    }
}

#pragma mark GLManager

- (NSNumber *)sendingInterval {
    if(_sendingInterval)
        return _sendingInterval;
    
    _sendingInterval = (NSNumber *)[[NSUserDefaults standardUserDefaults] valueForKey:GLSendIntervalDefaultsName];
    if(_sendingInterval == nil) {
        _sendingInterval = [NSNumber numberWithInteger:300];
    }
    return _sendingInterval;
}

- (void)setSendingInterval:(NSNumber *)newValue {
    [[NSUserDefaults standardUserDefaults] setValue:newValue forKey:GLSendIntervalDefaultsName];
    _sendingInterval = newValue;
}

- (NSDate *)lastSentDate {
    return (NSDate *)[[NSUserDefaults standardUserDefaults] objectForKey:GLLastSentDateDefaultsName];
}

- (void)setLastSentDate:(NSDate *)lastSentDate {
    [[NSUserDefaults standardUserDefaults] setObject:lastSentDate forKey:GLLastSentDateDefaultsName];
}

#pragma mark - CLLocationManager Delegate Methods

- (void)locationManager:(CLLocationManager *)manager didVisit:(CLVisit *)visit {

    if(!self.trackingEnabled) return;
    if(self.visitTrackingEnabled) {
        [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];
        [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
            NSString *timestamp = [GLManager iso8601DateStringFromDate:[NSDate date]];
            NSDictionary *update = @{
                                      @"type": @"Feature",
                                      @"geometry": @{
                                              @"type": @"Point",
                                              @"coordinates": @[
                                                      [NSNumber numberWithDouble:visit.coordinate.longitude],
                                                      [NSNumber numberWithDouble:visit.coordinate.latitude]
                                                      ]
                                              },
                                      @"properties": [NSMutableDictionary dictionaryWithDictionary:@{
                                              @"timestamp": timestamp,
                                              @"action": @"visit",
                                              @"arrival_date": ([visit.arrivalDate isEqualToDate:[NSDate distantPast]] ? [NSNull null] : [GLManager iso8601DateStringFromDate:visit.arrivalDate]),
                                              @"departure_date": ([visit.departureDate isEqualToDate:[NSDate distantFuture]] ? [NSNull null] : [GLManager iso8601DateStringFromDate:visit.departureDate]),
                                              @"horizontal_accuracy": [NSNumber numberWithInt:visit.horizontalAccuracy],
                                              }]
                                    };
            [self addMetadataToUpdate:update];
            [accessor setDictionary:update forKey:[NSString stringWithFormat:@"%@-visit-%@", timestamp, NSUUID.UUID.UUIDString]];
        }];

    }
    
    // If a trip is active, ask if they would like to end the trip. Ask to End Trip When Stopped
    // sends its own prompt for the same stop.
    if(self.tripInProgress && ![[NSUserDefaults standardUserDefaults] boolForKey:GLTripAskToEndWhenStoppedDefaultsName]) {
        [self askToEndTrip];
    }
    
    [self reconcileLocationHealth];
    [self sendQueueIfTimeElapsed];
}

- (BOOL)deleteAllData {
    if(self.sendInProgress || self.batchInProgress) return NO;
    BOOL committed = [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
        [accessor deleteAllData];
    }];
    if(!committed) return NO;
    self.uploadPending = NO;
    self.drainAll = NO;
    self.userDrain = NO;
    [self resetUploadRetry];
    [self endSendBackgroundTask];
    [self numberOfLocationsInQueue:^(long num) {}];
    [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];
    return YES;
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray *)locations {
    [self processLocations:locations];
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    [WhereWolfLocationEngine.shared recordFailure:error];
}

- (NSDate *)queuedLocationDate:(NSDictionary *)record {
    if([record[@"_type"] isEqual:@"location"] && [record[@"tst"] isKindOfClass:NSNumber.class]) {
        return [NSDate dateWithTimeIntervalSince1970:[record[@"tst"] doubleValue]];
    }
    NSDictionary *properties = record[@"properties"];
    if(![properties isKindOfClass:NSDictionary.class] || properties[@"action"] || properties[@"type"]) return nil;
    if(![record[@"type"] isEqual:@"Feature"] || ![properties[@"timestamp"] isKindOfClass:NSString.class]) return nil;
    return [[[NSISO8601DateFormatter alloc] init] dateFromString:properties[@"timestamp"]];
}

- (BOOL)isValidLocation:(CLLocation *)location {
    return CLLocationCoordinate2DIsValid(location.coordinate) && isfinite(location.horizontalAccuracy)
        && location.horizontalAccuracy >= 0 && isfinite(location.timestamp.timeIntervalSince1970)
        && location.timestamp.timeIntervalSinceNow <= 0;
}

- (BOOL)location:(CLLocation *)location equalsFix:(CLLocation *)other {
    return other && [location.timestamp isEqualToDate:other.timestamp]
        && location.coordinate.latitude == other.coordinate.latitude && location.coordinate.longitude == other.coordinate.longitude
        && location.horizontalAccuracy == other.horizontalAccuracy && location.verticalAccuracy == other.verticalAccuracy
        && location.altitude == other.altitude && location.speed == other.speed && location.course == other.course
        && location.speedAccuracy == other.speedAccuracy && location.courseAccuracy == other.courseAccuracy;
}

- (void)resetStationaryAnchors {
    self.inStationaryStop = NO;
    self.lastStationaryPointDate = nil;
    self.lastMovementLocation = nil;
    self.lastLocationMovedBeyondStopThreshold = nil;
    self.lastTimeMovedBeyondStopThreshold = nil;
    self.radiusPauseDate = nil;
    self.didPauseByRadius = NO;
}

- (BOOL)observeMovementLocation:(CLLocation *)location {
    if(self.tripInProgress || !self.stopsAutomaticallyActive || ![self isValidLocation:location]) return NO;
    if(fabs(location.timestamp.timeIntervalSinceNow) > 20) return NO;
    if(self.didPauseByRadius) {
        // Callbacks queued before the stop must not restart acquisition.
        if(self.radiusPauseDate && [location.timestamp compare:self.radiusPauseDate] != NSOrderedDescending) return NO;
        [self resetStationaryAnchors];
        [self runEngineStandardUpdates];
        [self notify:@"Location updates resumed." withTitle:@"Resumed"];
    }
    if(self.lastMovementLocation && [location.timestamp compare:self.lastMovementLocation.timestamp] != NSOrderedDescending) return NO;
    self.lastMovementLocation = location;
    if(!self.lastTimeMovedBeyondStopThreshold || location.horizontalAccuracy > self.stopsAutomaticallyRadius
       || location.speed >= 0.5
       || [self.lastLocationMovedBeyondStopThreshold distanceFromLocation:location] > self.stopsAutomaticallyRadius) {
        self.lastLocationMovedBeyondStopThreshold = location;
        self.lastTimeMovedBeyondStopThreshold = NSDate.date;
    }
    return YES;
}

- (void)processLocations:(NSArray *)locations {
    [[WhereWolfBackgroundRuntime shared] checkAudioFromLocation];
    if(!self.trackingEnabled || (!self.tripInProgress && self.trackingMode == kGLTrackingModeOff)) {
        return;
    }
    [self reconcileLocationHealth];
    [self.locationHealthPolicy observeLocations:locations uptime:[self locationHealthUptime] date:NSDate.date];
    if(locations.count == 0) { [self evaluateLocationHealth]; return; }
    GLLocationSaveAllowance *allowance = [self newLocationSaveAllowance];
    BOOL stored = NO;
    @try {
        stored = [self processLocationBatch:locations];
    } @finally {
        if(stored) {
            dispatch_group_t writes = dispatch_group_create();
            dispatch_group_enter(writes);
            [RecentLocationHistory finishPendingWrites:^{ dispatch_group_leave(writes); }];
            dispatch_group_enter(writes);
            [[HealthTripRecorder shared] finishPendingWrites:^{ dispatch_group_leave(writes); }];
            dispatch_group_notify(writes, dispatch_get_main_queue(), ^{ [allowance finish]; });
        } else {
            [allowance finish];
        }
    }
    [self evaluateLocationHealth];
}

- (BOOL)processLocationBatch:(NSArray *)locations {

    BOOL movementFix = NO;
    BOOL usefulFix = NO;
    NSUInteger saved = 0;
    NSMutableDictionary *rejected = self.locationHealthPolicy.expected ? [NSMutableDictionary dictionary] : nil;
    NSDictionary *options = self.advancedTrackingOptions;
    self.batchWifiInfo = [self wifiNetworkInfoForBatch];
    NSDictionary *place = [self currentWifiPlaceForLocations:locations networkInfo:self.batchWifiInfo];
    CLLocation *current = locations.lastObject;
    // Only a fresh fix can start or end a match; a delayed batch leaves it as it was.
    if(current && [self isValidLocation:current] && fabs(current.timestamp.timeIntervalSinceNow) <= 20) self.wifiPlaceMatchID = place[@"id"];
    NSMutableArray *usable = [NSMutableArray arrayWithCapacity:locations.count];
    for(CLLocation *location in locations) {
        if(![self isValidLocation:location]) { GLCountLocationRejection(rejected, @"invalid"); continue; }
        if(!self.lastReceivedLocation || [location.timestamp compare:self.lastReceivedLocation.timestamp] == NSOrderedDescending) {
            self.lastReceivedLocation = location;
        }
        if(fabs(location.timestamp.timeIntervalSinceNow) <= 20) {
            usefulFix = YES;
            [WhereWolfLocationEngine.shared recordStandardLocation];
        }
        // Inside a matched place only the current fix survives, to become the place's point.
        if(place && GLWifiPlaceContainsFix(place, location) && ([place[@"record"] isEqual:@"nothing"] || location != current)) {
            GLCountLocationRejection(rejected, @"wifi_place");
            continue;
        }
        if([options[@"reject_jumps"] boolValue]) {
            if(self.discardPointsOutsideAccuracy > 0 && location.horizontalAccuracy > self.discardPointsOutsideAccuracy) { GLCountLocationRejection(rejected, @"accuracy"); continue; }
            if(self.qualityObservation && [location.timestamp compare:self.qualityObservation.timestamp] != NSOrderedDescending) { GLCountLocationRejection(rejected, @"order"); continue; }
            if(![self.qualityPolicy acceptLocation:location relativeTo:self.qualityObservation maximumSpeed:[options[@"maximum_speed"] doubleValue]]) {
                self.rejectedJumpCount++;
                GLCountLocationRejection(rejected, @"jump");
                continue;
            }
            self.qualityObservation = location;
        }
        [usable addObject:location];
        if((self.engineStationary || (self.shouldUseLiveUpdates && [WhereWolfLocationEngine.shared.state isEqualToString:@"failed"]))
           && !self.tripInProgress && self.trackingMode == kGLTrackingModeStandardAndSignificant
           && [self isValidLocation:location] && fabs(location.timestamp.timeIntervalSinceNow) <= 20) {
            self.engineStationary = NO;
            [self runEngineStandardUpdates];
        }
        if([self observeMovementLocation:location]) movementFix = YES;
        if(self.adaptiveEnabled && !self.didPauseByRadius) {
            BOOL changed = [self.adaptivePolicy observeLocation:location motion:[self movementAtDate:location.timestamp]
                now:NSDate.date dwell:[options[@"adaptive_dwell"] doubleValue] radius:[options[@"adaptive_radius"] doubleValue]
                maxAccuracy:[options[@"adaptive_max_error"] doubleValue] requireMotion:[options[@"adaptive_require_motion"] boolValue]];
            if(changed) {
                [self updateAdaptiveRegion];
                [self requestTrackingReconfiguration];
                [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
            }
        }
    }

    [self rememberWifiNetworkInfo:self.batchWifiInfo location:locations.lastObject date:NSDate.date];
    locations = [place[@"record"] isEqual:@"nothing"] ? usable : [self locationsByApplyingWifiPlace:usable networkInfo:self.batchWifiInfo];

    NSString *activityType = @"";
    switch(self.tripInProgress ? self.activityTypeDuringTrip : self.activityType) {
        case CLActivityTypeOther:
            activityType = @"other";
            break;
        case CLActivityTypeAutomotiveNavigation:
            activityType = @"automotive_navigation";
            break;
        case CLActivityTypeFitness:
            activityType = @"fitness";
            break;
        case CLActivityTypeOtherNavigation:
            activityType = @"other_navigation";
            break;
        case CLActivityTypeAirborne:
            activityType = @"airborne";
            break;
        default:
            activityType = @"other";
            if(@available(iOS 27.0, *)) {
                CLActivityType selected = self.tripInProgress ? self.activityTypeDuringTrip : self.activityType;
                if(selected == CLActivityTypeMaritime) activityType = @"maritime";
            }
            break;
    }
    
    CLLocation *lastLocationSeen = self.lastLocation; // Grab the last known location from the previous batch
    
    int startIndex = 0;
    if(self.loggingModeCurrentValue == kGLLoggingModeOnlyLatest) {
        // Only grab the latest point in this batch
        startIndex = MAX(0, ((int)locations.count) - 1);
    }
    
    BOOL didAddData = NO;
    
    for(int i=startIndex; i<locations.count; i++) {
        CLLocation *loc = locations[i];
        CLLocation *rawLocation = usable[i];
        if(![self isValidLocation:loc]) { GLCountLocationRejection(rejected, @"invalid"); continue; }
        if([self location:loc equalsFix:lastLocationSeen]) { GLCountLocationRejection(rejected, @"duplicate"); continue; }
        if(lastLocationSeen && [loc.timestamp compare:lastLocationSeen.timestamp] == NSOrderedAscending) { GLCountLocationRejection(rejected, @"order"); continue; }
        if(fabs(loc.timestamp.timeIntervalSinceNow) <= 20) {
            usefulFix = YES;
            [WhereWolfLocationEngine.shared recordStandardLocation];
        }
        // A place saves its point on arrival and then once per heartbeat, whatever the point filters
        // allow, so a stay there still shows in history and Coverage.
        BOOL placePoint = loc != rawLocation;
        if(placePoint && lastLocationSeen && lastLocationSeen.coordinate.latitude == loc.coordinate.latitude
           && lastLocationSeen.coordinate.longitude == loc.coordinate.longitude
           && [loc.timestamp timeIntervalSinceDate:lastLocationSeen.timestamp] < GLWifiPlaceHeartbeatInterval) {
            GLCountLocationRejection(rejected, @"wifi_place");
            continue;
        }

        BOOL stationaryFilter = self.discardPointsWhileStationaryCurrentValue && [self.motionAuthorizationStatus isEqual:@"Allowed"];
        if(!stationaryFilter || [self deviceIsMovingAtDate:rawLocation.timestamp]) self.inStationaryStop = NO;
        BOOL stationaryPoint = stationaryFilter && [self deviceIsStationaryAtDate:rawLocation.timestamp];
        BOOL stationaryHeartbeat = stationaryFilter && self.inStationaryStop && self.lastStationaryPointDate
            && [rawLocation.timestamp timeIntervalSinceDate:self.lastStationaryPointDate] >= 3600;
        if(stationaryFilter && self.inStationaryStop && !stationaryHeartbeat) { GLCountLocationRejection(rejected, @"stationary"); continue; }
        if(self.discardPointsWithoutGPSCurrentValue && rawLocation.verticalAccuracy < 0 && rawLocation.speed < 0) { GLCountLocationRejection(rejected, @"gps"); continue; }
        if(!placePoint && !(stationaryPoint && !self.inStationaryStop) && !stationaryHeartbeat &&
           ![GLPointSelection acceptLocation:loc previous:lastLocationSeen anyLimit:[options[@"any_threshold"] boolValue]
            distance:self.discardPointsWithinDistanceCurrentValue seconds:self.discardPointsWithinSecondsCurrentValue
            turn:[options[@"turn_degrees"] doubleValue]]) { GLCountLocationRejection(rejected, @"threshold"); continue; }

        if(self.discardPointsOutsideAccuracy > 0) {
            if(loc.horizontalAccuracy > self.discardPointsOutsideAccuracy) {
                GLCountLocationRejection(rejected, @"accuracy");
                continue;
            }
        }
        
        NSString *timestamp = [GLManager iso8601DateStringFromDate:loc.timestamp];
        NSDictionary *update;
        if(self.usesOwntracksFormat) {
            update = [self owntracksDictionaryFromLocation:loc];
        } else {
            update = [self currentDictionaryFromLocation:loc];
            NSMutableDictionary *properties = [update objectForKey:@"properties"];
            if(self.includeTrackingStats) {
                [properties setValue:[NSNumber numberWithBool:self.locationManager.pausesLocationUpdatesAutomatically] forKey:@"pauses"];
                [properties setValue:activityType forKey:@"activity"];
                [properties setValue:[NSNumber numberWithDouble:self.locationManager.desiredAccuracy] forKey:@"desired_accuracy"];
                [properties setValue:[NSNumber numberWithInt:self.trackingMode] forKey:@"tracking_mode"];
                [properties setValue:[NSNumber numberWithLong:locations.count] forKey:@"locations_in_payload"];
            }
            // Add the trip start time as trip_id in the location update
            if(self.tripInProgress) {
                [properties setValue:[GLManager iso8601DateStringFromDate:self.currentTripStart] forKey:@"trip_id"];
                [properties setValue:[GLTripModeStore serverValueForModeID:self.currentTripMode] forKey:@"trip_mode"];
            }
        }

        // Queue the point in the database
        BOOL committed = [self.db accessCollection:GLLocationQueueName withBlock:^(id<LOLDatabaseAccessor> accessor) {
            if(self.loggingModeCurrentValue == kGLLoggingModeOnlyLatest) {
                NSMutableArray *older = [NSMutableArray array];
                [accessor enumerateKeysAndObjectsUsingBlock:^BOOL(NSString *key, NSDictionary *record) {
                    NSDictionary *metadata = [record[@"properties"] isKindOfClass:NSDictionary.class] ? record[@"properties"] : nil;
                    if([metadata[@"source"] isEqual:@"healthkit"]) return NO;
                    NSDate *date = [self queuedLocationDate:record];
                    if(date && [date compare:loc.timestamp] != NSOrderedDescending) [older addObject:key];
                    return NO;
                }];
                for(NSString *key in older) [accessor removeDictionaryForKey:key];
            }
            [accessor setDictionary:update forKey:[NSString stringWithFormat:@"%@-%@", timestamp, NSUUID.UUID.UUIDString]];
        }];
        if(!committed) {
            GLCountLocationRejection(rejected, @"storage");
            NSLog(@"Location could not be queued: %@", self.db.lastError.localizedDescription);
            continue;
        }
        [RecentLocationHistory recordUpdate:update];
        if(stationaryFilter && (stationaryPoint || self.inStationaryStop)) {
            self.inStationaryStop = YES;
            self.lastStationaryPointDate = loc.timestamp;
        }
        didAddData = YES;
        saved++;
        
        if(self.tripInProgress && [loc.timestamp timeIntervalSinceDate:self.currentTripStart] >= 0  // only if the location is newer than the trip start
           && loc.horizontalAccuracy <= 200 // only if the location is accurate enough
           ) {

            BOOL tripCommitted = [self appendTripLocation:loc];
            if(tripCommitted && _storeNextLocationAsTripStart) {
                [[NSUserDefaults standardUserDefaults] setObject:update forKey:GLTripStartLocationDefaultsName];
                self.tripStartLocationDictionary = update;
                _storeNextLocationAsTripStart = NO;
            }
            
        }

        self.lastLocation = loc;
        lastLocationSeen = loc;
        self.lastLocationDictionary = [self currentDictionaryFromLocation:self.lastLocation];
        [[HealthTripRecorder shared] recordAcceptedLocation:rawLocation];

    }
    
    if(movementFix && !self.didPauseByRadius && self.lastTimeMovedBeyondStopThreshold
       && -self.lastTimeMovedBeyondStopThreshold.timeIntervalSinceNow > self.stopsAutomaticallyAfterSeconds) {
        [[WhereWolfLocationEngine shared] stopLiveUpdates];
        [[WhereWolfLocationEngine shared] endBackgroundSession];
        [self.locationManager stopUpdatingLocation];
        self.runningConfiguration = nil;
        [self.locationManager stopUpdatingHeading];
        [self.locationManager startMonitoringSignificantLocationChanges];

        self.didPauseByRadius = YES;
        self.radiusPauseDate = NSDate.date;
        [self.adaptivePolicy reset];
        [self removeAdaptiveRegion];
        [WhereWolfLocationEngine.shared recordStationary:YES];
        [self cancelLocalNotification];
        
        NSLog(@"Stopping loc updates");
        [self notify:@"Location updates paused. Waiting for significant movement." withTitle:@"Paused"];
    }

    if(didAddData) {
        if(self.tripLiveActivityEnabled && self.tripInProgress && self.trackingEnabled) {
            [[TripLiveActivityController shared] updateWithMode:self.currentTripMode distance:self.currentTripDistance
                speed:self.lastLocation.speed force:NO];
        }
        [self numberOfLocationsInQueue:^(long num) {}];
        [[NSNotificationCenter defaultCenter] postNotificationName:GLNewDataNotification object:self];
    }

    [self sendQueueIfTimeElapsed];
    
    if(usefulFix) {
        self.engineStationary = NO;
        [self scheduleLocalNotification];
    } else if(!self.reminderEligible) {
        [self cancelLocalNotification];
    }
    self.batchWifiInfo = nil;
    [self.locationHealthPolicy recordSaved:saved rejected:rejected uptime:[self locationHealthUptime] date:NSDate.date];
    [self reconcileLocationHealth];
    return didAddData;
}

- (void)addMetadataToUpdate:(NSDictionary *) update {
    [self addMetadataToUpdate:update rememberWifi:YES];
}

- (void)addMetadataToUpdate:(NSDictionary *)update rememberWifi:(BOOL)remember {
    NSMutableDictionary *properties = [update objectForKey:@"properties"];
    if(_deviceId && _deviceId.length > 0) {
        [properties setValue:_deviceId forKey:@"device_id"];
    }
    NSDictionary *wifiInfo = self.batchWifiInfo ?: [GLManager currentWifiNetworkInfo];
    if(remember && !self.batchWifiInfo) [self rememberWifiNetworkInfo:wifiInfo];
    [properties setValue:wifiInfo[@"SSID"] forKey:@"wifi"];
    [properties setValue:[self currentBatteryState] forKey:@"battery_state"];
    [properties setValue:[self currentBatteryLevel] forKey:@"battery_level"];
    if([[NSUserDefaults standardUserDefaults] boolForKey:GLIncludeUniqueIdDefaultsName]) {
        NSString *uniqueId = [UIDevice currentDevice].identifierForVendor.UUIDString;
        [properties setValue:uniqueId forKey:@"unique_id"];
    }
}

- (NSDictionary *)currentDictionaryFromLocation:(CLLocation *)loc {
    return [self currentDictionaryFromLocation:loc rememberWifi:YES];
}

- (NSDictionary *)currentDictionaryFromLocation:(CLLocation *)loc rememberWifi:(BOOL)remember {
    NSString *timestamp = [GLManager iso8601DateStringFromDate:loc.timestamp];
    NSDictionary *update = @{
             @"type": @"Feature",
             @"geometry": @{
                     @"type": @"Point",
                     @"coordinates": @[
                             [NSNumber numberWithDouble:((int)(loc.coordinate.longitude * 10000000)) / 10000000.0],
                             [NSNumber numberWithDouble:((int)(loc.coordinate.latitude * 10000000)) / 10000000.0]
                             ]
                     },
             @"properties": [NSMutableDictionary dictionaryWithDictionary:@{
                     @"timestamp": timestamp,
                     @"altitude": [NSNumber numberWithDouble:((int)(loc.altitude * 1000)) / 1000.0],
                     @"speed": [NSNumber numberWithDouble:((int)(loc.speed * 1000)) / 1000.0],
                     @"course": [NSNumber numberWithDouble:((int)(loc.course * 1000)) / 1000.0],
                     @"horizontal_accuracy": [NSNumber numberWithDouble:((int)(loc.horizontalAccuracy * 1000)) / 1000.0],
                     @"vertical_accuracy": [NSNumber numberWithDouble:((int)(loc.verticalAccuracy * 1000)) / 1000.0],
                     @"speed_accuracy": [NSNumber numberWithDouble:((int)(loc.speedAccuracy * 100)) / 100.0],
                     @"course_accuracy": [NSNumber numberWithDouble:((int)(loc.courseAccuracy * 100)) / 100.0],
                     @"motion": [self motionArrayForDate:loc.timestamp],
                     }]
             };
    if(self.tripInProgress) [update[@"properties"] setObject:[GLTripModeStore serverValueForModeID:self.currentTripMode] forKey:@"trip_mode"];
    [self addMetadataToUpdate:update rememberWifi:remember];
    return update;
}

- (NSDictionary *)owntracksDictionaryFromLocation:(CLLocation *)loc {
    NSMutableDictionary *update = [NSMutableDictionary dictionaryWithDictionary:@{
        @"_type": @"location",
        @"lat": [NSNumber numberWithDouble:((int)(loc.coordinate.latitude * 10000000)) / 10000000.0],
        @"lon": [NSNumber numberWithDouble:((int)(loc.coordinate.longitude * 10000000)) / 10000000.0],
        @"tst": [NSNumber numberWithDouble:loc.timestamp.timeIntervalSince1970],
        @"acc": [NSNumber numberWithInt:(int)round(loc.horizontalAccuracy)],
        @"batt": @((int)round(self.currentBatteryLevel.doubleValue * 100)),
    }];
    if(_deviceId && _deviceId.length > 0) {
        NSString *topic = [NSString stringWithFormat:@"owntracks/%@", _deviceId];
        [update setValue:topic forKey:@"topic"];
    }
    return update;
}

- (NSArray *)motionArrayFromLastMotion {
    NSMutableArray *motion = [[NSMutableArray alloc] init];
    CMMotionActivity *motionActivity = [GLManager sharedManager].lastMotion;
    if(motionActivity.walking)
        [motion addObject:@"walking"];
    if(motionActivity.running)
        [motion addObject:@"running"];
    if(motionActivity.cycling)
        [motion addObject:@"cycling"];
    if(motionActivity.automotive)
        [motion addObject:@"driving"];
    if(motionActivity.stationary)
        [motion addObject:@"stationary"];
    return [NSArray arrayWithArray:motion];
}

- (void)locationManagerDidPauseLocationUpdates:(CLLocationManager *)manager {
    if(!self.trackingEnabled) return;
    self.engineStationary = YES;
    self.runningConfiguration = nil;
    [self reconcileLocationHealth];
    [WhereWolfLocationEngine.shared recordStationary:YES];
    [self cancelLocalNotification];
    [self logAction:@"paused_location_updates"];
    
    [self notify:@"Location updates paused" withTitle:@"Paused"];
    
    // Create an exit geofence to help it resume automatically
    if(self.resumesAfterDistance > 0 && self.lastLocation) {
        CLCircularRegion *region = [[CLCircularRegion alloc] initWithCenter:self.lastLocation.coordinate radius:self.resumesAfterDistance identifier:@"resume-from-pause"];
        region.notifyOnEntry = NO;
        region.notifyOnExit = YES;
        [self.locationManager startMonitoringForRegion:region];
    }
    
    // Send the queue now to flush all remaining points
    [self sendQueueIfNotInProgress];
    
    // If a trip was in progress, stop it now
    if(self.tripInProgress) {
        [self endTripFromAutopause:YES];
    }
}

-(void)locationManager:(CLLocationManager *)manager didExitRegion:(CLRegion *)region {
    if([region.identifier isEqual:GLAdaptiveRegionName]) {
        [self.locationManager stopMonitoringForRegion:region];
        if(self.trackingEnabled && self.adaptiveEnabled && !self.didPauseByRadius) {
            [self.adaptivePolicy movementDetected];
            [self requestTrackingReconfiguration];
            [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
        }
        return;
    }
    if(![region.identifier isEqualToString:@"resume-from-pause"]) return;
    [self.locationManager stopMonitoringForRegion:region];
    if(!self.trackingEnabled || ![[NSUserDefaults standardUserDefaults] boolForKey:GLTrackingStateDefaultsName]) return;
    NSLog(@"Did exit region");
    [self logAction:@"exited_pause_region"];
    [self notify:@"Starting updates from exiting the geofence" withTitle:@"Resumed"];
    [self.locationManager stopMonitoringForRegion:region];
    [self enableTracking];
}

- (void)locationManagerDidResumeLocationUpdates:(CLLocationManager *)manager {
    if(!self.trackingEnabled) return;
    self.engineStationary = NO;
    [self reconcileLocationHealth];
    [WhereWolfLocationEngine.shared recordStationary:NO];
    for(CLRegion *region in self.locationManager.monitoredRegions) {
        if([region.identifier isEqualToString:@"resume-from-pause"]) [self.locationManager stopMonitoringForRegion:region];
    }
    [self scheduleLocalNotification];
    [self logAction:@"resumed_location_updates"];
    [self notify:@"Location updates resumed" withTitle:@"Resumed"];
}

#pragma mark - AppDelegate Methods

- (void)applicationDidEnterBackground {
    // [self logAction:@"did_enter_background"];
}

- (void)applicationWillTerminate {
    [self logAction:@"will_terminate"];
}

- (void)applicationWillResignActive {
    // [self logAction:@"will_resign_active"];
}

#pragma mark - Notifications

- (BOOL)notificationsEnabled {
    if([self defaultsKeyExists:GLNotificationsEnabledDefaultsName]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:GLNotificationsEnabledDefaultsName];
    } else {
        return NO;
    }
}
- (BOOL)problemNotificationsOnly {
    return [NSUserDefaults.standardUserDefaults boolForKey:GLProblemNotificationsOnlyDefaultsName];
}
- (void)setProblemNotificationsOnly:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:GLProblemNotificationsOnlyDefaultsName];
}
- (void)setNotificationsEnabled:(BOOL)enabled {
    self.notificationPermissionRevision++;
    if(self.settingsChangeDepth > 0) {
        [NSUserDefaults.standardUserDefaults setBool:enabled forKey:GLNotificationsEnabledDefaultsName];
        if(!enabled) [self cancelLocalNotification];
        return;
    }
    if(enabled) {
        [self requestNotificationPermission];
    } else {
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLNotificationsEnabledDefaultsName];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:GLNotificationPermissionRequestedDefaultsName];
        [self cancelLocalNotification];
    }
}

- (void)initializeNotifications {
    UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
    notificationCenter.delegate = self;
    
    // If notifications were successfully requested previously, initialize again for this app launch
    if([[NSUserDefaults standardUserDefaults] boolForKey:GLNotificationPermissionRequestedDefaultsName]) {
        [self requestNotificationPermission];
    }
    
    UNNotificationAction *endTripAction = [UNNotificationAction actionWithIdentifier:@"END_TRIP" title:@"End Trip" options:UNNotificationActionOptionNone];
    UNNotificationCategory *actionCategory = [UNNotificationCategory categoryWithIdentifier:GLNotificationCategoryTripName
                                                                                    actions:@[endTripAction]
                                                                          intentIdentifiers:@[]
                                                                                    options:UNNotificationCategoryOptionNone];
    // Background actions run on the iPhone, including when tapped on a notification mirrored to a watch.
    UNNotificationAction *resumeAction = [UNNotificationAction actionWithIdentifier:GLNotificationActionResumeTracking title:@"Resume Tracking" options:UNNotificationActionOptionNone];
    UNNotificationCategory *reminderCategory = [UNNotificationCategory categoryWithIdentifier:GLNotificationCategoryReminderName
                                                                                      actions:@[resumeAction]
                                                                            intentIdentifiers:@[]
                                                                                      options:UNNotificationCategoryOptionNone];
    [notificationCenter setNotificationCategories:[NSSet setWithArray:@[actionCategory, reminderCategory]]];
}

- (void)requestNotificationPermission {
    [self requestNotificationPermissionWithCompletion:nil];
}

- (void)requestNotificationPermissionWithCompletion:(void (^)(BOOL granted))completion {
    NSUInteger revision = ++self.notificationPermissionRevision;
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
        completionHandler:^(BOOL granted, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if(revision != self.notificationPermissionRevision) {
                    if(completion) completion(NO);
                    return;
                }
                [NSUserDefaults.standardUserDefaults setBool:granted forKey:GLNotificationPermissionRequestedDefaultsName];
                [NSUserDefaults.standardUserDefaults setBool:granted forKey:GLNotificationsEnabledDefaultsName];
                [self scheduleLocalNotification];
                [[NSNotificationCenter defaultCenter] postNotificationName:GLSettingsChangedNotification object:self];
                if(completion) completion(granted);
            });
        }];
}

- (void)notify:(NSString *)message withTitle:(NSString *)title
{
    if(self.problemNotificationsOnly) return;
    [self postLocalNotification:message title:title];
}

- (void)postLocalNotification:(NSString *)message title:(NSString *)title {
    if([self notificationsEnabled]) {
        UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];
        
        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = title;
        content.body = message;
        content.sound = [UNNotificationSound defaultSound];
        
        /* UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:1 repeats:NO]; */
        
        NSString *identifier = @"GLLocalNotification";
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                              content:content
                                                                              trigger:nil];
        
        [notificationCenter addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
            if (error != nil) {
                NSLog(@"Something went wrong: %@",error);
            } else {
                NSLog(@"Notification sent");
            }
        }];
    }
}

/* Force notifications to display as normal when the app is active */
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    
    completionHandler(UNNotificationPresentationOptionList | UNNotificationPresentationOptionBanner);
}

- (void)askToEndTrip
{
    if(self.notificationsEnabled && !self.problemNotificationsOnly) {
        UNUserNotificationCenter *notificationCenter = [UNUserNotificationCenter currentNotificationCenter];

        UNMutableNotificationContent *content = [UNMutableNotificationContent new];
        content.title = @"End Trip";
        content.body = @"It looks like you stopped moving, would you like to end the current trip?";
        content.sound = [UNNotificationSound defaultSound];
        content.categoryIdentifier = GLNotificationCategoryTripName;
        
        NSString *identifier = @"GLLocalNotificationEndTripPrompt";
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier
                                                                              content:content
                                                                              trigger:nil];

        [notificationCenter addNotificationRequest:request withCompletionHandler:^(NSError * _Nullable error) {
            if(error != nil) {
                NSLog(@"Something went wrong trying to ask to end the trip: %@", error);
            } else{
                NSLog(@"Notification sent");
            }
        }];
    }
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center didReceiveNotificationResponse:(nonnull UNNotificationResponse *)response withCompletionHandler:(nonnull void (^)(void))completionHandler
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if([@"END_TRIP" isEqualToString:response.actionIdentifier]) {
            [self endTripFromPrompt:response.notification.request.content.userInfo];
            // The summary is written after a pedometer query, so stay awake for it.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), completionHandler);
            return;
        }
        if([GLNotificationActionResumeTracking isEqualToString:response.actionIdentifier] && [self resumeTrackingFromReminder]) {
            // refreshLocation restarts updates a second later, so stay awake past that.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), completionHandler);
            return;
        }
        completionHandler();
    });
}


#pragma mark - Wi-Fi Places

- (NSDictionary *)matchingWifiPlaceForSSID:(NSString *)ssid location:(CLLocation *)fix {
    if(!GLValidWifiSSID(ssid) || !fix) return nil;
    NSDictionary *nearest;
    CLLocationDistance best = DBL_MAX;
    for(NSDictionary *place in self.wifiPlaces) {
        if(![place[@"networks"] containsObject:ssid] || !GLWifiPlaceContainsFix(place, fix)) continue;
        CLLocation *center = [[CLLocation alloc] initWithLatitude:[place[@"latitude"] doubleValue] longitude:[place[@"longitude"] doubleValue]];
        CLLocationDistance distance = [center distanceFromLocation:fix];
        if(distance < best) { best = distance; nearest = place; }
    }
    return nearest;
}

- (NSDictionary *)currentWifiPlaceForLocations:(NSArray<CLLocation *> *)locations networkInfo:(NSDictionary *)info {
    CLLocation *current = locations.lastObject;
    // A current network cannot establish where delayed fixes were recorded.
    if(!current || ![self isValidLocation:current] || fabs(current.timestamp.timeIntervalSinceNow) > 20) return nil;
    if(GLValidWifiSSID(info[@"SSID"])) return [self matchingWifiPlaceForSSID:info[@"SSID"] location:current];
    // In the background iOS sometimes cannot name the connected network. An unnamed network keeps
    // the last match while fixes stay inside it; another network or a fix outside ends it.
    if(!self.wifiPlaceMatchID) return nil;
    for(NSDictionary *place in self.wifiPlaces) {
        if([place[@"id"] isEqual:self.wifiPlaceMatchID]) return GLWifiPlaceContainsFix(place, current) ? place : nil;
    }
    return nil;
}

- (NSArray<CLLocation *> *)locationsByApplyingWifiPlace:(NSArray<CLLocation *> *)locations networkInfo:(NSDictionary *)info {
    NSDictionary *place = [self currentWifiPlaceForLocations:locations networkInfo:info];
    if(!place || ![place[@"record"] isEqual:@"point"]) return locations;
    CLLocation *current = locations.lastObject;
    // Never less accurate than the fix it replaces, so Max Saved-Point Error keeps every point it would have kept.
    CLLocationAccuracy accuracy = MIN(GLWifiPlaceMatchDistance, current.horizontalAccuracy);
    CLLocation *replacement = [[CLLocation alloc] initWithCoordinate:CLLocationCoordinate2DMake([place[@"latitude"] doubleValue], [place[@"longitude"] doubleValue])
        altitude:0 horizontalAccuracy:accuracy verticalAccuracy:-1 course:-1 speed:0 timestamp:current.timestamp];
    NSMutableArray *result = [locations mutableCopy];
    result[result.count - 1] = replacement;
    return result;
}

- (NSArray<NSDictionary<NSString *, id> *> *)wifiPlaces {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id stored = [defaults objectForKey:GLWifiPlacesDefaultsName];
    if(stored) return [GLManager validatedWifiPlaces:stored] ?: @[];
    id zones = [defaults objectForKey:GLWifiZonesDefaultsName];
    if(!zones) {
        NSString *name = [defaults objectForKey:@"WifiZoneName"];
        if(![name isKindOfClass:NSString.class] || name.length == 0) return @[];
        zones = @[@{@"name": name, @"latitude": [defaults objectForKey:@"WifiZoneLatitude"] ?: @"0",
            @"longitude": [defaults objectForKey:@"WifiZoneLongitude"] ?: @"0"}];
    }
    NSArray *places = [GLManager placesFromLegacyWifiZones:zones];
    if(!places) return @[];
    [self replaceWifiPlaces:places];
    return places;
}

- (NSDictionary *)wifiNetworkInfoForBatch {
    return [GLManager currentWifiNetworkInfo];
}

#pragma mark - Observed Wi-Fi networks

+ (NSArray<NSDictionary<NSString *, id> *> *)knownWifiNetworks {
    return [self knownWifiNetworksAtDate:NSDate.date];
}

+ (NSArray<NSDictionary *> *)knownWifiNetworksAtDate:(NSDate *)now {
    @synchronized (GLManager.class) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        id stored = [defaults objectForKey:GLWifiKnownNetworksDefaultsName];
        NSArray *raw = [stored isKindOfClass:NSArray.class] ? stored : @[];
        NSArray *normalized = GLNormalizedWifiCatalog(raw, now);
        if(![raw isEqualToArray:normalized]) [defaults setObject:normalized forKey:GLWifiKnownNetworksDefaultsName];
        return normalized;
    }
}

+ (NSArray<NSDictionary<NSString *, id> *> *)frequentWifiNetworks {
    return [self frequentWifiNetworksAtDate:NSDate.date places:GLManager.sharedManager.wifiPlaces];
}

+ (NSArray<NSDictionary *> *)frequentWifiNetworksAtDate:(NSDate *)now places:(NSArray<NSDictionary *> *)places {
    NSMutableSet *assigned = [NSMutableSet set];
    for(NSDictionary *place in places) [assigned addObjectsFromArray:place[@"networks"]];
    NSMutableArray *frequent = [NSMutableArray array];
    for(NSDictionary *network in [self knownWifiNetworksAtDate:now]) {
        if([assigned containsObject:network[@"name"]]) continue;
        double seconds = 0;
        for(NSNumber *value in [network[@"days"] allValues]) seconds += value.doubleValue;
        if(seconds < 3600) continue;
        NSMutableDictionary *entry = [network mutableCopy];
        entry[@"connectedSeconds"] = @(seconds);
        [frequent addObject:entry.copy];
    }
    [frequent sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult order = [b[@"connectedSeconds"] compare:a[@"connectedSeconds"]];
        if(order == NSOrderedSame) order = [b[@"lastSeen"] compare:a[@"lastSeen"]];
        return order == NSOrderedSame ? [a[@"name"] compare:b[@"name"]] : order;
    }];
    if(frequent.count > 3) [frequent removeObjectsInRange:NSMakeRange(3, frequent.count - 3)];
    return frequent.copy;
}

- (void)rememberWifiNetworkInfo:(NSDictionary *)info {
    [self rememberWifiNetworkInfo:info location:nil date:NSDate.date];
}

- (void)rememberWifiNetworkInfo:(NSDictionary *)info location:(CLLocation *)fix date:(NSDate *)now {
    @synchronized (GLManager.class) {
        NSString *ssid = GLWifiSSID(info);
        NSDate *previousDate = self.observedWifiDate;
        NSString *previousSSID = self.observedWifiSSID;
        self.observedWifiDate = now;
        self.observedWifiSSID = ssid;
        NSArray *known = [GLManager knownWifiNetworksAtDate:now];
        if(!ssid) return;
        NSMutableArray *updated = [known mutableCopy];
        NSMutableDictionary *entry;
        for(NSDictionary *network in known) if([network[@"name"] isEqual:ssid]) { entry = [network mutableCopy]; [updated removeObject:network]; break; }
        if(!entry) entry = [@{@"name": ssid, @"days": @{}} mutableCopy];
        entry[@"lastSeen"] = @(now.timeIntervalSince1970);
        if(fix && CLLocationCoordinate2DIsValid(fix.coordinate) && isfinite(fix.horizontalAccuracy)
           && fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= 100
           && [fix.timestamp timeIntervalSinceDate:now] <= 0 && [fix.timestamp timeIntervalSinceDate:now] >= -60) {
            entry[@"latitude"] = @(fix.coordinate.latitude);
            entry[@"longitude"] = @(fix.coordinate.longitude);
        }
        NSMutableDictionary *days = [GLWifiDays(entry[@"days"], now) mutableCopy];
        NSTimeInterval gap = previousDate ? [now timeIntervalSinceDate:previousDate] : 0;
        if([ssid isEqual:previousSSID] && gap > 0 && gap <= 600) {
            NSTimeInterval cursor = previousDate.timeIntervalSince1970, end = now.timeIntervalSince1970;
            while(cursor < end) {
                NSTimeInterval boundary = (floor(cursor / 86400) + 1) * 86400;
                NSTimeInterval next = MIN(end, boundary);
                NSString *day = GLWifiDay(cursor);
                days[day] = @(MIN(86400, [days[day] doubleValue] + next - cursor));
                cursor = next;
            }
        }
        entry[@"days"] = GLWifiDays(days, now);
        [updated addObject:entry.copy];
        NSArray *normalized = GLNormalizedWifiCatalog(updated, now);
        if(![known isEqualToArray:normalized]) [NSUserDefaults.standardUserDefaults setObject:normalized forKey:GLWifiKnownNetworksDefaultsName];
    }
}

#pragma mark -

- (BOOL)defaultsKeyExists:(NSString *)key {
    return [NSUserDefaults.standardUserDefaults objectForKey:key] != nil;
}

+ (NSString *)currentWifiHotSpotName {
    return [self currentWifiNetworkInfo][@"SSID"];
}

static NSDictionary *GLFetchedWifiNetwork;
static CFAbsoluteTime GLFetchedWifiTime;
static BOOL GLFetchingWifiNetwork;

static NSDictionary *GLNormalizedCurrentWifiInfo(id ssid) {
    return GLValidWifiSSID(ssid) ? @{@"SSID": ssid} : nil;
}

// Current SSID access needs location authorization and the Wi-Fi information entitlement.
// A recent NEHotspotNetwork result fills in when the deprecated CaptiveNetwork API is empty.
+ (NSDictionary *)currentWifiNetworkInfo {
    NSArray *ifs = (__bridge_transfer id)CNCopySupportedInterfaces();
    for (NSString *ifnam in ifs) {
        NSDictionary *info = (__bridge_transfer id)CNCopyCurrentNetworkInfo((__bridge CFStringRef)ifnam);
        if(![info isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *network = GLNormalizedCurrentWifiInfo(info[@"SSID"]);
        if(network) return network;
    }
    [self refreshCurrentWifiNetwork:nil];
    @synchronized (GLManager.class) {
        if(GLFetchedWifiNetwork && CFAbsoluteTimeGetCurrent() - GLFetchedWifiTime < 120) return GLFetchedWifiNetwork;
    }
    return @{};
}

+ (void)refreshCurrentWifiNetwork:(void (^)(NSDictionary *network))completion {
    @synchronized (GLManager.class) {
        if(GLFetchingWifiNetwork && !completion) return;
        GLFetchingWifiNetwork = YES;
    }
    [NEHotspotNetwork fetchCurrentWithCompletionHandler:^(NEHotspotNetwork *current) {
        NSDictionary *network = GLNormalizedCurrentWifiInfo(current.SSID);
        @synchronized (GLManager.class) {
            GLFetchingWifiNetwork = NO;
            GLFetchedWifiNetwork = network;
            GLFetchedWifiTime = CFAbsoluteTimeGetCurrent();
        }
        if(completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(network ?: @{}); });
    }];
}

#pragma mark - FMDB

+ (NSString *)tripDatabasePath {
    NSString *docsPath = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    return [docsPath stringByAppendingPathComponent:@"trips.sqlite"];
}

- (void)setUpTripDB {
    [self.tripdb open];
    if(![self.tripdb executeUpdate:@"CREATE TABLE IF NOT EXISTS trips (\
       id INTEGER PRIMARY KEY AUTOINCREMENT, \
       timestamp INTEGER, \
       latitude REAL, \
       longitude REAL \
     )"]) {
        NSLog(@"Error creating trip DB: %@", self.tripdb.lastErrorMessage);
    }
    [self.tripdb close];
}

- (void)clearTripDB {
    [self.tripdb executeUpdate:@"DELETE FROM trips"];
}


#pragma mark - LOLDB

+ (NSString *)cacheDatabasePath
{
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *oldPath = [caches stringByAppendingPathComponent:@"GLLoggerCache.sqlite"];
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSError *error;
    if(![files createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"Unable to create queue directory: %@", error.localizedDescription);
        return oldPath;
    }
    NSString *path = [support stringByAppendingPathComponent:@"GLLoggerCache.sqlite"];
    if([files fileExistsAtPath:path] || ![files fileExistsAtPath:oldPath]) return path;

    NSString *temporary = [path stringByAppendingString:@".migration"];
    sqlite3 *source = NULL;
    sqlite3 *destination = NULL;
    BOOL copied = NO;
    if(sqlite3_open_v2(oldPath.UTF8String, &source, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK &&
       sqlite3_open(temporary.UTF8String, &destination) == SQLITE_OK) {
        sqlite3_backup *backup = sqlite3_backup_init(destination, "main", source, "main");
        if(backup) {
            int status = sqlite3_backup_step(backup, -1);
            int finished = sqlite3_backup_finish(backup);
            copied = status == SQLITE_DONE && finished == SQLITE_OK;
        }
    }
    if(destination) sqlite3_close(destination);
    if(source) sqlite3_close(source);
    if(copied && [files moveItemAtPath:temporary toPath:path error:&error]) return path;
    NSLog(@"Queue migration could not finish; retaining the original database");
    return oldPath;
}

+ (id)objectFromJSONData:(NSData *)data error:(NSError **)error;
{
    if(data.length == 0) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:error];
}

+ (NSData *)dataWithJSONObject:(id)object error:(NSError **)error;
{
    id safe = [self JSONSafeObject:object];
    if(![NSJSONSerialization isValidJSONObject:safe]) return nil;
    return [NSJSONSerialization dataWithJSONObject:safe options:0 error:error];
}

+ (id)JSONSafeObject:(id)object {
    if([object isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *safe = [NSMutableDictionary dictionaryWithCapacity:[object count]];
        [(NSDictionary *)object enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            safe[key] = [self JSONSafeObject:value];
        }];
        return safe;
    } else if([object isKindOfClass:[NSArray class]]) {
        NSMutableArray *safe = [NSMutableArray arrayWithCapacity:[object count]];
        for(id value in (NSArray *)object) {
            [safe addObject:[self JSONSafeObject:value]];
        }
        return safe;
    } else if([object isKindOfClass:[NSNumber class]]) {
        double value = [object doubleValue];
        if(isnan(value) || isinf(value)) {
            return [NSNull null];
        }
    }
    return object;
}

+ (NSString *)iso8601DateStringFromDate:(NSDate *)date {
    struct tm timeinfo;
    char buffer[80];
    
    time_t rawtime = (time_t)[date timeIntervalSince1970];
    gmtime_r(&rawtime, &timeinfo);
    
    strftime(buffer, 80, "%Y-%m-%dT%H:%M:%SZ", &timeinfo);
    
    return [NSString stringWithCString:buffer encoding:NSUTF8StringEncoding];
}

@end
