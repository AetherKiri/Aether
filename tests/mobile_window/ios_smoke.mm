// Link with the production mobile_window_ios.mm. This CPU fixture exercises
// the actual AVKit host without loading game assets or Godot's GPU renderer.
#include "mobile_window.h"
#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#include <vector>

namespace {
struct Fixture {
    bool paused = false, background = false;
    uint64_t ticks = 0, background_ticks = 0, elapsed_ms = 0, pauses = 0, resumes = 0;
    std::vector<uint8_t> rgba = std::vector<uint8_t>(640 * 360 * 4, 255);
} fixture;
engine_handle_t FixtureHandle() { return reinterpret_cast<engine_handle_t>(&fixture); }
}
extern "C" engine_result_t engine_background_playback(engine_handle_t h, uint32_t mode) {
    if (h != FixtureHandle() || mode > ENGINE_BACKGROUND_PLAYBACK_LEAVE) return ENGINE_RESULT_INVALID_ARGUMENT;
    if (mode != ENGINE_BACKGROUND_PLAYBACK_QUERY) fixture.background = mode == ENGINE_BACKGROUND_PLAYBACK_ENTER;
    return ENGINE_RESULT_OK;
}
extern "C" engine_result_t engine_pause(engine_handle_t h) { fixture.paused = true; ++fixture.pauses; return ENGINE_RESULT_OK; }
extern "C" engine_result_t engine_resume(engine_handle_t h) { fixture.paused = false; ++fixture.resumes; return ENGINE_RESULT_OK; }
extern "C" engine_result_t engine_tick(engine_handle_t h, uint32_t delta) {
    if (h != FixtureHandle() || fixture.paused) return ENGINE_RESULT_INVALID_STATE;
    ++fixture.ticks; fixture.elapsed_ms += delta;
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) ++fixture.background_ticks;
    const unsigned pos = unsigned(fixture.elapsed_ms / 10 % 640);
    for (unsigned y = 0; y < 360; ++y) for (unsigned x = 0; x < 640; ++x) {
        auto* p = fixture.rgba.data() + (y*640+x)*4;
        const bool bar = x >= pos && x < pos + 40;
        p[0] = bar ? 240 : 20; p[1] = bar ? 220 : uint8_t(y/2); p[2] = bar ? 20 : 80;
    }
    return ENGINE_RESULT_OK;
}
extern "C" engine_result_t engine_get_frame_desc(engine_handle_t h, engine_frame_desc_t* d) {
    d->width=640; d->height=360; d->stride_bytes=640*4; d->pixel_format=ENGINE_PIXEL_FORMAT_RGBA8888;
    d->frame_serial=fixture.ticks; return ENGINE_RESULT_OK;
}
extern "C" engine_result_t engine_read_frame_rgba(engine_handle_t h, void* out, size_t bytes) {
    if (bytes < fixture.rgba.size()) return ENGINE_RESULT_INVALID_ARGUMENT;
    memcpy(out,fixture.rgba.data(),fixture.rgba.size()); return ENGINE_RESULT_OK;
}

@interface PiPSmoke : UIResponder <UIApplicationDelegate> { void *_host; }
@property(strong, nonatomic) UIWindow *window;
@property(strong, nonatomic) NSTimer *timer;
@property(nonatomic) CFTimeInterval started;
@end
@implementation PiPSmoke
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.started = CACurrentMediaTime();
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    self.window.rootViewController = controller;
    controller.view.backgroundColor = UIColor.systemIndigoColor;
    UILabel *label = [[UILabel alloc] initWithFrame:controller.view.bounds];
    label.text = @"Aether live Picture in Picture test\nSwitch to another app to watch the moving bar.";
    label.numberOfLines=0; label.textAlignment=NSTextAlignmentCenter; label.textColor=UIColor.whiteColor;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [controller.view addSubview:label];
    [self.window makeKeyAndVisible];
    _host = aether_mobile_window_open(uint64_t((__bridge void *)controller.view));
    aether_mobile_window_set_engine(_host,FixtureHandle());
    aether_mobile_window_configure(_host,true,true);
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer*) { [self report]; }];
    // Explicit entry also permits device automation to activate another app.
    // 'pip' is the production host's own property, not a private Apple API.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        AVPictureInPictureController *pip = [(__bridge id)self->_host valueForKey:@"pip"];
        [pip startPictureInPicture];
    });
    [self report];
    return YES;
}
- (void)report {
    NSDictionary *result = @{@"elapsed_seconds":@(CACurrentMediaTime()-self.started),
        @"ticks":@(fixture.ticks), @"background_ticks":@(fixture.background_ticks),
        @"story_ms":@(fixture.elapsed_ms), @"paused":@(fixture.paused),
        @"background_mode":@(fixture.background), @"pauses":@(fixture.pauses), @"resumes":@(fixture.resumes),
        @"pip_active":@(aether_mobile_window_in_pip(_host)),
        @"owns_lifecycle":@(aether_mobile_window_handles_lifecycle(_host)),
        @"app_state":@(UIApplication.sharedApplication.applicationState)};
    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"pip-result.json"];
    [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil] writeToFile:path atomically:YES];
}
- (void)applicationWillTerminate:(UIApplication *)app {
    aether_mobile_window_detach_engine(FixtureHandle());
    aether_mobile_window_close(_host); _host=nullptr;
}
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(PiPSmoke.class)); } }
