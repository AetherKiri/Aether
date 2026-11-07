#include "mobile_window.h"
#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static void MobileOnUI(dispatch_block_t block) {
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

// Override only the controller instance hosting Godot. A child SDL controller
// must not bring the status bar or home indicator back over a running game.
static const char FullscreenKey = 0;
static BOOL MobileFullscreen(id controller, SEL selector) {
    return [objc_getAssociatedObject(controller, &FullscreenKey) boolValue];
}
static UIViewController *MobileStatusChild(id controller, SEL selector) { return nil; }
static Class MobileControllerClass(Class base) {
    NSString *name = [@"AetherMobile_" stringByAppendingString:NSStringFromClass(base)];
    Class subclass = NSClassFromString(name);
    if (!subclass) {
        subclass = objc_allocateClassPair(base, name.UTF8String, 0);
        class_addMethod(subclass, @selector(prefersStatusBarHidden), (IMP)MobileFullscreen, "B@:");
        class_addMethod(subclass, @selector(prefersHomeIndicatorAutoHidden), (IMP)MobileFullscreen, "B@:");
        class_addMethod(subclass, @selector(childViewControllerForStatusBarHidden), (IMP)MobileStatusChild, "@@:");
        class_addMethod(subclass, @selector(childViewControllerForHomeIndicatorAutoHidden), (IMP)MobileStatusChild, "@@:");
        objc_registerClassPair(subclass);
    }
    return subclass;
}

@interface AetherPiPView : UIView
@end
@implementation AetherPiPView
+ (Class)layerClass { return AVSampleBufferDisplayLayer.class; }
@end

@interface AetherMobileWindowHost : NSObject <AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate>
@property(nonatomic, weak) UIView *gameView;
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic) Class originalControllerClass;
@property(nonatomic, strong) AetherPiPView *sourceView;
@property(nonatomic, strong) AVPictureInPictureController *pip;
@property(nonatomic, strong) NSTimer *captureTimer;
@property(nonatomic) BOOL gameActive;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL playing;
@property(nonatomic) BOOL closed;
@property(nonatomic, copy) NSString *audioCategory;
@property(nonatomic, copy) NSString *audioMode;
@property(nonatomic) AVAudioSessionCategoryOptions audioOptions;
- (void)configureGame:(BOOL)active enabled:(BOOL)enabled;
- (void)capture;
- (void)close;
@end

