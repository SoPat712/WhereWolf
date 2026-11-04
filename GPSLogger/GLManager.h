//
//  GLManager.h
//  GPSLogger
//
//  Created by Aaron Parecki on 9/17/15.
//  Copyright © 2015 Esri. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreMotion/CoreMotion.h>
#import "GLCloudFileWriter.h"
@import UserNotifications;

static NSString *const GLReminderChangedNotification = @"GLReminderChangedNotification";
static NSString *const GLTrackingStateChangedNotification = @"GLTrackingStateChangedNotification";
static NSString *const GLNewDataNotification = @"GLNewDataNotification";
static NSString *const GLNewActivityNotification = @"GLNewActivityNotification";
static NSString *const GLAuthorizationStatusChangedNotification = @"GLAuthorizationStatusChangedNotification";
static NSString *const GLSendingStartedNotification = @"GLSendingStartedNotification";
static NSString *const GLSendingFinishedNotification = @"GLSendingFinishedNotification";
static NSString *const GLSettingsChangedNotification = @"GLSettingsChangedNotification";
static NSString *const GLUploadStateChangedNotification = @"GLUploadStateChangedNotification";

static NSString *const GLAPIEndpointDefaultsName = @"GLAPIEndpointDefaults";
static NSString *const GLAPIAccessTokenDefaultsName = @"GLAPIAccessTokenDefaults";
static NSString *const GLDeviceIdDefaultsName = @"GLDeviceIdDefaults";
static NSString *const GLLastSentDateDefaultsName = @"GLLastSentDateDefaults";
static NSString *const GLTrackingStateDefaultsName = @"GLTrackingStateDefaults";
static NSString *const GLSendIntervalDefaultsName = @"GLSendIntervalDefaults";
static NSString *const GLPausesAutomaticallyDefaultsName = @"GLPausesAutomaticallyDefaults";
static NSString *const GLResumesAutomaticallyDefaultsName = @"GLResumesAutomaticallyDefaults";
static NSString *const GLDiscardPointsWithinDistanceDefaultsName = @"GLDiscardPointsWithinDistanceDefaults";
static NSString *const GLDiscardPointsWithinSecondsDefaultsName = @"GLDiscardPointsWithinSecondsDefaults";
static NSString *const GLDiscardPointsOutsideAccuracyDefaultsName = @"GLDiscardPointsOutsideAccuracyDefaults";
static NSString *const GLStopsAutomaticallyDefaultsName = @"GLStopsAutomaticallyDefaults";
static NSString *const GLStopsAutomaticallyAfterDefaultsName = @"GLStopsAutomaticallyAfterDefaults";
static NSString *const GLIncludeTrackingStatsDefaultsName = @"GLIncludeTrackingStatsDefaultsName";
static NSString *const GLActivityTypeDefaultsName = @"GLActivityTypeDefaults";
static NSString *const GLDesiredAccuracyDefaultsName = @"GLDesiredAccuracyDefaults";
static NSString *const GLSignificantLocationModeDefaultsName = @"GLSignificantLocationModeDefaults";
static NSString *const GLPointsPerBatchDefaultsName = @"GLPointsPerBatchDefaults";
static NSString *const GLNotificationPermissionRequestedDefaultsName = @"GLNotificationPermissionRequestedDefaults";
static NSString *const GLNotificationsEnabledDefaultsName = @"GLNotificationsEnabledDefaults";
static NSString *const GLIncludeUniqueIdDefaultsName = @"GLIncludeUniqueIdDefaults";
static NSString *const GLConsiderHTTP200SuccessDefaultsName = @"GLConsiderHTTP200SuccessDefaults";
static NSString *const GLPreciseSettingsDefaults = @"GLPreciseSettingsDefaults";
static NSString *const GLBackgroundIndicatorDefaultsName = @"GLBackgroundIndicatorDefaults";
static NSString *const GLLoggingModeDefaultsName = @"GLLoggingModeDefaults";
static NSString *const GLDestinationDefaultsName = @"GLDestination";
static NSString *const GLCloudFileModeDefaultsName = @"GLCloudFileMode";
static NSString *const GLDiscardPointsWithoutGPSDefaultsName = @"GLDiscardPointsWithoutGPSDefaults";
static NSString *const GLTripDiscardPointsWithoutGPSDefaultsName = @"GLTripDiscardPointsWithoutGPSDefaults";
static NSString *const GLDiscardPointsWhileStationaryDefaultsName = @"GLDiscardPointsWhileStationaryDefaults";
static NSString *const GLTripDiscardPointsWhileStationaryDefaultsName = @"GLTripDiscardPointsWhileStationaryDefaults";
static NSString *const GLTripLiveActivityEnabledDefaultsName = @"GLTripLiveActivityEnabled";
static NSString *const GLTripModeStatsDefaultsName = @"GLTripModeStats";
static NSString *const GLVisitTrackingEnabledDefaultsName = @"GLVisitTrackingEnabledDefaults";
static NSString *const GLLastTimeMovedBeyondStopThresholdDefaultsName = @"GLLastTimeMovedBeyondStopThresholdDefaults";
static NSString *const GLDidPauseByRadiusDefaultsName = @"GLDidPauseByRadiusDefaults";

