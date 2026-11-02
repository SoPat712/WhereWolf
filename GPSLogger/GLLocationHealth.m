#import "GLLocationHealth.h"
#import <math.h>

@interface GLLocationHealthPolicy ()
@property (nonatomic) NSUInteger attempts;
@property (nonatomic) BOOL expected;
@property NSTimeInterval started;
@property NSTimeInterval callback;
@property NSTimeInterval fresh;
@property NSTimeInterval saved;
@property NSTimeInterval nextRetry;
@property NSTimeInterval lastAttempt;
@property BOOL gapReported;
@property BOOL filterReported;
@property (nonatomic, strong, nullable) NSDate *newestFix;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *rejections;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *events;
@end

@implementation GLLocationHealthPolicy
- (instancetype)init {
    if((self = [super init])) {
        _retryAfter = 120;
        _rejections = [NSMutableDictionary dictionary];
        _events = [NSMutableArray array];
        [self resetAtUptime:0];
    }
    return self;
}
- (void)resetAtUptime:(NSTimeInterval)uptime {
    self.started = uptime;
    self.callback = self.fresh = self.saved = self.lastAttempt = NAN;
    self.nextRetry = uptime + self.retryAfter;
    self.attempts = 0;
    self.gapReported = self.filterReported = NO;
    self.newestFix = nil;
    [self.rejections removeAllObjects];
    [self.events removeAllObjects];
}
- (void)setExpected:(BOOL)expected uptime:(NSTimeInterval)uptime {
    if(expected == self.expected) return;
    self.expected = expected;
    self.started = uptime;
    self.callback = self.fresh = self.saved = NAN;
    self.nextRetry = MAX(self.nextRetry, uptime + self.retryAfter);
    self.gapReported = self.filterReported = NO;
    [self.rejections removeAllObjects];
}
- (void)setRetryAfter:(NSTimeInterval)retryAfter {
    _retryAfter = isfinite(retryAfter) ? MIN(1800, MAX(60, retryAfter)) : 120;
}
- (NSTimeInterval)freshAge:(NSTimeInterval)uptime {
    return MAX(0, uptime - (isfinite(self.fresh) ? self.fresh : self.started));
}
- (void)addEvent:(NSString *)kind date:(NSDate *)date duration:(NSTimeInterval)duration {
    NSMutableDictionary *event = [@{@"id": NSUUID.UUID.UUIDString, @"time": @(date.timeIntervalSince1970),
        @"kind": kind, @"seconds": @(MAX(0, duration)), @"attempt": @(self.attempts)} mutableCopy];
    if(self.rejections.count) event[@"rejected"] = self.rejections.copy;
    [self.events addObject:event];
    if(self.events.count > 32) [self.events removeObjectAtIndex:0];
}
- (void)observeLocations:(NSArray<CLLocation *> *)locations uptime:(NSTimeInterval)uptime date:(NSDate *)date {
    if(!self.expected) return;
    self.callback = uptime;
    if([self.newestFix timeIntervalSinceDate:date] > 20) self.newestFix = nil;
    NSDate *newest;
    for(CLLocation *location in locations) {
        if(![location isKindOfClass:CLLocation.class]) continue;
        NSTimeInterval age = [date timeIntervalSinceDate:location.timestamp];
        if(!CLLocationCoordinate2DIsValid(location.coordinate) || !isfinite(location.horizontalAccuracy)
           || location.horizontalAccuracy < 0 || !isfinite(age) || age < 0 || age > 20) continue;
        if(self.newestFix && [location.timestamp compare:self.newestFix] != NSOrderedDescending) continue;
        if(!newest || [location.timestamp compare:newest] == NSOrderedDescending) newest = location.timestamp;
    }
    if(!newest) return;
    NSTimeInterval gap = [self freshAge:uptime];
    if(self.gapReported || self.attempts > 0) [self addEvent:@"updates_resumed" date:date duration:gap];
    self.newestFix = newest;
    self.fresh = uptime;
    self.nextRetry = uptime + self.retryAfter;
    self.attempts = 0;
    self.lastAttempt = NAN;
    self.gapReported = NO;
}
- (void)recordSaved:(NSUInteger)saved rejected:(NSDictionary<NSString *, NSNumber *> *)rejected
             uptime:(NSTimeInterval)uptime date:(NSDate *)date {
    if(!self.expected) return;
    for(NSString *key in rejected) self.rejections[key] = @(MIN(1000000, self.rejections[key].unsignedIntegerValue + rejected[key].unsignedIntegerValue));
    if(saved == 0) return;
    if(self.filterReported) [self addEvent:@"saving_resumed" date:date duration:uptime - (isfinite(self.saved) ? self.saved : self.started)];
    self.saved = uptime;
    self.filterReported = NO;
    [self.rejections removeAllObjects];
}
- (BOOL)evaluateAtUptime:(NSTimeInterval)uptime date:(NSDate *)date automaticRetry:(BOOL)retry {
    if(!self.expected) return NO;
    NSTimeInterval age = [self freshAge:uptime];
    if(age >= self.retryAfter) {
        if(!self.gapReported) {
            NSString *kind = !isfinite(self.callback) || uptime - self.callback >= self.retryAfter ? @"updates_missing" : @"updates_outdated";
            [self addEvent:kind date:date duration:age];
            self.gapReported = YES;
        }
        if(!retry || self.attempts >= 3 || uptime < self.nextRetry) return NO;
        self.attempts++;
        self.lastAttempt = uptime;
        const double multipliers[] = {2, 5, 10};
        self.nextRetry = uptime + self.retryAfter * multipliers[self.attempts - 1];
        [self addEvent:@"retry_requested" date:date duration:age];
        return YES;
    }
    NSTimeInterval sinceSaved = MAX(0, uptime - (isfinite(self.saved) ? self.saved : self.started));
    if(isfinite(self.fresh) && sinceSaved >= self.retryAfter && self.rejections.count && !self.filterReported) {
        [self addEvent:@"points_skipped" date:date duration:sinceSaved];
        self.filterReported = YES;
    }
    return NO;
}
- (NSDictionary<NSString *, id> *)snapshotAtUptime:(NSTimeInterval)uptime {
    NSString *state = @"not_expected";
    NSTimeInterval age = [self freshAge:uptime];
    if(self.expected) {
        if(age >= self.retryAfter) state = !isfinite(self.callback) || uptime - self.callback >= self.retryAfter ? @"updates_missing" : @"updates_outdated";
        else if(self.filterReported) state = @"points_skipped";
        else state = isfinite(self.fresh) ? @"receiving" : @"waiting";
    }
    NSMutableDictionary *snapshot = [@{@"state": state, @"attempts": @(self.attempts), @"limit": @3,
        @"rejected": self.rejections.copy} mutableCopy];
    if(self.expected) snapshot[@"fresh_age"] = @(age);
    if(isfinite(self.callback)) snapshot[@"callback_age"] = @(MAX(0, uptime - self.callback));
    if(isfinite(self.lastAttempt)) snapshot[@"retry_age"] = @(MAX(0, uptime - self.lastAttempt));
    return snapshot;
}
- (NSArray<NSDictionary *> *)takeEvents {
    NSArray *events = self.events.copy;
    [self.events removeAllObjects];
    return events;
}
@end

