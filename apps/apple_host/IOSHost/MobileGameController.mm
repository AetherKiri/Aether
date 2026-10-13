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
    id _disconnectObserver;
    CGRect _previousCanvasFrame;
#if DEBUG
    uint64_t _keyEvents, _pointerEvents;
#endif
}
- (instancetype)initWithGameURL:(NSURL *)game {
    if ((self = [super init])) {_game = game; _engineOptions=@{}; _gameCanvasLabel=@"Game image"; _gameCanvasHint=@"";}
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor;
    _canvas = [AetherMobileCanvas new]; _canvas.contentMode = UIViewContentModeScaleAspectFit;
    _canvas.userInteractionEnabled = YES; _canvas.multipleTouchEnabled = YES;
    _canvas.translatesAutoresizingMaskIntoConstraints = NO;
    _canvas.virtualMouse=self.virtualMouseMode;
    _canvas.isAccessibilityElement=YES; _canvas.accessibilityTraits=UIAccessibilityTraitImage;
    _canvas.accessibilityIdentifier=@"mobile.game.canvas";
    _canvas.accessibilityLabel=self.gameCanvasLabel; _canvas.accessibilityHint=self.gameCanvasHint;
#if DEBUG
    _canvas.accessibilityValue=@"key=0 pointer=0";
#endif
    [self.view addSubview:_canvas];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_canvas.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_canvas.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_canvas.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_canvas.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]]];
    __weak AetherMobileGameController *weakSelf = self;
    _canvas.inputInvalidated = ^{if (weakSelf.inputWillReset) weakSelf.inputWillReset();};
    _canvas.pointer = ^(uint32_t type, CGPoint p, int32_t modifiers) {
        AetherMobileGameController *owner = weakSelf;
        if (!owner || !owner->_session ||
            (owner->_driver.pauseReasons && !(modifiers & ENGINE_INPUT_MODIFIER_POINTER_CANCEL))) return;
        [owner->_session sendPointerEventWithType:type pointerId:0 x:p.x y:p.y deltaX:0 deltaY:0 button:0 modifiers:modifiers | owner.hostInputModifiers];
        [owner didSendHostInput:@{@"type":@(type),@"x":@(p.x),@"y":@(p.y),@"modifiers":@(modifiers | owner.hostInputModifiers)}];
    };
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
#if DEBUG
    _canvas.accessibilityLabel=[NSString stringWithFormat:@"%@ font=%@",self.gameCanvasLabel,self.traitCollection.preferredContentSizeCategory];