@implementation AetherMobileWindowHost
- (instancetype)init {
    if ((self = [super init])) {
        _playing = YES;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:self selector:@selector(willResign:) name:UIApplicationWillResignActiveNotification object:nil];
        [center addObserver:self selector:@selector(didBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}
- (void)installController {
    UIViewController *controller = self.gameView.window.rootViewController;
    if (!controller || self.controller == controller) return;
    self.controller = controller;
    self.originalControllerClass = object_getClass(controller);
    object_setClass(controller, MobileControllerClass(self.originalControllerClass));
}
- (void)updateFullscreen {
    [self installController];
    NSNumber *previous = objc_getAssociatedObject(self.controller, &FullscreenKey);
    if (previous && previous.boolValue == self.gameActive) return;
    objc_setAssociatedObject(self.controller, &FullscreenKey, @(self.gameActive), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.controller setNeedsStatusBarAppearanceUpdate];
    [self.controller setNeedsUpdateOfHomeIndicatorAutoHidden];
}
- (void)preparePiP {
    if (self.pip || ![AVPictureInPictureController isPictureInPictureSupported]) return;
    UIWindow *window = self.gameView.window;
    if (!window) return;
    self.sourceView = [[AetherPiPView alloc] initWithFrame:window.bounds];
    self.sourceView.userInteractionEnabled = NO;
    self.sourceView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // Keep the sample layer in the window while the game renders in front.
    // AVKit uses this layer as the source of its standard PiP transition.
    [window insertSubview:self.sourceView atIndex:0];
    AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)self.sourceView.layer;
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    CMTimebaseRef timebase = nil;
    if (CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &timebase) == noErr) {
        CMTimebaseSetTime(timebase, CMClockGetTime(CMClockGetHostTimeClock()));
        CMTimebaseSetRate(timebase, 1.0);
        layer.controlTimebase = timebase;
        CFRelease(timebase);
    }
    AVPictureInPictureControllerContentSource *source = [[AVPictureInPictureControllerContentSource alloc]
        initWithSampleBufferDisplayLayer:layer playbackDelegate:self];
    self.pip = [[AVPictureInPictureController alloc] initWithContentSource:source];
    self.pip.delegate = self;
    self.pip.requiresLinearPlayback = YES;
}
- (void)startCaptureTimer {
    [self.captureTimer invalidate];
    self.captureTimer = nil;
    if (!self.gameActive || !self.enabled || !self.pip ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    __weak AetherMobileWindowHost *weakSelf = self;
    self.captureTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        [weakSelf capture];
    }];
    [self capture];
}
- (void)configureGame:(BOOL)active enabled:(BOOL)enabled {
    if (self.closed) return;
    if (self.gameActive == active && self.enabled == enabled && self.controller &&
        (!(active && enabled) || self.pip)) return;
    if (active && enabled && !(self.gameActive && self.enabled)) self.playing = YES;
    self.gameActive = active;
    self.enabled = enabled;
    [self updateFullscreen];
    if (active && enabled) {
        [self preparePiP];
        if (self.pip && !self.audioCategory) {
            AVAudioSession *audio = AVAudioSession.sharedInstance;
            self.audioCategory = audio.category;
            self.audioMode = audio.mode;
            self.audioOptions = audio.categoryOptions;
            NSError *error = nil;
            [audio setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault
                options:AVAudioSessionCategoryOptionMixWithOthers error:&error];
            if (!error) [audio setActive:YES error:&error];
            if (error) NSLog(@"[AetherPiP] Audio session: %@", error.localizedDescription);
        }
    }
    self.pip.canStartPictureInPictureAutomaticallyFromInline = active && enabled;
    [self.pip invalidatePlaybackState];
    if (!active || !enabled) {
        [self.pip stopPictureInPicture];
        [(AVSampleBufferDisplayLayer *)self.sourceView.layer flushAndRemoveImage];
        if (self.audioCategory) {
            [AVAudioSession.sharedInstance setCategory:self.audioCategory mode:self.audioMode
                options:self.audioOptions error:nil];
            self.audioCategory = nil;
        }
    }
    [self startCaptureTimer];
}
- (void)capture {
    // No GPU work or view snapshots after backgrounding. AVKit keeps the last
    // submitted frame; the existing game lifecycle pauses and resumes play.
    if (!self.gameActive || !self.enabled || !self.sourceView || self.pip.isPictureInPictureActive ||
        UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    UIWindow *window = self.gameView.window;
    if (!window || window.bounds.size.width < 1 || window.bounds.size.height < 1) return;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.opaque = YES;
    format.scale = MIN(1.0, 960.0 / MAX(window.bounds.size.width, window.bounds.size.height));
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds format:format];
    __block BOOL drawn = NO;
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        drawn = [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
    }];
    if (!drawn || !image.CGImage) return;
    size_t width = CGImageGetWidth(image.CGImage), height = CGImageGetHeight(image.CGImage);
    CVPixelBufferRef pixels = nil;
    NSDictionary *attributes = @{(id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attributes, &pixels) != kCVReturnSuccess) return;
    CVPixelBufferLockBaseAddress(pixels, 0);
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixels), width, height, 8,
        CVPixelBufferGetBytesPerRow(pixels), color, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image.CGImage);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(color);
    CVPixelBufferUnlockBaseAddress(pixels, 0);
    CMVideoFormatDescriptionRef description = nil;
    CMSampleBufferRef sample = nil;
    CMSampleTimingInfo timing = {kCMTimeInvalid, CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
    if (context && CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixels, &description) == noErr &&
        CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixels, description, &timing, &sample) == noErr) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
        CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0),
            kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        AVSampleBufferDisplayLayer *layer = (AVSampleBufferDisplayLayer *)self.sourceView.layer;
        if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) [layer flush];
        if (layer.readyForMoreMediaData) [layer enqueueSampleBuffer:sample];
        CFRelease(sample);
    }
    if (description) CFRelease(description);
    CVPixelBufferRelease(pixels);
}
- (void)willResign:(NSNotification *)notification {
    [self capture];
    [self.captureTimer invalidate];
    self.captureTimer = nil;
}
- (void)didBecomeActive:(NSNotification *)notification {
    [self updateFullscreen];
    self.playing = YES;
    [self.pip invalidatePlaybackState];
    [self.pip stopPictureInPicture];
    [self.sourceView.superview sendSubviewToBack:self.sourceView];
    [self startCaptureTimer];
}
- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)controller {
    [self.sourceView.superview bringSubviewToFront:self.sourceView];
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller failedToStartPictureInPictureWithError:(NSError *)error {
    [self.sourceView.superview sendSubviewToBack:self.sourceView];
    NSLog(@"[AetherPiP] Failed to start: %@", error.localizedDescription);
}
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)controller {
    [self.sourceView.superview sendSubviewToBack:self.sourceView];
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completion {
    // AVKit brings the same scene back. Its game remains loaded and resumes
    // through the normal application-active notification.
    completion(self.gameActive && !self.closed);
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller setPlaying:(BOOL)playing {
    self.playing = playing;
    [controller invalidatePlaybackState];
}
- (BOOL)pictureInPictureControllerIsPlaybackPaused:(AVPictureInPictureController *)controller { return !self.playing; }
- (CMTimeRange)pictureInPictureControllerTimeRangeForPlayback:(AVPictureInPictureController *)controller {
    return CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity);
}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller didTransitionToRenderSize:(CMVideoDimensions)size {}
- (void)pictureInPictureController:(AVPictureInPictureController *)controller skipByInterval:(CMTime)interval completionHandler:(void (^)(void))completion { completion(); }
- (void)close {
    [self configureGame:NO enabled:NO];
    self.closed = YES;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.pip.delegate = nil;
    self.pip = nil;
    [self.sourceView removeFromSuperview];
    self.sourceView = nil;
    if (self.controller && object_getClass(self.controller) == MobileControllerClass(self.originalControllerClass)) {
        object_setClass(self.controller, self.originalControllerClass);
        objc_setAssociatedObject(self.controller, &FullscreenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self.controller setNeedsStatusBarAppearanceUpdate];
        [self.controller setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
}
@end

void *aether_mobile_window_open(uint64_t native_view) {
    __block void *handle = nullptr;
    MobileOnUI(^{
        UIView *view = (__bridge UIView *)(void *)native_view;
        if (!view) return;
        AetherMobileWindowHost *host = [AetherMobileWindowHost new];
        host.gameView = view;
        handle = (__bridge_retained void *)host;
    });
    return handle;
}
void aether_mobile_window_configure(void *handle, bool active, bool enabled) {
    MobileOnUI(^{ [(__bridge AetherMobileWindowHost *)handle configureGame:active enabled:enabled]; });
}
bool aether_mobile_window_supported(void *handle) {
    __block BOOL supported = NO;
    MobileOnUI(^{ supported = [AVPictureInPictureController isPictureInPictureSupported]; });
    return supported;
}
bool aether_mobile_window_in_pip(void *handle) {
    __block BOOL active = NO;
    MobileOnUI(^{ active = ((__bridge AetherMobileWindowHost *)handle).pip.isPictureInPictureActive; });
    return active;
}
void aether_mobile_window_close(void *handle) {
    MobileOnUI(^{
        AetherMobileWindowHost *host = (__bridge_transfer AetherMobileWindowHost *)handle;
        [host close];
    });
}