@interface GLLocationHealthLog ()
@property (nonatomic, strong) NSURL *directory;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation GLLocationHealthLog
- (instancetype)initWithDirectory:(NSURL *)directory {
    if((self = [super init])) {
        _directory = directory;
        _queue = dispatch_queue_create("com.sopat712.where.location-health-log", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (NSURL *)file { return [self.directory URLByAppendingPathComponent:@"events.json"]; }
- (nullable NSDictionary *)validated:(id)value {
    if(![value isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *input = value;
    if(![input[@"kind"] isKindOfClass:NSString.class] || [input[@"kind"] length] > 64
       || ![input[@"time"] isKindOfClass:NSNumber.class] || !isfinite([input[@"time"] doubleValue])) return nil;
    NSArray *kinds = @[@"logging_started", @"app_launched", @"monitor_resumed", @"monitor_paused", @"updates_missing",
        @"updates_outdated", @"retry_requested", @"manual_retry", @"updates_resumed", @"points_skipped",
        @"saving_resumed", @"save_time_expired"];
    if(![kinds containsObject:input[@"kind"]]) return nil;
    NSMutableDictionary *event = [@{@"kind": input[@"kind"], @"time": input[@"time"]} mutableCopy];
    if([input[@"id"] isKindOfClass:NSString.class] && [input[@"id"] length] <= 80) event[@"id"] = input[@"id"];
    if([@[@"new", @"original"] containsObject:input[@"engine"]]) event[@"engine"] = input[@"engine"];
    NSArray *reasons = @[@"tracking_off", @"event_mode", @"permission", @"radius_pause", @"adaptive_pause",
        @"automatic_pause", @"location_event", @"other_launch"];
    if([reasons containsObject:input[@"reason"]]) event[@"reason"] = input[@"reason"];
    if(!event[@"id"]) event[@"id"] = NSUUID.UUID.UUIDString;
    for(NSString *key in @[@"seconds", @"attempt"]) {
        if([input[key] isKindOfClass:NSNumber.class] && isfinite([input[key] doubleValue])) event[key] = @(MAX(0, [input[key] doubleValue]));
    }
    NSDictionary *counts = [input[@"rejected"] isKindOfClass:NSDictionary.class] ? input[@"rejected"] : @{};
    NSMutableDictionary *rejected = [NSMutableDictionary dictionary];
    for(NSString *key in @[@"invalid", @"accuracy", @"jump", @"order", @"duplicate", @"stationary", @"gps", @"threshold", @"storage"]) {
        if([counts[key] isKindOfClass:NSNumber.class] && isfinite([counts[key] doubleValue])) rejected[key] = @(MIN(1000000, MAX(0, [counts[key] integerValue])));
    }
    if(rejected.count) event[@"rejected"] = rejected;
    return event;
}
- (NSMutableArray<NSDictionary *> *)read {
    NSNumber *size;
    [self.file getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
    if(size.unsignedLongLongValue > 256 * 1024) return [NSMutableArray array];
    NSData *data = [NSData dataWithContentsOfURL:self.file];
    id decoded = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSMutableArray *events = [NSMutableArray array];
    NSTimeInterval cutoff = NSDate.date.timeIntervalSince1970 - 7 * 86400;
    if([decoded isKindOfClass:NSArray.class]) {
        for(id value in decoded) {
            NSDictionary *event = [self validated:value];
            if(event && [event[@"time"] doubleValue] >= cutoff) [events addObject:event];
        }
    }
    if(events.count > 200) [events removeObjectsInRange:NSMakeRange(0, events.count - 200)];
    if([decoded isKindOfClass:NSArray.class] && events.count != [decoded count]) [self write:events];
    return events;
}
- (void)write:(NSArray *)events {
    NSFileManager *files = NSFileManager.defaultManager;
    NSError *error;
    if(![files createDirectoryAtURL:self.directory withIntermediateDirectories:YES
        attributes:@{NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error]) return;
    [self.directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];
    NSData *data = [NSJSONSerialization dataWithJSONObject:events options:0 error:NULL];
    if(![data writeToURL:self.file options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:&error]) {
        NSLog(@"Location health log could not be saved: %@", error.localizedDescription);
    }
}
- (void)append:(NSDictionary *)event {
    NSDictionary *safe = [self validated:event];
    if(!safe) return;
    dispatch_async(self.queue, ^{
        NSMutableArray *events = [self read];
        [events addObject:safe];
        if(events.count > 200) [events removeObjectsInRange:NSMakeRange(0, events.count - 200)];
        [self write:events];
    });
}
- (void)load:(void (^)(NSArray<NSDictionary *> *))completion {
    dispatch_async(self.queue, ^{
        NSArray *events = [self read].copy;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(events); });
    });
}
- (void)clear:(void (^)(void))completion {
    dispatch_async(self.queue, ^{
        [NSFileManager.defaultManager removeItemAtURL:self.file error:NULL];
        dispatch_async(dispatch_get_main_queue(), completion);
    });
}
@end

@interface GLLocationSaveAllowance ()
@property UIBackgroundTaskIdentifier identifier;
@property BOOL finished;
@property (nonatomic, copy) void (^end)(UIBackgroundTaskIdentifier);
@end

@implementation GLLocationSaveAllowance
- (instancetype)init {
    return [self initWithBegin:^UIBackgroundTaskIdentifier(void (^expiration)(void)) {
        return [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Save Received Locations" expirationHandler:expiration];
    } end:^(UIBackgroundTaskIdentifier identifier) {
        [UIApplication.sharedApplication endBackgroundTask:identifier];
    }];
}
- (instancetype)initWithBegin:(UIBackgroundTaskIdentifier (^)(void (^)(void)))begin
                          end:(void (^)(UIBackgroundTaskIdentifier))end {
    if((self = [super init])) {
        _identifier = UIBackgroundTaskInvalid;
        _end = [end copy];
        __weak typeof(self) weakSelf = self;
        UIBackgroundTaskIdentifier identifier = begin(^{ [weakSelf finish]; });
        @synchronized(self) {
            if(self.finished) { if(identifier != UIBackgroundTaskInvalid) end(identifier); }
            else self.identifier = identifier;
        }
    }
    return self;
}
- (void)finish {
    UIBackgroundTaskIdentifier identifier;
    @synchronized(self) {
        if(self.finished) return;
        self.finished = YES;
        identifier = self.identifier;
        self.identifier = UIBackgroundTaskInvalid;
    }
    if(identifier == UIBackgroundTaskInvalid) return;
    if(NSThread.isMainThread) self.end(identifier);
    else dispatch_async(dispatch_get_main_queue(), ^{ self.end(identifier); });
}
@end
