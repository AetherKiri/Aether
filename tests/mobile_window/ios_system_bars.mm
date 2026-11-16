// Simulator app linked to the production UIKit host. No game or PiP is needed.
#include "mobile_window.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

extern "C" engine_result_t engine_background_playback(engine_handle_t, uint32_t) { return ENGINE_RESULT_NOT_SUPPORTED; }
extern "C" engine_result_t engine_pause(engine_handle_t) { return ENGINE_RESULT_OK; }
extern "C" engine_result_t engine_resume(engine_handle_t) { return ENGINE_RESULT_OK; }
extern "C" engine_result_t engine_tick(engine_handle_t, uint32_t) { return ENGINE_RESULT_OK; }
extern "C" engine_result_t engine_get_frame_desc(engine_handle_t, engine_frame_desc_t*) { return ENGINE_RESULT_NOT_SUPPORTED; }
extern "C" engine_result_t engine_read_frame_rgba(engine_handle_t, void*, size_t) { return ENGINE_RESULT_NOT_SUPPORTED; }

// Model Godot/SwiftUI's container delegating status appearance to a game child.
@interface GameController : UIViewController
@end
@implementation GameController
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }
@end
@interface ContainerController : GameController
@end
@implementation ContainerController
- (UIViewController*)childViewControllerForStatusBarHidden { return self.childViewControllers.firstObject; }
- (UIViewController*)childViewControllerForStatusBarStyle { return self.childViewControllers.firstObject; }
@end

@interface SystemBarsSmoke : UIResponder <UIApplicationDelegate> { void *_host; }
@property(strong, nonatomic) UIWindow *window;
@property(strong, nonatomic) UIViewController *game;
@property(strong, nonatomic) NSMutableArray *results;
- (void)check:(NSString*)name active:(BOOL)active dark:(BOOL)dark next:(dispatch_block_t)next;
@end
@implementation SystemBarsSmoke
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options {
    self.results = [NSMutableArray new];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.game = [GameController new];
    ContainerController *root = [ContainerController new];
    [root addChildViewController:self.game];
    self.game.view.frame = root.view.bounds;
    self.game.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:self.game.view];
    [self.game didMoveToParentViewController:root];
    _host = aether_mobile_window_open(uint64_t((__bridge void*)self.game.view));
    aether_mobile_window_configure(_host, false, false, false); // Before attaching to a window.
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    [self check:@"library-light" active:NO dark:NO next:^{
        [self check:@"settings-dark" active:NO dark:YES next:^{
            [self check:@"game-pip-disabled" active:YES dark:YES next:^{
                [self check:@"return-to-library" active:NO dark:NO next:^{
                    // Reparent the same Godot view, as a window/container change can do.
                    UIViewController *previous = self.window.rootViewController;
                    [self.game willMoveToParentViewController:nil];
                    [self.game.view removeFromSuperview];
                    [self.game removeFromParentViewController];
                    ContainerController *replacement = [ContainerController new];
                    [replacement addChildViewController:self.game];
                    self.game.view.frame = replacement.view.bounds;
                    [replacement.view addSubview:self.game.view];
                    [self.game didMoveToParentViewController:replacement];
                    self.window.rootViewController = replacement;
                    [self check:@"replacement-container" active:NO dark:YES next:^{
                        BOOL restored = object_getClass(previous) == ContainerController.class;
                        aether_mobile_window_close(self->_host); self->_host = nullptr;
                        restored = restored && object_getClass(replacement) == ContainerController.class;
                        [self.results addObject:@{@"name":@"controller-restoration", @"passed":@(restored)}];
                        BOOL passed = YES;
                        for (NSDictionary *result in self.results) passed &= [result[@"passed"] boolValue];
                        NSDictionary *report = @{@"passed":@(passed), @"checks":self.results};
                        NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"system-bars-result.json"];
                        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:path atomically:YES];
                        NSLog(@"SYSTEM_BARS_TEST %@", passed ? @"PASSED" : @"FAILED");
                    }];
                }];
            }];
        }];
    }];
    return YES;
}
- (void)check:(NSString*)name active:(BOOL)active dark:(BOOL)dark next:(dispatch_block_t)next {
    self.game.view.backgroundColor = dark ? UIColor.blackColor : UIColor.whiteColor;
    aether_mobile_window_configure(_host, active, false, dark);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIViewController *root = self.window.rootViewController;
        UIStatusBarManager *bar = self.window.windowScene.statusBarManager;
        UIStatusBarStyle style = dark ? UIStatusBarStyleLightContent : UIStatusBarStyleDarkContent;
        BOOL passed = root.prefersStatusBarHidden == active && root.prefersHomeIndicatorAutoHidden == active
            && root.preferredStatusBarStyle == style && !root.childViewControllerForStatusBarHidden
            && !root.childViewControllerForStatusBarStyle && bar && bar.statusBarHidden == active;
        [self.results addObject:@{@"name":name, @"passed":@(passed), @"status_hidden":@(bar.statusBarHidden),
            @"style":@(root.preferredStatusBarStyle), @"safe_top":@(self.game.view.safeAreaInsets.top)}];
        next();
    });
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(SystemBarsSmoke.class)); }
}
