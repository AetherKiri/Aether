#include "renpy_native.h"
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <cstdlib>
#include <vector>

static void *runtime;
static int (*python_run)(const char *);
static void (*configure_adapter)(void (*)(void *), int, int);
static NSString *runtime_path;
static void OnUI(dispatch_block_t block) {
    if (NSThread.isMainThread) block(); else dispatch_sync(dispatch_get_main_queue(), block);
}
static NSString *Literal(id value) {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingWithoutEscapingSlashes error:nil] encoding:NSUTF8StringEncoding];
}
@interface AetherRenpyContainer : UIView
@end
@implementation AetherRenpyContainer
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
@end
@interface AetherRenpyNativeHost : NSObject
@property(nonatomic, strong) UIView *parent;
@property(nonatomic, strong) UIView *view;
@property(nonatomic, strong) UIViewController *controller;
@property(nonatomic, weak) UIView *godot;
@property(nonatomic, strong) NSMutableArray *input;
@property(nonatomic) BOOL stepping;
@end
@implementation AetherRenpyNativeHost
@end
static AetherRenpyNativeHost *active;

static void Adopt(void *window) {
    if (!active) return;
    struct WMInfo { unsigned char version[3]; unsigned char padding; int subsystem; void *data[32]; } info = {{2, 0, 20}};
    auto wm = reinterpret_cast<int (*)(void *, void *)>(dlsym(runtime, "SDL_GetWindowWMInfo"));
    if (!wm || !wm(window, &info) || info.subsystem != 5) return; // SDL_SYSWM_UIKIT
    UIWindow *helper = (__bridge UIWindow *)info.data[0];
    UIViewController *controller = helper.rootViewController;
    UIView *view = controller.view;
    if (!view) return;
    [view removeFromSuperview];
    helper.rootViewController = nil;
    helper.hidden = YES;
    if (active.controller != controller) {
        [active.controller willMoveToParentViewController:nil];
        [active.controller removeFromParentViewController];
        active.controller = controller;
        [active.godot.window.rootViewController addChildViewController:controller];
    }
    active.view = view;
    view.frame = active.parent.bounds;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [active.parent addSubview:view];
    [controller didMoveToParentViewController:controller.parentViewController];
}

