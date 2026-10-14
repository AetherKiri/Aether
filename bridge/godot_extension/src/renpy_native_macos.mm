#include "renpy_native.h"
#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <cstdlib>
#include <string>
#include <vector>

static void *runtime;
static int (*python_run)(const char *);
static NSString *runtime_path;
static NSString *runtime_error;
static void (*set_bounds)(int, int);
static void (*activate_context)();
static void OnUI(dispatch_block_t block) {
    if (NSThread.isMainThread) block(); else dispatch_sync(dispatch_get_main_queue(), block);
}
static NSString *Literal(id value) {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingWithoutEscapingSlashes error:nil] encoding:NSUTF8StringEncoding];
}

// Keep the adopted SDK view visual-only. Godot owns input and the toolbar;
// forwarding through its event stream also works with touch and virtual keys.
@interface AetherRenpyContainer : NSView
@end
@implementation AetherRenpyContainer
- (NSView *)hitTest:(NSPoint)point { return nil; }
@end

@interface AetherRenpyNativeHost : NSObject
@property(nonatomic, strong) NSView *parent;
@property(nonatomic, strong) NSView *view;
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, weak) NSResponder *previousResponder;
@property(nonatomic, strong) NSMutableArray *input;
@property(nonatomic) BOOL stepping;
@end
@implementation AetherRenpyNativeHost
@end
static AetherRenpyNativeHost *active;

static void Adopt(void *window) {
    if (!active) return;
    // SDL 2.0.20 SysWMinfo: version, subsystem, then the Cocoa NSWindow.
    struct WMInfo { unsigned char version[3]; unsigned char padding; int subsystem; void *data[32]; } info = {{2, 0, 20}};
    auto wm = reinterpret_cast<int (*)(void *, void *)>(dlsym(runtime, "SDL_GetWindowWMInfo"));
    if (!wm || !wm(window, &info)) return;
    NSWindow *helper = (__bridge NSWindow *)info.data[0];
    active.view = helper.contentView;
    [active.view removeFromSuperview];
    helper.contentView = [[NSView alloc] initWithFrame:active.view.bounds];
    active.view.frame = active.parent.bounds;
    active.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [active.parent addSubview:active.view];
}