static NSString *const GLPurgeQueueOnNextLaunchDefaultsName = @"GLPurgeQueueOnNextLaunch";
static NSString *const GLLastScheduledNotificationDateDefaultsName = @"GLLastScheduledNotificationDateDefaults";

/* During-Trip Defaults */
static NSString *const GLTripDesiredAccuracyDefaultsName = @"GLTripDesiredAccuracyDefaults";
static NSString *const GLTripActivityTypeDefaultsName = @"GLTripActivityTypeDefaults";
static NSString *const GLTripBackgroundIndicatorDefaultsName = @"GLTripBackgroundIndicatorDefaults";
static NSString *const GLTripPausesAutomaticallyDefaultsName = @"GLTripPausesAutomaticallyDefaults";
static NSString *const GLTripLoggingModeDefaultsName = @"GLTripLoggingModeDefaults";
static NSString *const GLTripPointsPerBatchDefaultsName = @"GLTripPointsPerBatchDefaults";
static NSString *const GLTripDiscardPointsWithinDistanceDefaultsName = @"GLTripDiscardPointsWithinDistanceDefaults";
static NSString *const GLTripDiscardPointsWithinSecondsDefaultsName = @"GLTripDiscardPointsWithinSecondsDefaults";
static NSString *const GLTripDiscardPointsOutsideAccuracyDefaultsName = @"GLTripDiscardPointsOutsideAccuracyDefaults";
static NSString *const GLScreenLockEnabledDefaultsName = @"GLScreenLockEnabledDefaults";
/* End */

static NSString *const GLTripTrackingEnabledDefaultsName = @"GLTripTrackingEnabledDefaults";
// Trip Settings: ask to end the trip once the phone has stopped (TripEndPrompt.swift)
static NSString *const GLTripAskToEndWhenStoppedDefaultsName = @"GLTripAskToEndWhenStoppedDefaults";
// When the last trip ended, which can be earlier than when it was ended
static NSString *const GLLastTripEndDefaultsName = @"GLLastTripEndDefaults";
// The End Trip category, and the userInfo of a prompt that ends the trip when the phone stopped
static NSString *const GLNotificationCategoryTripName = @"TRIP";
static NSString *const GLEndTripPromptTripStartKey = @"trip_start";
static NSString *const GLEndTripPromptStoppedAtKey = @"stopped_at";
static NSString *const GLEndTripPromptLatitudeKey = @"latitude";
static NSString *const GLEndTripPromptLongitudeKey = @"longitude";
static NSString *const GLEndTripPromptAccuracyKey = @"horizontal_accuracy";
static NSString *const GLTripModeDefaultsName = @"GLTripModeDefaults";
static NSString *const GLTripStartTimeDefaultsName = @"GLTripStartTimeDefaults";
static NSString *const GLTripStartLocationDefaultsName = @"GLTripStartLocationDefaults";
static NSString *const GLUseNewLocationEngineDefaultsName = @"GLUseNewLocationEngine";
static NSString *const GLWifiZonesDefaultsName = @"WifiZones";
static NSString *const GLWifiPlacesDefaultsName = @"WifiPlaces";
static NSString *const GLWifiKnownNetworksDefaultsName = @"WifiKnownNetworks";

