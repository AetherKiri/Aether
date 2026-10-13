#import <MetalKit/MetalKit.h>
#import "MetalBridge.h"
NS_ASSUME_NONNULL_BEGIN
// Original-size engine frame -> drawable aspect fit; no CPU readback.
// Producer and presentation use the same bridge queue and lease submit boundary.
@interface AetherMobileMetalPresenter : NSObject <MTKViewDelegate>
@property(nonatomic, readonly) MTKView *view;
@property(nonatomic, readonly, nullable) NSString *lastError;
@property(nonatomic, readonly) uint64_t submittedFrames;
- (nullable instancetype)initWithError:(NSError **)error;
- (void)presentFrame:(nullable AetherMetalFrameLease *)frame;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