extern "C" void *aether_renpy_native_open(uint64_t native, const char *sdkPath, const char *manifestPath,
    const char *bootstrapPath, const char *greenletPath, char **outError) {
    __block void *result = nullptr;
    OnUI(^{
        if (outError) *outError = nullptr;
        auto fail = [&](NSString *message) { if (outError) *outError = strdup(message.UTF8String); };
        if (active) { fail(@"A Ren'Py session is already open"); return; }
        NSString *sdk = @(sdkPath);
        if (runtime_path && ![runtime_path isEqualToString:sdk]) { fail(@"Restart Aether before selecting another Ren'Py runtime"); return; }
        UIView *godot = (__bridge UIView *)(reinterpret_cast<void *>(native));
        if (!godot.window) { fail(@"The Aether view is unavailable"); return; }
        AetherRenpyNativeHost *host = [AetherRenpyNativeHost new];
        host.godot = godot;
        host.parent = [[AetherRenpyContainer alloc] initWithFrame:godot.bounds];
        host.parent.clipsToBounds = YES;
        host.input = [NSMutableArray new];
        [godot addSubview:host.parent];
        active = host;
        if (!runtime) {
            NSString *library = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"AetherRenpy.framework/AetherRenpy"];
            runtime = dlopen(library.UTF8String, RTLD_NOW | RTLD_LOCAL);
            if (!runtime) { fail(@(dlerror())); active = nil; [host.parent removeFromSuperview]; return; }
            auto init = reinterpret_cast<void (*)()>(dlsym(runtime, "aether_renpy_runtime_init"));
            configure_adapter = reinterpret_cast<void (*)(void (*)(void *), int, int)>(dlsym(runtime, "aether_renpy_ios_adapter"));
            auto set_path = reinterpret_cast<void (*)(const wchar_t *)>(dlsym(runtime, "Py_SetPath"));
            auto initialize = reinterpret_cast<void (*)(int)>(dlsym(runtime, "Py_InitializeEx"));
            python_run = reinterpret_cast<int (*)(const char *)>(dlsym(runtime, "PyRun_SimpleString"));
            if (!init || !configure_adapter || !set_path || !initialize || !python_run) {
                fail(@"The packaged Ren'Py framework has an incompatible native API"); active = nil; [host.parent removeFromSuperview]; return;
            }
            configure_adapter(Adopt, godot.bounds.size.width, godot.bounds.size.height);
            setenv("RENPY_PLATFORM", "ios-arm64", 1);
            setenv("RENPY_GL_VSYNC", "0", 1);
            NSString *path = [sdk stringByAppendingPathComponent:@"lib/python3.12"];
            NSUInteger length = [path lengthOfBytesUsingEncoding:NSUTF32LittleEndianStringEncoding] / sizeof(wchar_t);
            std::vector<wchar_t> wide(length + 1);
            [path getBytes:wide.data() maxLength:length * sizeof(wchar_t) usedLength:nil encoding:NSUTF32LittleEndianStringEncoding options:0 range:NSMakeRange(0, path.length) remainingRange:nil];
            init(); set_path(wide.data()); initialize(0);
            runtime_path = sdk;
        }
        configure_adapter(Adopt, godot.bounds.size.width, godot.bounds.size.height);
        NSString *script = [NSString stringWithFormat:@"import sys;sys.path[:0]=%@;__import__('embedded').open_session(%@[0])",
            Literal(@[sdk, @(greenletPath), [@(bootstrapPath) stringByDeletingLastPathComponent]]), Literal(@[@(manifestPath)])];
        if (python_run(script.UTF8String)) { fail(@"Could not initialize the native Ren'Py host"); active = nil; [host.parent removeFromSuperview]; return; }
        result = (__bridge_retained void *)host;
    });
    return result;
}
extern "C" bool aether_renpy_native_step(void *handle) {
    __block bool success = false;
    OnUI(^{
        if (!handle || !active) return;
        if (active.stepping) { success = true; return; }
        active.stepping = YES;
        NSArray *input = [active.input copy]; [active.input removeAllObjects];
        NSString *script = [NSString stringWithFormat:@"__import__('embedded').input_events(__import__('json').loads(%@[0]));__import__('embedded').step()", Literal(@[Literal(input)])];
        success = python_run(script.UTF8String) == 0;
        active.stepping = NO;
    });
    return success;
}
extern "C" void aether_renpy_native_input(void *handle, const char *event) {
    NSString *json = @(event);
    OnUI(^{
        if (!handle || !active) return;
        id value = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if ([value isKindOfClass:NSDictionary.class] && active.input.count < 256) [active.input addObject:value];
    });
}
extern "C" void aether_renpy_native_close(void *handle) {
    if (!handle) return;
    AetherRenpyNativeHost *host = (__bridge_transfer AetherRenpyNativeHost *)handle;
    OnUI(^{
        python_run("__import__('embedded').close_session()");
        [host.controller willMoveToParentViewController:nil];
        [host.view removeFromSuperview];
        [host.controller removeFromParentViewController];
        [host.parent removeFromSuperview];
        active = nil;
    });
}
extern "C" void aether_renpy_native_pause(void *handle, bool paused) {
    OnUI(^{ if (handle && active) python_run(paused ? "__import__('embedded').pause(True)" : "__import__('embedded').pause(False)"); });
}
extern "C" bool aether_renpy_native_is_embedded(void *handle) {
    __block bool result = false;
    AetherRenpyNativeHost *host = (__bridge AetherRenpyNativeHost *)handle;
    OnUI(^{ result = host.view && host.view.window == host.godot.window && host.controller.parentViewController != nil; });
    return result;
}
extern "C" void aether_renpy_native_rect(void *handle, double x, double y, double width, double height) {
    AetherRenpyNativeHost *host = (__bridge AetherRenpyNativeHost *)handle;
    OnUI(^{
        CGRect bounds = host.godot.bounds;
        CGRect rect = CGRectMake(x * bounds.size.width, y * bounds.size.height, width * bounds.size.width, height * bounds.size.height);
        if (CGRectEqualToRect(rect, host.parent.frame)) return;
        host.parent.frame = rect;
        if (configure_adapter) configure_adapter(Adopt, rect.size.width, rect.size.height);
    });
}
