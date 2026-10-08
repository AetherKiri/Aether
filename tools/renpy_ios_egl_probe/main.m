#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include "egl_probe.h"

@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIImageView *imageView;
@end

@implementation ProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.blackColor;
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 70, self.window.bounds.size.width - 48, 150)];
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.text = @"Running MetalANGLE EGL pbuffer probe…";
    self.imageView = [[UIImageView alloc] initWithFrame:CGRectMake(24, 240, 256, 256)];
    self.imageView.layer.magnificationFilter = kCAFilterNearest;
    [controller.view addSubview:self.statusLabel];
    [controller.view addSubview:self.imageView];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(), ^{
        const NSUInteger windowCount = application.windows.count;
        aether_egl_probe_result result;
        aether_run_egl_probe(&result);
        const BOOL noExtraWindow = application.windows.count == windowCount;
        if (!noExtraWindow) result.passed = 0;
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSMutableDictionary *report = [@{
            @"probe": @"MetalANGLE EGL pbuffer", @"gameplay_verified": @NO,
            @"passed": @(result.passed), @"pbuffer_created": @(result.pbuffer_created),
            @"readback_verified": @(result.readback_verified),
            @"host_context_restored": @(result.host_context_restored),
            @"resume_verified": @(result.resume_verified), @"no_extra_uiwindow": @(noExtraWindow),
            @"gles_client_version": @(result.client_version),
            @"egl_error": @(result.egl_error), @"gl_error": @(result.gl_error),
            @"error": [NSString stringWithUTF8String:result.error] ?: @"invalid UTF-8 diagnostic",
            @"egl_vendor": [NSString stringWithUTF8String:result.egl_vendor] ?: @"",
            @"egl_version": [NSString stringWithUTF8String:result.egl_version] ?: @"",
            @"gl_vendor": [NSString stringWithUTF8String:result.gl_vendor] ?: @"",
            @"gl_renderer": [NSString stringWithUTF8String:result.gl_renderer] ?: @"",
            @"gl_version": [NSString stringWithUTF8String:result.gl_version] ?: @"",
            @"pixel_width": @16, @"pixel_height": @16,
            @"pixels_origin": @"bottom-left", @"thread": @"UIKit main thread",
            @"windows_before": @(windowCount), @"windows_after": @(application.windows.count)
        } mutableCopy];
        NSData *pixels = [NSData dataWithBytes:result.pixels length:sizeof(result.pixels)];
        [pixels writeToFile:[documents stringByAppendingPathComponent:@"egl-probe.rgba"] atomically:YES];
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGImageRef image = CGImageCreate(16, 16, 8, 32, 64, colorSpace,
            kCGBitmapByteOrderDefault | kCGImageAlphaLast, provider, NULL, NO, kCGRenderingIntentDefault);
        if (image) {
            UIImage *shown = [UIImage imageWithCGImage:image];
            self.imageView.image = shown;
            [UIImagePNGRepresentation(shown) writeToFile:[documents stringByAppendingPathComponent:@"egl-probe.png"] atomically:YES];
            CGImageRelease(image);
        }
        CGColorSpaceRelease(colorSpace);
        CGDataProviderRelease(provider);
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
        if (json) [json writeToFile:[documents stringByAppendingPathComponent:@"egl-probe.json"] atomically:YES];
        self.statusLabel.text = result.passed ? @"PASS: actual EGL pbuffer pixels read back.\nHost context preserved; fresh pixels after resume.\nRen’Py gameplay is not tested." :
            [NSString stringWithFormat:@"FAIL: %@\nEGL=0x%x GL=0x%x", report[@"error"], result.egl_error, result.gl_error];
        NSLog(@"AETHER_EGL_PROBE %@", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] ?: error.description);
    });
    return YES;
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeDelegate.class)); }
}
