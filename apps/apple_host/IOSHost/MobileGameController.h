#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface AetherMobileGameController : UIViewController
@property(nonatomic, copy, nullable) void (^statusChanged)(NSString *status);
@property(nonatomic, copy, nullable) void (^failed)(NSString *message);
@property(nonatomic, copy, nullable) void (^presentationFallback)(NSString *localizationKey);
@property(nonatomic, copy, nullable) void (^sceneReady)(UIWindowScene *scene);
@property(nonatomic, copy, nullable) void (^didClose)(void);
@property(nonatomic) BOOL prefersSoftwareRendering;
@property(nonatomic, copy) NSDictionary<NSString *,NSString *> *engineOptions;
- (instancetype)initWithGameURL:(NSURL *)game;
- (void)sendEnter;
- (void)resumeAudio;
- (void)setSystemModalPresented:(BOOL)presented;
- (uint64_t)softwareFrameCount;
- (uint64_t)submittedMetalFrames;
- (NSString *)metalDiagnostics;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
