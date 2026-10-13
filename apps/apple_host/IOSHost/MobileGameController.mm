#import "MobileGameController.h"
#import "MobileGameCanvas.h"
#import "MobileSessionDriver.h"
#import "MobileMetalPresenter.h"
#import <QuartzCore/QuartzCore.h>
extern "C" uint32_t aether_apple_host_core_initialize(void);

@implementation AetherMobileGameController {
    NSURL *_game;
    AetherMobileCanvas *_canvas;
    AetherEngineSession *_session;
    AetherMobileSessionDriver *_driver;
    AetherMobileMetalPresenter *_presenter;
    BOOL _native;
    BOOL _closed;
    BOOL _seenFrame;
    CFTimeInterval _lastStatus;
    NSString *_finalMetalDiagnostics;
    uint64_t _softwareFrames;
}
- (instancetype)initWithGameURL:(NSURL *)game {
    if ((self = [super init])) {_game = game; _engineOptions=@{};}
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
    for (NSString *key in self.engineOptions) {
        if (![_session setOption:key value:self.engineOptions[key] error:&error]) {
            [self fail:error.localizedDescription]; return;
        }
    }
    BOOL forceSoftware=self.prefersSoftwareRendering;
#if DEBUG
    forceSoftware=forceSoftware || [NSProcessInfo.processInfo.environment[@"AETHER_IOS_SOFTWARE"] isEqualToString:@"1"];
#endif
    if (!forceSoftware && [_session enableMetalRenderer:&error]) {
        _presenter=[[AetherMobileMetalPresenter alloc] initWithError:&error];
        if (_presenter) {
            _native=YES;
            MTKView *metal=_presenter.view; metal.translatesAutoresizingMaskIntoConstraints=NO;
            [self.view insertSubview:metal belowSubview:_canvas];
            [NSLayoutConstraint activateConstraints:@[
                [metal.leadingAnchor constraintEqualToAnchor:_canvas.leadingAnchor],
                [metal.trailingAnchor constraintEqualToAnchor:_canvas.trailingAnchor],
                [metal.topAnchor constraintEqualToAnchor:_canvas.topAnchor],
                [metal.bottomAnchor constraintEqualToAnchor:_canvas.bottomAnchor]]];
        }
    }
    if (!_native) {
        NSLog(@"IOS Metal unavailable; using software: %@",error);
        if (!forceSoftware && self.presentationFallback) self.presentationFallback(@"metalPresenterUnavailable");
        if (![_session setOption:@"renderer" value:@"software" error:&error]) { [self fail:error.localizedDescription]; return; }
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
    if (_presenter.lastError) {
        NSLog(@"IOS Metal presentation fallback: %@",_presenter.lastError);
        [_presenter stop]; [_presenter.view removeFromSuperview]; _presenter=nil; _native=NO;
        AetherMetalBridgeDrain();
        if (self.presentationFallback) self.presentationFallback(@"metalPresentationFailed");
    }
    if (_native) {
        AetherMetalFrameLease *frame=[_session acquireNativeFrame];
        if (frame) {
            CGSize size=CGSizeMake(frame.texture.width,frame.texture.height);
            if (!CGSizeEqualToSize(size,_canvas.canvas)) {
                [_canvas cancelPointer]; _canvas.canvas=size;
                [_session setSurfaceSize:(uint32_t)size.width height:(uint32_t)size.height error:nil];
            }
            if (!_seenFrame) { _seenFrame=YES; NSLog(@"IOS product first frame metal %.0fx%.0f",size.width,size.height); }
        }
        [_presenter presentFrame:frame];
    }
    CGImageRef image = _native ? nil : [_session copyFrameImage];
    if (image) {
        ++_softwareFrames;
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
- (uint64_t)softwareFrameCount { return _softwareFrames; }
- (uint64_t)submittedMetalFrames { return _presenter.submittedFrames; }
- (NSString *)metalDiagnostics { return _session ? [_session metalBridgeDiagnostics] : _finalMetalDiagnostics ?: @""; }
- (void)stop {
    _closed=YES; [_canvas cancelPointer]; [_driver stop]; _driver=nil;
    if (_session) {
        uint64_t frames=_presenter.submittedFrames;
        [_presenter stop]; [_presenter.view removeFromSuperview]; _presenter=nil;
        AetherMetalBridgeDrain(); [_session shutdown];
        _finalMetalDiagnostics=[_session metalBridgeDiagnostics];
        NSLog(@"IOS stopped submitted=%llu %@",frames,_finalMetalDiagnostics);
        _session=nil;
    }
    _canvas.image=nil;
}
- (void)dealloc { [self stop]; }
@end
