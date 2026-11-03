//
//  GLCloudFileWriter.m
//  WhereWolf
//
//  Atomic FeatureCollection writes retain queued records on failure. Stable record IDs make
//  retries safe when a batch spans several files or the queue acknowledgement fails.
//

#import "GLCloudFileWriter.h"



@implementation GLCloudFileWriter {
    dispatch_queue_t _queue;
    NSURL *_documentsURL;
    NSDateFormatter *_dailyPathFormatter;
    NSISO8601DateFormatter *_timestampParser;
}

+ (instancetype)sharedWriter {
    static GLCloudFileWriter *writer;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        writer = [[GLCloudFileWriter alloc] init];
    });
    return writer;
}

- (instancetype)initWithDocumentsURL:(NSURL *)documentsURL {
    self = [self init];
    if(self) _documentsURL = documentsURL;
    return self;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("me.joshpatra.WhereWolf.cloudfiles", DISPATCH_QUEUE_SERIAL);

        _dailyPathFormatter = [[NSDateFormatter alloc] init];
        _dailyPathFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        _dailyPathFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        _dailyPathFormatter.dateFormat = @"yyyy/MM/yyyy-MM-dd'.geojson'";

        _timestampParser = [[NSISO8601DateFormatter alloc] init];
    }
    return self;
}

+ (NSString *)setupInstructions {
    return @"In the Settings app, tap your name, then iCloud. Make sure iCloud Drive is turned on, and that WhereWolf is turned on in the list of apps using iCloud.";
}

+ (BOOL)isAvailable {
    id enabled = [NSBundle.mainBundle objectForInfoDictionaryKey:@"WhereWolfICloudEnabled"];
    return (!enabled || [enabled boolValue]) && [NSFileManager defaultManager].ubiquityIdentityToken != nil;
}

- (void)writeFeatures:(NSArray<NSDictionary *> *)features mode:(GLCloudFileMode)mode completion:(void (^)(NSString *))completion {
    dispatch_async(_queue, ^{
        NSString *errorMessage = [self saveFeatures:features mode:mode];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(errorMessage);
        });
    });
}

#pragma mark - Private, on the writer's queue

// The Documents folder of the app's iCloud container, which appears in iCloud Drive as "WhereWolf".
// Looking up the container can block, so this runs on the writer's queue.
- (NSURL *)documentsURL {
    if (_documentsURL == nil) {
        id enabled = [NSBundle.mainBundle objectForInfoDictionaryKey:@"WhereWolfICloudEnabled"];
        if(enabled && ![enabled boolValue]) return nil;
        NSURL *container = [[NSFileManager defaultManager] URLForUbiquityContainerIdentifier:([NSBundle.mainBundle objectForInfoDictionaryKey:@"WhereWolfCloudContainer"] ?: @"iCloud.me.joshpatra.WhereWolf")];
        if (container) {
            _documentsURL = [container URLByAppendingPathComponent:@"Documents" isDirectory:YES];
        }
    }
    return _documentsURL;
}

- (NSString *)saveFeatures:(NSArray<NSDictionary *> *)features mode:(GLCloudFileMode)mode {
    NSURL *documents = [self documentsURL];
    if (documents == nil) {
        return [@"iCloud Drive isn't available. " stringByAppendingString:[GLCloudFileWriter setupInstructions]];
    }

    // Group the features by file, keeping the order they were recorded in
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableArray *> *featuresByPath = [NSMutableDictionary dictionary];
    for (NSDictionary *feature in features) {
        NSString *path = [self relativePathForFeature:feature mode:mode];
        if (path == nil) {
            // Not saved in this mode, such as a point outside a trip
            continue;
        }
        if (featuresByPath[path] == nil) {
            featuresByPath[path] = [NSMutableArray array];
            [paths addObject:path];
        }
        [featuresByPath[path] addObject:feature];
    }

    for (NSString *path in paths) {
        NSString *errorMessage = [self appendFeatures:featuresByPath[path] toURL:[documents URLByAppendingPathComponent:path]];
        if (errorMessage) {
            return errorMessage;
        }
    }
    return nil;
}

// The file a feature belongs in, relative to the Documents folder, or nil if it isn't saved
- (NSString *)relativePathForFeature:(NSDictionary *)feature mode:(GLCloudFileMode)mode {
    NSDictionary *properties = feature[@"properties"];
    if (![properties isKindOfClass:[NSDictionary class]]) {
        properties = nil;
    }

    if (mode == GLCloudFileModeTrips) {
        // Points in a trip have trip_id, and the record written when the trip ends has the same start
        id tripStart = [properties[@"type"] isEqual:@"trip"] ? properties[@"start"] : properties[@"trip_id"];
        if (![tripStart isKindOfClass:[NSString class]] || [tripStart length] == 0) {
            return nil;
        }
        // Colons aren't allowed in file names
        NSString *name = [[tripStart stringByReplacingOccurrencesOfString:@":" withString:@"-"]
                          stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
        return [NSString stringWithFormat:@"Trips/%@.geojson", name];
    }

    NSDate *date = nil;
    if ([properties[@"timestamp"] isKindOfClass:[NSString class]]) {
        date = [_timestampParser dateFromString:properties[@"timestamp"]];
        if(!date) {
            NSISO8601DateFormatter *fractional = [[NSISO8601DateFormatter alloc] init];
            fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
            date = [fractional dateFromString:properties[@"timestamp"]];
        }
    }
    return [_dailyPathFormatter stringFromDate:date ?: [NSDate date]];
}

- (NSString *)appendFeatures:(NSArray<NSDictionary *> *)features toURL:(NSURL *)url {
    for(NSDictionary *feature in features) {
        if(![feature[@"type"] isEqual:@"Feature"] || ![NSJSONSerialization isValidJSONObject:feature]) {
            return @"The queued data cannot be represented as GeoJSON. The queue has been retained.";
        }
    }
    NSError *error;
    if(![NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:&error]) return error.localizedDescription;
    __block NSString *message;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForMerging error:&error byAccessor:^(NSURL *writeURL) {
        NSMutableArray *all = [NSMutableArray array];
        NSMutableSet *identifiers = [NSMutableSet set];
        if([NSFileManager.defaultManager fileExistsAtPath:writeURL.path]) {
            NSData *data = [NSData dataWithContentsOfURL:writeURL];
            id existing = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if(![existing isKindOfClass:NSDictionary.class] || ![existing[@"type"] isEqual:@"FeatureCollection"]
               || ![existing[@"features"] isKindOfClass:NSArray.class]) {
                message = @"An existing iCloud file could not be read. It and the queued points have been retained.";
                return;
            }
            [all addObjectsFromArray:existing[@"features"]];
            for(id feature in all) {
                if([feature isKindOfClass:NSDictionary.class] && [feature[@"id"] isKindOfClass:NSString.class]) {
                    [identifiers addObject:feature[@"id"]];
                }
            }
        }
        for(NSDictionary *feature in features) {
            NSString *identifier = [feature[@"id"] isKindOfClass:NSString.class] ? feature[@"id"] : nil;
            if(identifier && [identifiers containsObject:identifier]) continue;
            [all addObject:feature];
            if(identifier) [identifiers addObject:identifier];
        }
        NSError *writeError;
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"type": @"FeatureCollection", @"features": all} options:0 error:&writeError];
        if(!data || ![data writeToURL:writeURL options:NSDataWritingAtomic error:&writeError]) message = writeError.localizedDescription ?: @"The iCloud file could not be saved.";
    }];
    return error.localizedDescription ?: message;
}

@end