static NSString *const GLTripModeWalk = @"walk";
static NSString *const GLTripModeRun = @"run";
static NSString *const GLTripModeBicycle = @"bicycle";
static NSString *const GLTripModeCar = @"car";
static NSString *const GLTripModeTaxi = @"taxi";
static NSString *const GLTripModeBus = @"bus";
static NSString *const GLTripModeTrain = @"train";
static NSString *const GLTripModePlane = @"plane";
static NSString *const GLTripModeTram = @"tram";
static NSString *const GLTripModeGondola = @"gondola";
static NSString *const GLTripModeMonorail = @"monorail";
static NSString *const GLTripModeSleigh = @"sleigh";
static NSString *const GLTripModeMetro = @"metro";
static NSString *const GLTripModeBoat = @"boat";
static NSString *const GLTripModeScooter = @"scooter";

typedef enum {
    kGLTrackingModeOff,
    kGLTrackingModeStandard,
    kGLTrackingModeSignificant,
    kGLTrackingModeStandardAndSignificant
} GLTrackingMode;

typedef enum {
    kGLLoggingModeAllData,
    kGLLoggingModeOnlyLatest,
    kGLLoggingModeOwntracks
} GLLoggingMode;

typedef enum {
    kGLLocationPropertyTimestamp,
    kGLLocationPropertyLatitude,
    kGLLocationPropertyLongitude,
    kGLLocationPropertyAccuracy,
    kGLLocationPropertySpeed,
    kGLLocationPropertyAltitude,
    kGLLocationPropertyBattery
} GLLocationProperty;

typedef void (^CaseBlock)(void);

@interface GLManager : NSObject <CLLocationManagerDelegate, UNUserNotificationCenterDelegate>

@property BOOL savesToICloudDrive;
@property GLCloudFileMode cloudFileMode;
- (BOOL)hasDestination;
- (BOOL)usesOwntracksFormat;
@property BOOL discardPointsWithoutGPS;
@property BOOL discardPointsWithoutGPSDuringTrip;
@property (readonly) BOOL discardPointsWithoutGPSCurrentValue;
@property BOOL discardPointsWhileStationary;
@property BOOL discardPointsWhileStationaryDuringTrip;
@property (readonly) BOOL discardPointsWhileStationaryCurrentValue;
@property BOOL tripLiveActivityEnabled;
- (void)syncTripLiveActivity;
@property (strong, nonatomic, readonly) CLLocation *lastDeviceLocation;
@property (strong, nonatomic, readonly) NSString *lastSendErrorTitle;
@property (strong, nonatomic, readonly) NSString *lastSendErrorMessage;

+ (GLManager *)sharedManager;

+ (NSString *)currentWifiHotSpotName;
+ (NSDictionary *)currentWifiNetworkInfo;
+ (void)refreshCurrentWifiNetwork:(void (^)(NSDictionary *network))completion;
+ (NSArray<NSDictionary<NSString *, id> *> *)knownWifiNetworks;
+ (NSArray<NSDictionary<NSString *, id> *> *)frequentWifiNetworks;

@property (strong, nonatomic, readonly) CLLocationManager *locationManager;
@property (strong, nonatomic, readonly) CMMotionActivityManager *motionActivityManager;

