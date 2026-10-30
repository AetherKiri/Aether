#include "native_controls_overlay.h"
#import <TargetConditionals.h>
#import <QuartzCore/QuartzCore.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#define AetherControlsBase UIView
#else
#import <AppKit/AppKit.h>
#define AetherControlsBase NSView
#endif

static void ControlsOnUI(dispatch_block_t action) {
    if (NSThread.isMainThread) action();
    else dispatch_sync(dispatch_get_main_queue(), action);
}

@interface AetherControlsOverlay : AetherControlsBase
@property(nonatomic, weak) AetherControlsBase *godotView;
@property(nonatomic, strong) NSArray<NSArray<NSNumber *> *> *regions;
- (BOOL)containsControl:(CGPoint)point;
@end

@implementation AetherControlsOverlay
- (BOOL)containsControl:(CGPoint)point {
    if (self.hidden || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return NO;
    const double x = point.x / self.bounds.size.width, y = point.y / self.bounds.size.height;
    for (NSArray<NSNumber *> *r in self.regions) {
        if (r.count == 4 && x >= r[0].doubleValue && y >= r[1].doubleValue &&
            x < r[0].doubleValue + r[2].doubleValue && y < r[1].doubleValue + r[3].doubleValue) return YES;
    }
    return NO;
}
#if TARGET_OS_IPHONE
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return [self containsControl:point] ? self.godotView : nil;
}
#else
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpaque { return NO; }
- (NSView *)hitTest:(NSPoint)point {
    return [self containsControl:[self convertPoint:point fromView:self.superview]] ? self.godotView : nil;
}
#endif
@end

void *aether_controls_open(uint64_t native) {
    __block AetherControlsOverlay *view = nil;
    ControlsOnUI(^{
#if TARGET_OS_IPHONE
        UIView *parent = (__bridge UIView *)(void *)native;
#else
        NSView *parent = ((__bridge NSWindow *)(void *)native).contentView;
#endif
        if (!parent) return;
        view = [[AetherControlsOverlay alloc] initWithFrame:parent.bounds];
        view.godotView = parent;
#if TARGET_OS_IPHONE
        view.backgroundColor = UIColor.clearColor;
        view.opaque = NO;
        view.multipleTouchEnabled = YES;
#else
        view.wantsLayer = YES;
#endif
        view.layer.contentsGravity = kCAGravityResize;
        view.hidden = YES;
        [parent addSubview:view];
    });
    return (__bridge_retained void *)view;
}

void aether_controls_present(void *handle, const uint8_t *rgba, int width, int height, const char *regions_json) {
    if (!handle || !rgba || width <= 0 || height <= 0) return;
    NSData *data = [NSData dataWithBytes:rgba length:size_t(width) * height * 4];
    NSData *json = [[NSString stringWithUTF8String:regions_json] dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *regions = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    ControlsOnUI(^{
        AetherControlsOverlay *view = (__bridge AetherControlsOverlay *)handle;
        CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
        CGImageRef image = CGImageCreate(width, height, 8, 32, size_t(width) * 4, color,
            kCGImageAlphaPremultipliedLast, provider, nullptr, false, kCGRenderingIntentDefault);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        view.layer.contents = (__bridge id)image;
        view.regions = regions;
        view.hidden = regions.count == 0;
        [CATransaction commit];
        // Reopening a native game adds a new surface. Keep this shared layer
        // above it without changing the game's frame or keyboard responder.
        if (view.superview.subviews.lastObject != view) {
            AetherControlsBase *parent = view.godotView;
            [view removeFromSuperview];
            [parent addSubview:view];
        }
        CGImageRelease(image);
        CGDataProviderRelease(provider);
        CGColorSpaceRelease(color);
    });
}

void aether_controls_rect(void *handle, double x, double y, double width, double height) {
    if (!handle) return;
    ControlsOnUI(^{
        AetherControlsOverlay *view = (__bridge AetherControlsOverlay *)handle;
        CGSize size = view.godotView.bounds.size;
        double origin_y = y;
#if !TARGET_OS_IPHONE
        if (!view.godotView.isFlipped) origin_y = 1.0 - y - height;
#endif
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        view.frame = CGRectMake(x * size.width, origin_y * size.height, width * size.width, height * size.height);
        [CATransaction commit];
    });
}

void aether_controls_visible(void *handle, bool visible) {
    if (handle) ControlsOnUI(^{ ((__bridge AetherControlsOverlay *)handle).hidden = !visible; });
}

void aether_controls_close(void *handle) {
    if (!handle) return;
    ControlsOnUI(^{
        AetherControlsOverlay *view = (__bridge_transfer AetherControlsOverlay *)handle;
        [view removeFromSuperview];
    });
}
