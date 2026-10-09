/* Real UIKit SDL2 plus MetalANGLE coexistence probe. No SDL/GL API is replaced. */
#define SDL_MAIN_HANDLED 1
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#include <SDL.h>
#include <dlfcn.h>
#include <string.h>
#include "egl_probe.h"

typedef struct AppleGL {
    const GLubyte *(*GetString)(GLenum);
    GLenum (*GetError)(void);
    void (*GenFramebuffers)(GLsizei, GLuint *);
    void (*BindFramebuffer)(GLenum, GLuint);
    void (*DeleteFramebuffers)(GLsizei, const GLuint *);
    GLenum (*CheckFramebufferStatus)(GLenum);
    void (*GenRenderbuffers)(GLsizei, GLuint *);
    void (*BindRenderbuffer)(GLenum, GLuint);
    void (*RenderbufferStorage)(GLenum, GLenum, GLsizei, GLsizei);
    void (*FramebufferRenderbuffer)(GLenum, GLenum, GLenum, GLuint);
    void (*DeleteRenderbuffers)(GLsizei, const GLuint *);
    void (*ClearColor)(GLfloat, GLfloat, GLfloat, GLfloat);
    void (*Clear)(GLbitfield);
    void (*Finish)(void);
    void (*ReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *);
} AppleGL;

static void *appleSymbol(const char *name, NSMutableDictionary *sources, NSMutableDictionary *report) {
    void *symbol = SDL_GL_GetProcAddress(name);
    Dl_info info = {0};
    if (!symbol || !dladdr(symbol, &info) || !info.dli_fname) {
        report[@"error"] = [NSString stringWithFormat:@"Actual SDL symbol %s failed: %s", name, SDL_GetError()];
        return NULL;
    }
    NSString *source = [NSString stringWithUTF8String:info.dli_fname] ?: @"";
    sources[[NSString stringWithUTF8String:name]] = source;
    if (![source containsString:@"/OpenGLES.framework/"] || [source containsString:@"MetalANGLE"]) {
        report[@"error"] = [NSString stringWithFormat:@"Host SDL resolved %s to %@", name, source];
        return NULL;
    }
    return symbol;
}

static BOOL expectedColor(const unsigned char *pixels, int red, int green, int blue) {
    for (int i = 0; i < 16 * 16; ++i) {
        const int wanted[] = {red, green, blue, 255};
        for (int c = 0; c < 4; ++c) {
            int delta = pixels[i * 4 + c] - wanted[c];
            if (delta < -1 || delta > 1) return NO;
        }
    }
    return YES;
}

static NSDictionary *runHostProbe(NSData **actualPixels) {
    NSMutableDictionary *report = [@{
        @"probe": @"actual SDL2.32.10 UIKit Apple OpenGLES and MetalANGLE isolation",
        @"gameplay_verified": @NO, @"passed": @NO, @"error": @"",
        @"apple_provenance_verified": @NO, @"apple_readback_verified": @NO,
        @"metalangle_readback_verified": @NO, @"apple_context_preserved": @NO,
        @"apple_pixels_preserved": @NO, @"apple_resume_verified": @NO,
        @"load_unload_verified": @NO, @"video_reinitialization_verified": @NO
    } mutableCopy];
    NSMutableDictionary *sources = [NSMutableDictionary dictionary];
    EAGLContext *previous = [EAGLContext currentContext];
    EAGLContext *host = nil;
    AppleGL gl = {0};
    GLuint framebuffer = 0, renderbuffer = 0;
    unsigned char pixels[16 * 16 * 4] = {0};
    aether_egl_probe_result metal = {0};
    SDL_version version;
    SDL_GetVersion(&version);
    report[@"sdl_version"] = [NSString stringWithFormat:@"%d.%d.%d", version.major, version.minor, version.patch];
    report[@"symbol_sources"] = sources;
#define CHECK(value, ...) do { if (!(value)) { \
    if (![report[@"error"] length]) { report[@"error"] = (__VA_ARGS__); } goto cleanup; } } while (0)
