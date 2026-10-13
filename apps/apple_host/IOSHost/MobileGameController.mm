#import "MobileGameController.h"
#import "MobileGameCanvas.h"
#import "MobileSessionDriver.h"
#import <QuartzCore/QuartzCore.h>
extern "C" uint32_t aether_apple_host_core_initialize(void);

@implementation AetherMobileGameController {
    NSURL *_game;
    AetherMobileCanvas *_canvas;
    AetherEngineSession *_session;
    AetherMobileSessionDriver *_driver;
    BOOL _closed;
    BOOL _seenFrame;
    CFTimeInterval _lastStatus;
}
- (instancetype)initWithGameURL:(NSURL *)game {
    if ((self = [super init])) _game = game;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor;
    _canvas = [AetherMobileCanvas new]; _canvas.contentMode = UIViewContentModeScaleAspectFit;
    _canvas.userInteractionEnabled = YES; _canvas.multipleTouchEnabled = YES;
    _canvas.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_canvas];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_canvas.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_canvas.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_canvas.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_canvas.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]]];
    __weak AetherMobileGameController *weakSelf = self;
    _canvas.pointer = ^(uint32_t type, CGPoint p, int32_t modifiers) {
        AetherMobileGameController *owner = weakSelf;
        if (!owner || !owner->_session ||
            (owner->_driver.pauseReasons && !(modifiers & ENGINE_INPUT_MODIFIER_POINTER_CANCEL))) return;
        [owner->_session sendPointerEventWithType:type pointerId:0 x:p.x y:p.y deltaX:0 deltaY:0 button:0 modifiers:modifiers];
    };
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_closed || _session) return;
    aether_apple_host_core_initialize();
    _session = [AetherEngineSession new];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject.path;
    NSString *cache = [fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject.path;
    NSString *font = [NSBundle.mainBundle pathForResource:@"aetherkiri-runtime-cjk" ofType:@"otf"];
    NSError *error = nil;
    if (!font || ![_session initializeWithWritablePath:documents cachePath:cache error:&error] ||
        ![_session setOption:@"renderer" value:@"software" error:&error] ||
        ![_session setOption:@"frame_output" value:@"raw_source" error:&error] ||
        ![_session setOption:@"default_font" value:font error:&error]) {
        [self fail:error.localizedDescription ?: @"Missing runtime font"]; return;
    }
    _driver = [[AetherMobileSessionDriver alloc] initWithSession:_session scene:self.view.window.windowScene];
    __weak AetherMobileGameController *weakSelf = self;
    _driver.tick = ^(uint32_t delta) { [weakSelf tick:delta]; };
    _driver.willPause = ^{ AetherMobileGameController *owner = weakSelf; if (owner) [owner->_canvas cancelPointer]; };
    _driver.stateChanged = ^(uint32_t reasons) {
        AetherMobileGameController *owner = weakSelf;
        if (owner.statusChanged) owner.statusChanged((reasons & (1u << 5)) ? @"restartRequired" : reasons ? @"paused" : @"running");
    };
    if (![_driver start:&error] || ![_session openGameAtPath:_game.path error:&error]) {
        [self fail:error.localizedDescription ?: @"Engine start failed"]; return;
    }
    NSLog(@"IOS product game started api=%u", _session.engineAPIVersion);
}
- (void)tick:(uint32_t)delta {
    [_session tickWithDeltaMS:delta];
    CGImageRef image = [_session copyFrameImage];
    if (image) {
        CGSize size = CGSizeMake(CGImageGetWidth(image),CGImageGetHeight(image));
        if (!_seenFrame) { _seenFrame=YES; NSLog(@"IOS product first frame software %.0fx%.0f",size.width,size.height); }
        if (!CGSizeEqualToSize(size,_canvas.canvas)) {
            _canvas.canvas=size;
            [_session setSurfaceSize:(uint32_t)size.width height:(uint32_t)size.height error:nil];
        }
        _canvas.image = [UIImage imageWithCGImage:image]; CGImageRelease(image);
    }
    if (_session.startupState == ENGINE_STARTUP_STATE_FAILED) { [self fail:_session.lastError]; return; }
    CFTimeInterval now=CACurrentMediaTime();
    if (now-_lastStatus > 0.25) {
        _lastStatus=now;
        if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"%.0f×%.0f",_canvas.canvas.width,_canvas.canvas.height]);
    }
}
- (void)fail:(NSString *)message {
    [self stop]; if (self.failed) self.failed(message);
}
- (void)sendEnter {
    if (!_session || _driver.pauseReasons) return;
    [_session sendKeyEvent:YES keyCode:0x0D modifiers:0 unicode:0];
    [_session sendKeyEvent:NO keyCode:0x0D modifiers:0 unicode:0];
}
- (void)resumeAudio { [_driver requestUserResume]; }
- (void)setSystemModalPresented:(BOOL)presented { [_driver setSystemModalPresented:presented]; }
- (void)stop {
    _closed=YES; [_canvas cancelPointer]; [_driver stop]; _driver=nil;
    if (_session) { AetherMetalBridgeDrain(); [_session shutdown]; _session=nil; }
    _canvas.image=nil;
}
- (void)dealloc { [self stop]; }
@end