#endif
    if (!CGRectEqualToRect(_canvas.frame,_previousCanvasFrame)) [self cancelHostInput];
    _previousCanvasFrame=_canvas.frame;
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [self cancelHostInput]; [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_closed || _session) return;
    UIWindowScene *scene=self.view.window.windowScene;
    if (!scene) { [self fail:@"An owning window scene is required"]; return; }
    if (self.sceneReady) self.sceneReady(scene);
    __weak AetherMobileGameController *weakController=self;
    _disconnectObserver=[NSNotificationCenter.defaultCenter addObserverForName:UISceneDidDisconnectNotification
        object:scene queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            [weakController stop];
        }];
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
    _driver = [[AetherMobileSessionDriver alloc] initWithSession:_session scene:scene];
    __weak AetherMobileGameController *weakSelf = self;
    _driver.tick = ^(uint32_t delta) { [weakSelf tick:delta]; };
    _driver.willPause = ^{ AetherMobileGameController *owner = weakSelf; if (owner) [owner cancelHostInput]; };
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
- (void)didSendHostInput:(NSDictionary<NSString *,NSNumber *> *)event {
#if DEBUG
    if (event[@"type"].unsignedIntValue <= ENGINE_INPUT_EVENT_POINTER_SCROLL) ++_pointerEvents; else ++_keyEvents;
    _canvas.accessibilityValue=[NSString stringWithFormat:@"key=%llu pointer=%llu",_keyEvents,_pointerEvents];
#endif
    if (self.hostInputObserved) self.hostInputObserved(event);
}
- (BOOL)inputAvailable {return _session && !_closed && _driver && !_driver.pauseReasons;}
- (BOOL)sendHostKeyPressed:(BOOL)pressed keyCode:(int32_t)key modifiers:(int32_t)modifiers {
    if (!_session || (pressed && !self.inputAvailable)) return NO;
    [_session sendKeyEvent:pressed keyCode:key modifiers:modifiers unicode:0];
    [self didSendHostInput:@{@"type":@(pressed ? ENGINE_INPUT_EVENT_KEY_DOWN : ENGINE_INPUT_EVENT_KEY_UP),@"key":@(key),@"modifiers":@(modifiers)}];
    return YES;
}
- (void)sendEnter {
    if (!self.inputAvailable) return;
    [self sendHostKeyPressed:YES keyCode:0x0D modifiers:self.hostInputModifiers];
    [self sendHostKeyPressed:NO keyCode:0x0D modifiers:self.hostInputModifiers];
}
- (void)cancelHostInput {
#if DEBUG
    if (self.hostInputModifiers) NSLog(@"IOS held input reset reasons=%u previous=%@ current=%@",_driver.pauseReasons,NSStringFromCGRect(_previousCanvasFrame),NSStringFromCGRect(_canvas.frame));
#endif
    [_canvas cancelPointer]; if (self.inputWillReset) self.inputWillReset();
}
- (void)setVirtualMouseMode:(BOOL)mouse {_virtualMouseMode=mouse; _canvas.virtualMouse=mouse;}
- (void)moveVirtualCursorBy:(CGSize)delta {
    if (!self.inputAvailable || !self.virtualMouseMode || CGRectIsEmpty(_canvas.contentRect)) return;
    CGPoint p=[_canvas moveCursorBy:delta];
    if (_canvas.pointer) _canvas.pointer(ENGINE_INPUT_EVENT_POINTER_MOVE,p,0);
}
- (void)clickVirtualCursor {
    if (!self.inputAvailable || !self.virtualMouseMode || CGRectIsEmpty(_canvas.contentRect)) return;
    CGPoint p=_canvas.cursorPosition;
    if (_canvas.pointer) {_canvas.pointer(ENGINE_INPUT_EVENT_POINTER_DOWN,p,0); _canvas.pointer(ENGINE_INPUT_EVENT_POINTER_UP,p,0);}
}
- (CGRect)inputContentRect {return _canvas.contentRect;}
- (CGSize)logicalCanvasSize {return _canvas.canvas;}
- (CGPoint)virtualCursorPosition {return _canvas.cursorPosition;}
- (void)resumeAudio { [_driver requestUserResume]; }
- (void)setSystemModalPresented:(BOOL)presented { [_driver setSystemModalPresented:presented]; }
- (uint64_t)softwareFrameCount { return _softwareFrames; }
- (uint64_t)submittedMetalFrames { return _presenter.submittedFrames; }
- (NSString *)metalDiagnostics { return _session ? [_session metalBridgeDiagnostics] : _finalMetalDiagnostics ?: @""; }
- (void)stop {
    if (_closed) return;
    _closed=YES;
    if (_disconnectObserver) { [NSNotificationCenter.defaultCenter removeObserver:_disconnectObserver]; _disconnectObserver=nil; }
    [self cancelHostInput]; [_driver stop]; _driver=nil;
    if (_session) {
        uint64_t frames=_presenter.submittedFrames;
        [_presenter stop]; [_presenter.view removeFromSuperview]; _presenter=nil;
        AetherMetalBridgeDrain(); [_session shutdown];
        _finalMetalDiagnostics=[_session metalBridgeDiagnostics];
        NSLog(@"IOS stopped submitted=%llu %@",frames,_finalMetalDiagnostics);
        _session=nil;
    }
    _canvas.image=nil;
    if (self.didClose) self.didClose();
}
- (void)dealloc { [self stop]; }
@end