#define LOAD(member, name) do { void *address = appleSymbol(name, sources, report); \
    if (!address) { goto cleanup; } gl.member = (__typeof__(gl.member))address; } while (0)
    CHECK(version.major == 2 && version.minor == 32 && version.patch == 10, @"Unexpected actual host SDL version");
    SDL_SetMainReady();
    CHECK(!SDL_setenv("SDL_VIDEODRIVER", "uikit", 1), @"Cannot select actual UIKit driver");
    CHECK(!SDL_Init(SDL_INIT_VIDEO), [NSString stringWithFormat:@"Actual UIKit SDL init: %s", SDL_GetError()]);
    CHECK(SDL_GetCurrentVideoDriver() && !strcmp(SDL_GetCurrentVideoDriver(), "uikit"), @"Actual SDL did not select UIKit");
    LOAD(GetString, "glGetString"); LOAD(GetError, "glGetError");
    LOAD(GenFramebuffers, "glGenFramebuffers"); LOAD(BindFramebuffer, "glBindFramebuffer");
    LOAD(DeleteFramebuffers, "glDeleteFramebuffers"); LOAD(CheckFramebufferStatus, "glCheckFramebufferStatus");
    LOAD(GenRenderbuffers, "glGenRenderbuffers"); LOAD(BindRenderbuffer, "glBindRenderbuffer");
    LOAD(RenderbufferStorage, "glRenderbufferStorage"); LOAD(FramebufferRenderbuffer, "glFramebufferRenderbuffer");
    LOAD(DeleteRenderbuffers, "glDeleteRenderbuffers"); LOAD(ClearColor, "glClearColor");
    LOAD(Clear, "glClear"); LOAD(Finish, "glFinish"); LOAD(ReadPixels, "glReadPixels");
    report[@"apple_provenance_verified"] = @YES;
    host = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    CHECK(host && host.API == kEAGLRenderingAPIOpenGLES3 && [EAGLContext setCurrentContext:host],
        @"Actual Apple EAGL GLES3 context creation failed");
    report[@"apple_gles_client_version"] = @(host.API);
    const GLubyte *renderer = gl.GetString(GL_RENDERER);
    CHECK(renderer, @"Actual Apple context has no GL_RENDERER string");
    report[@"apple_renderer"] = [NSString stringWithUTF8String:(const char *)renderer] ?: @"";
    gl.GenFramebuffers(1, &framebuffer); gl.BindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    gl.GenRenderbuffers(1, &renderbuffer); gl.BindRenderbuffer(GL_RENDERBUFFER, renderbuffer);
    gl.RenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 16, 16);
    gl.FramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, renderbuffer);
    CHECK(gl.CheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE, @"Actual Apple host FBO is incomplete");
    gl.ClearColor(0, 1, 1, 1); gl.Clear(GL_COLOR_BUFFER_BIT); gl.Finish();
    gl.ReadPixels(0, 0, 16, 16, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    CHECK(gl.GetError() == GL_NO_ERROR && expectedColor(pixels, 0, 255, 255), @"Actual Apple host cyan pixels mismatch");
    report[@"apple_readback_verified"] = @YES;
    CHECK(!aether_run_egl_probe(&metal) && metal.passed && metal.readback_verified && metal.client_version == 3,
        [NSString stringWithFormat:@"Actual MetalANGLE pbuffer failed: %s", metal.error]);
    report[@"metalangle_gles_client_version"] = @(metal.client_version);
    report[@"metalangle_renderer"] = [NSString stringWithUTF8String:metal.gl_renderer] ?: @"";
    report[@"metalangle_readback_verified"] = @YES;
    CHECK([EAGLContext currentContext] == host, @"MetalANGLE changed Apple's current host EAGL context");
    report[@"apple_context_preserved"] = @YES;
    CHECK(appleSymbol("glClear", sources, report), @"Actual host GL provenance changed after MetalANGLE rendering");
    gl.ReadPixels(0, 0, 16, 16, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    CHECK(gl.GetError() == GL_NO_ERROR && expectedColor(pixels, 0, 255, 255), @"MetalANGLE changed actual Apple host pixels");
    report[@"apple_pixels_preserved"] = @YES;
    gl.ClearColor(1, 0, 1, 1); gl.Clear(GL_COLOR_BUFFER_BIT); gl.Finish();
    gl.ReadPixels(0, 0, 16, 16, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    CHECK(gl.GetError() == GL_NO_ERROR && expectedColor(pixels, 255, 0, 255), @"Apple host did not resume with fresh magenta pixels");
    report[@"apple_resume_verified"] = @YES;
    *actualPixels = [NSData dataWithBytes:pixels length:sizeof(pixels)];
    CHECK(!SDL_GL_LoadLibrary(NULL), @"Actual SDL explicit GL load failed");
    SDL_GL_UnloadLibrary();
    CHECK(appleSymbol("glClear", sources, report), @"Actual SDL lost its initial preload reference");
    SDL_GL_UnloadLibrary();
    CHECK(!SDL_GL_GetProcAddress("glClear"), @"Actual SDL still returned GL after its final unload");
    SDL_ClearError();
    CHECK(!SDL_GL_LoadLibrary(NULL) && appleSymbol("glClear", sources, report), @"Actual SDL concrete Apple framework reload failed");
    report[@"load_unload_verified"] = @YES;
    SDL_Quit();
    CHECK(!SDL_Init(SDL_INIT_VIDEO) && appleSymbol("glClear", sources, report), @"Actual SDL video reinitialization failed");
    report[@"video_reinitialization_verified"] = @YES;
    report[@"passed"] = @YES;
cleanup:
    if (host && gl.DeleteFramebuffers && gl.DeleteRenderbuffers) {
        [EAGLContext setCurrentContext:host];
        if (framebuffer) gl.DeleteFramebuffers(1, &framebuffer);
        if (renderbuffer) gl.DeleteRenderbuffers(1, &renderbuffer);
    }
    [EAGLContext setCurrentContext:previous];
    SDL_Quit();
    return report;
#undef LOAD
#undef CHECK
}

@interface HostGLProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIImageView *imageView;
@end
@implementation HostGLProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.blackColor;
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 70, self.window.bounds.size.width - 48, 160)];
    self.statusLabel.textColor = UIColor.whiteColor; self.statusLabel.numberOfLines = 0;
    self.statusLabel.text = @"Running actual UIKit SDL / Apple OpenGLES / MetalANGLE isolation…";
    self.imageView = [[UIImageView alloc] initWithFrame:CGRectMake(24, 250, 256, 256)];
    self.imageView.layer.magnificationFilter = kCAFilterNearest;
    [controller.view addSubview:self.statusLabel]; [controller.view addSubview:self.imageView];
    self.window.rootViewController = controller; [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger before = application.windows.count;
        NSData *pixels = nil;
        NSMutableDictionary *report = [runHostProbe(&pixels) mutableCopy];
        report[@"no_extra_uiwindow"] = @(before == application.windows.count);
        report[@"windows_before"] = @(before); report[@"windows_after"] = @(application.windows.count);
        if (![report[@"no_extra_uiwindow"] boolValue]) {
            report[@"passed"] = @NO;
            report[@"error"] = @"UIKit created an additional UIWindow";
        }
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (pixels) {
            [pixels writeToFile:[documents stringByAppendingPathComponent:@"host-gl-probe.rgba"] atomically:YES];
            CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
            CGImageRef image = CGImageCreate(16, 16, 8, 32, 64, colorSpace,
                kCGBitmapByteOrderDefault | kCGImageAlphaLast, provider, NULL, NO, kCGRenderingIntentDefault);
            if (image) {
                UIImage *shown = [UIImage imageWithCGImage:image]; self.imageView.image = shown;
                [UIImagePNGRepresentation(shown) writeToFile:[documents stringByAppendingPathComponent:@"host-gl-probe.png"] atomically:YES];
                CGImageRelease(image);
            }
            CGColorSpaceRelease(colorSpace); CGDataProviderRelease(provider);
        }
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
        if (json) [json writeToFile:[documents stringByAppendingPathComponent:@"host-gl-probe.json"] atomically:YES];
        self.statusLabel.text = [report[@"passed"] boolValue] ?
            @"PASS: real host SDL uses Apple GLES; MetalANGLE pixels remain separate.\nUnload/reload and fresh host pixels verified.\nRen’Py gameplay is not tested." :
            [NSString stringWithFormat:@"FAIL: %@", report[@"error"]];
        NSLog(@"AETHER_HOST_GL_PROBE %@", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ?: error.description);
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(HostGLProbeDelegate.class)); }
}
