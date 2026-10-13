#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface AetherMobileGameController : UIViewController
@property(nonatomic, copy, nullable) void (^statusChanged)(NSString *status);
@property(nonatomic, copy, nullable) void (^failed)(NSString *message);
@property(nonatomic, copy, nullable) void (^presentationFallback)(NSString *localizationKey);
@property(nonatomic, copy, nullable) void (^sceneReady)(UIWindowScene *scene);
@property(nonatomic, copy, nullable) void (^didClose)(void);
@property(nonatomic, copy, nullable) void (^inputWillReset)(void);
@property(nonatomic, copy, nullable) void (^hostInputObserved)(NSDictionary<NSString *,NSNumber *> *event);
@property(nonatomic, copy) NSString *gameCanvasLabel;
@property(nonatomic, copy) NSString *gameCanvasHint;
@property(nonatomic) int32_t hostInputModifiers;
@property(nonatomic) BOOL virtualMouseMode;
@property(nonatomic, readonly) BOOL inputAvailable;
@property(nonatomic) BOOL prefersSoftwareRendering;
@property(nonatomic, copy) NSDictionary<NSString *,NSString *> *engineOptions;
- (instancetype)initWithGameURL:(NSURL *)game;
- (void)sendEnter;
- (BOOL)sendHostKeyPressed:(BOOL)pressed keyCode:(int32_t)key modifiers:(int32_t)modifiers NS_SWIFT_NAME(sendHostKey(pressed:keyCode:modifiers:));
- (void)cancelHostInput;
- (void)moveVirtualCursorBy:(CGSize)delta;
- (void)clickVirtualCursor;
- (CGRect)inputContentRect;
- (CGSize)logicalCanvasSize;
- (CGPoint)virtualCursorPosition;
- (void)resumeAudio;
- (void)setSystemModalPresented:(BOOL)presented;
- (uint64_t)softwareFrameCount;
- (uint64_t)submittedMetalFrames;
- (NSString *)metalDiagnostics;
- (void)stop;
@end
NS_ASSUME_NONNULL_END
