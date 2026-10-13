#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface AetherMobileGameController : UIViewController
@property(nonatomic, copy, nullable) void (^statusChanged)(NSString *status);
@property(nonatomic, copy, nullable) void (^failed)(NSString *message);
- (instancetype)initWithGameURL:(NSURL *)game;
- (void)sendEnter;
- (void)resumeAudio;
- (void)setSystemModalPresented:(BOOL)presented;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
