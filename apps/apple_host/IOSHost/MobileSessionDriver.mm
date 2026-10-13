#import "MobileSessionDriver.h"
#import <AVFAudio/AVFAudio.h>
#import <QuartzCore/QuartzCore.h>
#include "SessionTiming.h"
using namespace aether::mobile;

@interface AetherMobileClockTarget : NSObject
@property(nonatomic, weak) AetherMobileSessionDriver *driver;
- (void)display:(CADisplayLink *)link;
@end
@interface AetherMobileSessionDriver ()
- (void)display:(CADisplayLink *)link;
- (void)applyReasons:(uint32_t)reasons;
@end
@implementation AetherMobileClockTarget
- (void)display:(CADisplayLink *)link { [self.driver display:link]; }
@end

@implementation AetherMobileSessionDriver {
    AetherEngineSession *_session;
    __weak UIWindowScene *_scene;
    CADisplayLink *_link;
    NSMutableArray<id> *_observers;
    SessionTiming _timing;
    uint64_t _generation;
    BOOL _started;
}
- (instancetype)initWithSession:(AetherEngineSession *)session scene:(UIWindowScene *)scene {
    if ((self = [super init])) { _session = session; _scene = scene; _observers = [NSMutableArray new]; }
    return self;
}
- (uint32_t)pauseReasons { return _timing.reasons(); }
- (BOOL)start:(NSError **)error {
    NSAssert(NSThread.isMainThread, @"mobile lifecycle belongs to the main thread");
    if (_started) return YES;
    if (!_scene || !_session.borrowedEngineHandle) {
        if (error) *error = [NSError errorWithDomain:@"AetherMobileSessionDriver" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"An owning scene and live engine session are required"}];
        return NO;
    }
    // Foreground playback, including with the silent switch on. No background
    // audio entitlement; runtime owns OpenAL and the shared activation helper.
    if (![AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback
                                              mode:AVAudioSessionModeDefault options:0 error:error]) return NO;
    uint32_t initialReasons = _scene.activationState == UISceneActivationStateForegroundActive ? 0 : sceneInactive;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) initialReasons |= applicationInactive;
    if (!initialReasons && ![_session activateHostAudioSession:error]) return NO;
    _started = YES; ++_generation; _timing.start();
    _timing.setReasons(initialReasons);
    __weak AetherMobileSessionDriver *weakSelf = self;
    uint64_t generation = _generation;
    void (^observe)(NSNotificationName, id, void (^)(AetherMobileSessionDriver *, NSNotification *)) =
    ^(NSNotificationName name, id object, void (^body)(AetherMobileSessionDriver *, NSNotification *)) {
        id token = [NSNotificationCenter.defaultCenter addObserverForName:name object:object queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            AetherMobileSessionDriver *owner = weakSelf;
            if (!owner || !owner->_started || owner->_generation != generation) return;
            body(owner, note);
        }];
        [self->_observers addObject:token];
    };
    observe(UISceneWillDeactivateNotification, _scene, ^(AetherMobileSessionDriver *owner, NSNotification *note) {
        [owner applyReasons:owner.pauseReasons | sceneInactive];
    });
    observe(UISceneDidActivateNotification, _scene, ^(AetherMobileSessionDriver *owner, NSNotification *note) {
        [owner applyReasons:owner.pauseReasons & ~sceneInactive];
    });
    observe(UIApplicationDidBecomeActiveNotification, nil, ^(AetherMobileSessionDriver *owner, NSNotification *note) {
        [owner applyReasons:owner.pauseReasons & ~applicationInactive];
    });
    observe(UIApplicationWillResignActiveNotification, nil, ^(AetherMobileSessionDriver *owner, NSNotification *note) {
        [owner applyReasons:owner.pauseReasons | applicationInactive];
    });
    observe(AVAudioSessionInterruptionNotification, AVAudioSession.sharedInstance, ^(AetherMobileSessionDriver *owner, NSNotification *note) {
        NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
        if (!type) return;
        if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan) {
            [owner applyReasons:owner.pauseReasons | audioInterruption];
        } else if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
            NSUInteger options = [note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
            uint32_t next = owner.pauseReasons & ~audioInterruption;
            if (!(options & AVAudioSessionInterruptionOptionShouldResume)) next |= userResumeRequired;
            [owner applyReasons:next];
        }
    });
    observe(AVAudioSessionRouteChangeNotification, AVAudioSession.sharedInstance, ^(AetherMobileSessionDriver *owner, NSNotification *note) {
        if ([note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue] == AVAudioSessionRouteChangeReasonOldDeviceUnavailable)
            [owner applyReasons:owner.pauseReasons | userResumeRequired];
    });
    observe(AVAudioSessionMediaServicesWereLostNotification, AVAudioSession.sharedInstance, ^(AetherMobileSessionDriver *owner, NSNotification *note) {
        [owner applyReasons:owner.pauseReasons | audioServicesLost];
    });
    observe(AVAudioSessionMediaServicesWereResetNotification, AVAudioSession.sharedInstance, ^(AetherMobileSessionDriver *owner, NSNotification *note) {
        // Keep paused for explicit user recovery; OpenAL reconstruction after a
        // media-server reset is a separately verified runtime requirement.
        [owner applyReasons:owner.pauseReasons | audioServicesLost];
    });
    AetherMobileClockTarget *target = [AetherMobileClockTarget new]; target.driver = self;
    _link = [CADisplayLink displayLinkWithTarget:target selector:@selector(display:)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    _link.paused = !_timing.ticking();
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    if (!_timing.ticking()) { if (self.willPause) self.willPause(); engine_pause(_session.borrowedEngineHandle); }
    NSLog(@"MOBILE session started generation=%llu reasons=%u", _generation, self.pauseReasons);
    return YES;
}
- (void)applyReasons:(uint32_t)reasons {
    BOOL wasTicking = _timing.ticking();
    _timing.setReasons(reasons);
    if (wasTicking && !_timing.ticking()) {
        if (self.willPause) self.willPause();
        engine_result_t result = engine_pause(_session.borrowedEngineHandle);
        NSLog(@"MOBILE pause generation=%llu reasons=%u result=%d", _generation, reasons, result);
    } else if (!wasTicking && _timing.ticking()) {
        NSError *error = nil;
        engine_result_t result = ENGINE_RESULT_INTERNAL_ERROR;
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
            _timing.setReasons(reasons | applicationInactive);
        } else {
            if ([_session activateHostAudioSession:&error]) result = engine_resume(_session.borrowedEngineHandle);
            if (result != ENGINE_RESULT_OK) _timing.setReasons(reasons | audioUnavailable);
        }
        NSLog(@"MOBILE resume generation=%llu reasons=%u result=%d error=%@", _generation, self.pauseReasons, result, error);
    }
    _link.paused = !_timing.ticking();
    if (self.stateChanged) self.stateChanged(self.pauseReasons);
}
- (void)setSystemModalPresented:(BOOL)presented {
    NSAssert(NSThread.isMainThread, @"mobile lifecycle belongs to the main thread");
    if (!_started) return;
    [self applyReasons:presented ? self.pauseReasons | systemModal : self.pauseReasons & ~systemModal];
}
- (void)requestUserResume {
    NSAssert(NSThread.isMainThread, @"mobile lifecycle belongs to the main thread");
    if (!_started) return;
    [self applyReasons:self.pauseReasons & ~(userResumeRequired | audioUnavailable)];
}
- (void)display:(CADisplayLink *)link {
    auto delta = _timing.delta(link.timestamp);
    if (delta && self.tick) self.tick(*delta);
}
- (void)stop {
    if (_started && self.willPause) self.willPause();
    ++_generation; _started = NO;
    [_link invalidate]; _link = nil;
    for (id token in _observers) [NSNotificationCenter.defaultCenter removeObserver:token];
    [_observers removeAllObjects]; _timing.stop();
}
- (void)dealloc { [self stop]; }
@end