extern "C" void *aether_renpy_native_open(uint64_t native, const char *sdkPath, const char *manifestPath,
    const char *bootstrapPath, const char *greenletPath, char **outError) {
    __block void *result = nullptr;
    OnUI(^{
        if (outError) *outError = nullptr;
        auto fail = [&](NSString *message) {
            if (outError) *outError = strdup(message.UTF8String);
            if (runtime && !runtime_path) runtime_error = message;
        };
        if (active) { fail(@"A Ren'Py session is already open"); return; }
        if (runtime_error) { fail([runtime_error stringByAppendingString:@"; restart Aether before retrying"]); return; }
        NSString *sdk = @(sdkPath);
        if (runtime_path && ![runtime_path isEqualToString:sdk]) { fail(@"Restart Aether before selecting another Ren'Py runtime"); return; }
        NSWindow *window = (__bridge NSWindow *)(reinterpret_cast<void *>(native));
        if (!window.contentView) { fail(@"The Aether window is unavailable"); return; }
        AetherRenpyNativeHost *host = [AetherRenpyNativeHost new];
        host.window = window; host.previousResponder = window.firstResponder;
        host.parent = [[AetherRenpyContainer alloc] initWithFrame:window.contentView.bounds];
        host.input = [NSMutableArray new];
        [window.contentView addSubview:host.parent];
        active = host;
        if (!runtime) {
            NSString *library = [sdk stringByAppendingPathComponent:@"lib/py3-mac-universal/librenpython.dylib"];
            Dl_info own;
            dladdr(reinterpret_cast<void *>(&aether_renpy_native_open), &own);
            NSString *hook = [[@(own.dli_fname) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"libaether_renpy_sdl_hook.dylib"];
            if (![NSFileManager.defaultManager fileExistsAtPath:hook]) { fail(@"The native Ren'Py SDL adapter is missing"); active = nil; [host.parent removeFromSuperview]; return; }
            NSString *previous = getenv("SDL_DYNAMIC_API") ? @(getenv("SDL_DYNAMIC_API")) : nil;
            struct RestoreEnvironment {
                NSString *value;
                ~RestoreEnvironment() { if (value) setenv("SDL_DYNAMIC_API", value.UTF8String, 1); else unsetenv("SDL_DYNAMIC_API"); }
            } restore{previous};
            setenv("SDL_DYNAMIC_API", hook.UTF8String, 1);
            setenv("AETHER_RENPY_NATIVE_LIBRARY", library.UTF8String, 1);
            setenv("AETHER_RENPY_NATIVE_ADOPT", std::to_string(reinterpret_cast<uintptr_t>(&Adopt)).c_str(), 1);
#if defined(__x86_64__)
            setenv("RENPY_PLATFORM", "mac-x86_64", 1);
#else
            setenv("RENPY_PLATFORM", "mac-arm64", 1);
#endif
            setenv("RENPY_GL_VSYNC", "0", 1);
            setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
            runtime = dlopen(library.UTF8String, RTLD_NOW | RTLD_GLOBAL);
            if (!runtime) { fail(@(dlerror())); active = nil; [host.parent removeFromSuperview]; return; }
            auto init = reinterpret_cast<void (*)()>(dlsym(runtime, "init_librenpy"));
            auto set_path = reinterpret_cast<void (*)(const wchar_t *)>(dlsym(runtime, "Py_SetPath"));
            auto initialize = reinterpret_cast<void (*)()>(dlsym(runtime, "Py_Initialize"));
            auto program = reinterpret_cast<void (*)(const wchar_t *)>(dlsym(runtime, "Py_SetProgramName"));
            python_run = reinterpret_cast<int (*)(const char *)>(dlsym(runtime, "PyRun_SimpleString"));
            auto version = reinterpret_cast<void (*)(unsigned char *)>(dlsym(runtime, "SDL_GetVersion"));
            if (!init || !set_path || !initialize || !program || !python_run || !version) {
                fail(@"The supplied runtime has an incompatible native API"); active = nil; [host.parent removeFromSuperview]; return;
            }
            unsigned char sdl[3]; version(sdl);
            if (previous) setenv("SDL_DYNAMIC_API", previous.UTF8String, 1); else unsetenv("SDL_DYNAMIC_API");
            void *adapter = dlopen(hook.UTF8String, RTLD_NOW | RTLD_NOLOAD);
            auto installed = adapter ? reinterpret_cast<bool (*)()>(dlsym(adapter, "aether_renpy_sdl_hook_installed")) : nullptr;
            set_bounds = adapter ? reinterpret_cast<void (*)(int, int)>(dlsym(adapter, "aether_renpy_sdl_bounds")) : nullptr;
            activate_context = adapter ? reinterpret_cast<void (*)()>(dlsym(adapter, "aether_renpy_sdl_activate")) : nullptr;
            if (!installed || !installed()) {
                fail(@"The SDK could not install its native view adapter"); active = nil; [host.parent removeFromSuperview]; return;
            }
            if (sdl[0] != 2 || sdl[1] != 0 || sdl[2] != 20) {
                fail(@"The native adapter requires the Ren'Py 8.5.3 SDL 2.0.20 runtime"); active = nil; [host.parent removeFromSuperview]; return;
            }
            auto wide = [](NSString *value) {
                NSUInteger length = [value lengthOfBytesUsingEncoding:NSUTF32LittleEndianStringEncoding] / sizeof(wchar_t);
                std::vector<wchar_t> result(length + 1);
                [value getBytes:result.data() maxLength:length * sizeof(wchar_t) usedLength:nil encoding:NSUTF32LittleEndianStringEncoding options:0 range:NSMakeRange(0, value.length) remainingRange:nil];
                return result;
            };
            auto paths = wide([NSString stringWithFormat:@"%@/lib/python3.12:%@/lib/py3-mac-universal", sdk, sdk]);
            auto executable = wide([sdk stringByAppendingPathComponent:@"lib/py3-mac-universal/python"]);
            init(); set_path(paths.data()); program(executable.data()); initialize();
            runtime_path = sdk;
        }
        NSString *script = [NSString stringWithFormat:@"import sys;sys.path[:0]=%@;__import__('embedded').open_session(%@[0])",
            Literal(@[sdk, @(greenletPath), [@(bootstrapPath) stringByDeletingLastPathComponent]]), Literal(@[@(manifestPath)])];
        if (python_run(script.UTF8String)) { fail(@"Could not initialize the cooperative Ren'Py host"); active = nil; [host.parent removeFromSuperview]; return; }
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
        NSOpenGLContext *previous = NSOpenGLContext.currentContext;
        if (activate_context) activate_context();
        NSArray *input = [active.input copy];
        [active.input removeAllObjects];
        NSString *script = [NSString stringWithFormat:@"__import__('embedded').input_events(__import__('json').loads(%@[0]));__import__('embedded').step()", Literal(@[Literal(input)])];
        success = python_run(script.UTF8String) == 0;
        if (previous) [previous makeCurrentContext]; else [NSOpenGLContext clearCurrentContext];
        active.stepping = NO;
    });
    return success;
}
extern "C" void aether_renpy_native_input(void *handle, const char *event) {
    NSString *json = @(event);
    OnUI(^{
        if (!handle || !active) return;
        id value = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![value isKindOfClass:NSDictionary.class]) return;
        if (active.input.count < 256) [active.input addObject:value];
    });
}
extern "C" void aether_renpy_native_close(void *handle) {
    if (!handle) return;
    AetherRenpyNativeHost *host = (__bridge_transfer AetherRenpyNativeHost *)handle;
    OnUI(^{
        NSOpenGLContext *previous = NSOpenGLContext.currentContext;
        if (activate_context) activate_context();
        python_run("__import__('embedded').close_session()");
        if (previous) [previous makeCurrentContext]; else [NSOpenGLContext clearCurrentContext];
        [host.view removeFromSuperview]; [host.parent removeFromSuperview];
        [host.window makeFirstResponder:host.previousResponder]; active = nil;
    });
}
extern "C" void aether_renpy_native_pause(void *handle, bool paused) {
    OnUI(^{ if (handle && active) python_run(paused ? "__import__('embedded').pause(True)" : "__import__('embedded').pause(False)"); });
}
extern "C" bool aether_renpy_native_is_embedded(void *handle) {
    __block bool result = false;
    AetherRenpyNativeHost *host = (__bridge AetherRenpyNativeHost *)handle;
    OnUI(^{ result = host.view != nil && host.view.window == host.window; });
    return result;
}
extern "C" void aether_renpy_native_rect(void *handle, double x, double y, double width, double height) {
    AetherRenpyNativeHost *host = (__bridge AetherRenpyNativeHost *)handle;
    OnUI(^{
        NSView *parent = host.parent.superview;
        if (!parent) return;
        NSRect bounds = parent.bounds;
        NSRect rect = NSMakeRect(x * bounds.size.width, y * bounds.size.height, width * bounds.size.width, height * bounds.size.height);
        if (!parent.isFlipped) rect.origin.y = bounds.size.height - rect.origin.y - rect.size.height;
        host.parent.frame = rect;
        if (set_bounds) set_bounds(rect.size.width, rect.size.height);
    });
}