@property (strong, nonatomic) NSNumber *sendingInterval;
@property BOOL pausesAutomatically;
@property (nonatomic) BOOL useNewLocationEngine;
@property (nonatomic, readonly) BOOL hasContinuousUpdates;
@property (nonatomic, readonly) BOOL shouldUseLiveUpdates;
@property (nonatomic, readonly) NSString *engineState;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *advancedTrackingOptions;
@property (nonatomic, readonly) NSString *adaptiveTrackingStatus;
@property (nonatomic, readonly) NSString *motionAuthorizationStatus;
@property (nonatomic, readonly) NSString *motionSummary;
@property (nonatomic, readonly) CLLocation *lastReceivedLocation;
@property (nonatomic, readonly) NSUInteger rejectedJumpCount;
@property (nonatomic, readonly) NSDictionary<NSString *, id> *locationUpdateHealth;
- (void)loadLocationHealthLog:(void (^)(NSArray<NSDictionary *> *events))completion;
- (void)clearLocationHealthLog:(void (^)(void))completion;
- (void)noteLocationLaunch:(BOOL)locationEvent;
@property (nonatomic, readonly) BOOL pendingUploads;
@property (nonatomic, readonly) BOOL uploadsBlocked;
@property (nonatomic, readonly) BOOL waitingForWifi;
@property (nonatomic, readonly) NSDate *uploadRetryDate;
- (void)setAdvancedTrackingOption:(NSNumber *)value forKey:(NSString *)key;
- (void)requestMotionPermission;
- (void)reconcileTracking;
- (void)resumePendingUpload;
- (void)resumeUploadAfterConnectivity;
@property BOOL includeTrackingStats;
@property BOOL notificationsEnabled;
@property BOOL problemNotificationsOnly;
@property (nonatomic) CLLocationDistance resumesAfterDistance;
@property (nonatomic) CLLocationDistance discardPointsWithinDistance;
@property (nonatomic) CLLocationDistance stopsAutomaticallyRadius;
@property (nonatomic, readonly) BOOL stopsAutomaticallyActive;
@property (nonatomic) CLLocationAccuracy discardPointsOutsideAccuracy;
@property (nonatomic) int stopsAutomaticallyAfterSeconds;
@property (nonatomic) int discardPointsWithinSeconds;
@property (nonatomic) GLTrackingMode trackingMode;
@property BOOL visitTrackingEnabled;
@property (nonatomic) GLLoggingMode loggingMode;
@property (nonatomic, readonly) GLLoggingMode loggingModeCurrentValue;
@property (nonatomic) BOOL showBackgroundLocationIndicator;
@property (nonatomic) CLActivityType activityType;
@property (nonatomic) CLLocationAccuracy desiredAccuracy;
@property (nonatomic) int pointsPerBatch;
@property CLLocation* lastLocationMovedBeyondStopThreshold;
@property NSDate* lastTimeMovedBeyondStopThreshold;
@property (nonatomic) BOOL didPauseByRadius;

/* During-Trip Settings */
@property (nonatomic) CLLocationAccuracy desiredAccuracyDuringTrip;
@property (nonatomic) CLActivityType activityTypeDuringTrip;
@property (nonatomic) BOOL showBackgroundLocationIndicatorDuringTrip;
@property BOOL pausesAutomaticallyDuringTrip;
@property (nonatomic) GLLoggingMode loggingModeDuringTrip;
@property (nonatomic) int pointsPerBatchDuringTrip;
@property (nonatomic) CLLocationDistance discardPointsWithinDistanceDuringTrip;
@property (nonatomic) int discardPointsWithinSecondsDuringTrip;
/* End */

@property (readonly) BOOL trackingEnabled;
@property (readonly) BOOL sendInProgress;
@property (strong, nonatomic, readonly) CLLocation *lastLocation;
@property (strong, nonatomic, readonly) NSDictionary *lastLocationDictionary;
@property (strong, nonatomic, readonly) CMMotionActivity *lastMotion;
@property (strong, nonatomic, readonly) NSString *lastMotionString;
@property (strong, nonatomic, readonly) NSNumber *lastStepCount;
@property (strong, nonatomic, readonly) NSDate *lastSentDate;
@property (nonatomic, readonly) long currentPointsInQueue;
@property (strong, nonatomic, readonly) NSString *lastLocationName;

- (void)startAllUpdates;
- (UNMutableNotificationContent *)reminderContent;
- (BOOL)resumeTrackingFromReminder;
- (void)stopAllUpdates;
- (void)refreshLocation;
- (BOOL)deleteAllData;

