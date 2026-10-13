#import <UIKit/UIKit.h>
#import "EngineSession.h"
NS_ASSUME_NONNULL_BEGIN
// Main-thread owner of the mobile frame clock and audio/scene pause policy.
// The caller stops this driver before draining GPU work/destroying the engine.
@interface AetherMobileSessionDriver : NSObject
@property(nonatomic, readonly) uint32_t pauseReasons;
@property(nonatomic, copy, nullable) void (^tick)(uint32_t deltaMS);
@property(nonatomic, copy, nullable) void (^willPause)(void);
@property(nonatomic, copy, nullable) void (^stateChanged)(uint32_t reasons);
- (instancetype)initWithSession:(AetherEngineSession *)session scene:(UIWindowScene *)scene;
- (BOOL)start:(NSError **)error;
- (void)stop;
- (void)setSystemModalPresented:(BOOL)presented;
// A user action only clears the route/denied-resume/activation-failure reasons.
// It cannot override an active scene or audio interruption.
- (void)requestUserResume;
@end
NS_ASSUME_NONNULL_END
