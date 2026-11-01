#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface GLLocationHealthPolicy : NSObject
@property (nonatomic) NSTimeInterval retryAfter;
@property (nonatomic, readonly) NSUInteger attempts;
@property (nonatomic, readonly) BOOL expected;
- (void)setExpected:(BOOL)expected uptime:(NSTimeInterval)uptime;
- (void)resetAtUptime:(NSTimeInterval)uptime;
- (void)observeLocations:(NSArray<CLLocation *> *)locations uptime:(NSTimeInterval)uptime date:(NSDate *)date;
- (void)recordSaved:(NSUInteger)saved rejected:(NSDictionary<NSString *, NSNumber *> *)rejected
             uptime:(NSTimeInterval)uptime date:(NSDate *)date;
- (BOOL)evaluateAtUptime:(NSTimeInterval)uptime date:(NSDate *)date automaticRetry:(BOOL)retry;
- (NSDictionary<NSString *, id> *)snapshotAtUptime:(NSTimeInterval)uptime;
- (NSArray<NSDictionary *> *)takeEvents;
@end

@interface GLLocationHealthLog : NSObject
- (instancetype)initWithDirectory:(NSURL *)directory;
- (void)append:(NSDictionary *)event;
- (void)load:(void (^)(NSArray<NSDictionary *> *events))completion;
- (void)clear:(void (^)(void))completion;
@end

@interface GLLocationSaveAllowance : NSObject
- (instancetype)initWithBegin:(UIBackgroundTaskIdentifier (^)(void (^expiration)(void)))begin
                          end:(void (^)(UIBackgroundTaskIdentifier identifier))end NS_DESIGNATED_INITIALIZER;
- (void)finish;
@end

NS_ASSUME_NONNULL_END
