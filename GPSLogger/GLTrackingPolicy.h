#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

typedef NS_ENUM(NSInteger, GLMovementState) {
    GLMovementUnknown,
    GLMovementStationary,
    GLMovementMoving
};

@interface GLAdaptivePolicy : NSObject
@property (nonatomic, readonly) BOOL stationary;
@property (nonatomic, readonly) CLLocation *anchor;
- (BOOL)observeLocation:(CLLocation *)location motion:(GLMovementState)motion now:(NSDate *)now
                 dwell:(NSTimeInterval)dwell radius:(CLLocationDistance)radius
           maxAccuracy:(CLLocationAccuracy)accuracy requireMotion:(BOOL)requireMotion;
- (BOOL)movementDetected;
- (void)reset;
@end

@interface GLPointQualityPolicy : NSObject
- (BOOL)acceptLocation:(CLLocation *)location relativeTo:(CLLocation *)previous
          maximumSpeed:(CLLocationSpeed)speed;
- (void)reset;
@end

@interface GLPointSelection : NSObject
+ (BOOL)acceptLocation:(CLLocation *)location previous:(CLLocation *)previous
             anyLimit:(BOOL)anyLimit distance:(CLLocationDistance)distance
              seconds:(NSTimeInterval)seconds turn:(CLLocationDirection)turn;
@end