- (NSString *)authorizationStatusAsString;
- (void)requestAuthorizationPermission;
- (void)requestNotificationPermissionWithCompletion:(void (^ _Nullable)(BOOL granted))completion NS_SWIFT_NAME(requestNotificationPermission(completion:));
- (NSInteger)usageProfile;
- (void)applyUsageProfile:(NSInteger)profile;

- (BOOL)saveNewAPIEndpoint:(NSString *)endpoint andAccessToken:(NSString *)accessToken;
- (NSString *)apiEndpointURL;
- (NSString *)apiAccessToken;
- (void)saveNewDeviceId:(NSString *)deviceId;
- (NSString *)deviceId;

- (void)logAction:(NSString *)action;
- (void)sendQueueNow;
- (void)notify:(NSString *)message withTitle:(NSString *)title;
- (void)askToEndTrip;

typedef NS_ENUM(NSInteger, GLSendStatus) {
    GLSendStatusSuccess = 0,
    GLSendStatusServerError = 1,
    GLSendStatusNetworkError = 2,
};

- (void)recordSendResult:(GLSendStatus)status;
- (NSArray *)recentSendResults;

- (void)numberOfLocationsInQueue:(void(^)(long num))callback;
- (void)numberOfObjectsInQueue:(void(^)(long locations, long trips, long stats))callback;
- (void)accountInfo:(void(^)(NSString *name))block;
- (NSSet <__kindof CLRegion *>*)monitoredRegions;

- (void)requestNotificationPermission;

@property (strong, nonatomic, readonly) NSArray<NSDictionary<NSString *, id> *> *wifiPlaces;
- (NSDictionary<NSString *, id> *)matchingWifiPlaceForSSID:(NSString *)ssid location:(CLLocation *)fix NS_SWIFT_NAME(matchingWifiPlace(forSSID:location:));
+ (NSString *)autoWifiPlaceSymbolForName:(NSString *)name NS_SWIFT_NAME(autoWifiPlaceSymbol(for:));
- (void)processEngineLocation:(CLLocation *)location;
- (void)enqueueWorkoutImportRecords:(NSArray<NSDictionary *> *)records
                        completion:(void (^)(NSUInteger inserted, NSString *error))completion;
- (void)processEngineStationary:(BOOL)stationary;
- (void)updateLocationEngine;
+ (BOOL)isValidEndpoint:(NSString *)endpoint;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *customHTTPHeaders;
- (void)reloadServerCredentials;
- (void)performSettingsBatch:(void (^)(void))changes;
+ (NSDictionary *)normalizedTrackingOptions:(NSDictionary *)options;
+ (NSArray<NSDictionary *> *)validatedWifiPlaces:(NSArray *)places NS_SWIFT_NAME(validatedWifiPlaces(_:));
+ (NSArray<NSDictionary *> *)placesFromLegacyWifiZones:(NSArray *)zones NS_SWIFT_NAME(places(fromLegacyWifiZones:));
- (BOOL)replaceWifiPlaces:(NSArray<NSDictionary *> *)places NS_SWIFT_NAME(replaceWifiPlaces(_:));
- (NSURLRequest *)connectionTestRequestForLocation:(CLLocation *)location;
- (NSURLSessionDataTask *)testConnectionAtLocation:(CLLocation *)location
    completion:(void (^)(NSInteger status, BOOL acknowledged, NSError *error))completion NS_SWIFT_NAME(testConnection(at:completion:));

#pragma mark - Trips

+ (NSArray *)GLTripModes;
- (BOOL)tripInProgress;
@property (nonatomic) NSString *currentTripMode;
- (NSDate *)currentTripStart;
- (NSArray *)currentTripPoints;
- (CLLocationDistance)currentTripDistance;
- (NSTimeInterval)currentTripDuration;
- (void)startTrip;
- (void)endTrip;
// Ends the trip as if it had ended at endDate and location: its end time, duration and distance
// stop there. nil means now, the same as endTrip.
- (void)endTripAtDate:(NSDate *)endDate location:(CLLocation *)location;
- (NSArray *)tripModesByFrequency;

#pragma mark -

- (void)applicationWillTerminate;
- (void)applicationDidEnterBackground;
- (void)applicationWillResignActive;

@end
