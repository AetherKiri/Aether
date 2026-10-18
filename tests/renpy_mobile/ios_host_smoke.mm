#import <UIKit/UIKit.h>
#include "renpy_native.h"
#include <unistd.h>

@interface RenpySmokeView : UIViewController
@property(nonatomic) void *runtime;
@property(nonatomic, strong) CADisplayLink *link;
@property(nonatomic, strong) NSString *session;
@property(nonatomic, strong) NSString *sdk;
@property(nonatomic) NSInteger phase;
@property(nonatomic) NSInteger sequence;
@property(nonatomic) CFTimeInterval started;
@property(nonatomic) CFTimeInterval savedAt;
@end
@implementation RenpySmokeView
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (void)fail:(NSString *)error {
    NSString *state = [NSString stringWithContentsOfFile:[self.session stringByAppendingPathComponent:@"state.json"] encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"RENPY_IOS_SMOKE_FAILED: %@; phase=%ld; state=%@", error, (long)self.phase, state);
    [@{@"passed":@NO, @"error":error} writeToFile:[self.session stringByAppendingPathComponent:@"failure.plist"] atomically:YES];
    exit(1);
}
- (void)openSession {
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    self.session = [documents stringByAppendingPathComponent:[NSString stringWithFormat:@"session-%ld-%llu", (long)self.phase, (unsigned long long)(CACurrentMediaTime() * 1000000)]];
    [NSFileManager.defaultManager createDirectoryAtPath:self.session withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *name in @[@"host.py", @"overlay.rpy", @"embedded.py"]) {
        [NSFileManager.defaultManager copyItemAtPath:[bundle stringByAppendingPathComponent:name] toPath:[self.session stringByAppendingPathComponent:name] error:nil];
    }
    NSDictionary *manifest = @{@"sdk":self.sdk, @"game":[bundle stringByAppendingPathComponent:@"fixture/game"],
        @"saves":[documents stringByAppendingPathComponent:@"saves"], @"ui_font":[bundle stringByAppendingPathComponent:@"font.ttf"],
        @"embedded":@YES, @"debug":@YES, @"parent_pid":@(getpid())};
    NSString *file = [self.session stringByAppendingPathComponent:@"manifest.json"];
    [[NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil] writeToFile:file atomically:YES];
    char *error = nullptr;
    self.runtime = aether_renpy_native_open((uint64_t)(__bridge void *)self.view, self.sdk.UTF8String, file.UTF8String,
        [self.session stringByAppendingPathComponent:@"embedded.py"].UTF8String,
        [self.sdk stringByAppendingPathComponent:@"lib/python3.12/site-packages"].UTF8String, &error);
    if (!self.runtime) [self fail:error ? @(error) : @"Native open failed"];
    self.sequence = 0;
    aether_renpy_native_rect(self.runtime, 0, 0.08, 1, 0.92);
}
- (void)command:(NSString *)action values:(NSDictionary *)values {
    NSMutableDictionary *command = [values mutableCopy];
    command[@"action"] = action; command[@"seq"] = @(++self.sequence);
    [[NSJSONSerialization dataWithJSONObject:command options:0 error:nil] writeToFile:[self.session stringByAppendingPathComponent:@"command.json"] atomically:YES];
}
- (void)input:(NSDictionary *)value {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    aether_renpy_native_input(self.runtime, json.UTF8String);
}
- (void)key:(NSString *)key {
    [self input:@{@"type":@"key", @"key":key, @"pressed":@YES}];
    [self input:@{@"type":@"key", @"key":key, @"pressed":@NO}];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.link) return;
    self.view.backgroundColor = UIColor.blackColor;
    self.sdk = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"renpy-runtime"];
    [self openSession]; self.started = CACurrentMediaTime();
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)tick {
    if (CACurrentMediaTime() - self.started > 100) [self fail:@"Native scenario timed out"];
    if (!aether_renpy_native_step(self.runtime)) [self fail:@"Native tick failed"];
    NSData *data = [NSData dataWithContentsOfFile:[self.session stringByAppendingPathComponent:@"state.json"]];
    NSDictionary *state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([state[@"phase"] isEqual:@"error"]) [self fail:state[@"error"] ?: @"Engine error"];
    NSInteger step = [state[@"variables"][@"aether_probe_step"] integerValue];
    switch (self.phase) {
        case 0:
            if (![state[@"phase"] isEqual:@"ready"] || ![state[@"main_menu"] boolValue]) return;
            if (!aether_renpy_native_is_embedded(self.runtime)) [self fail:@"SDL view is outside the host window"];
            if ([state[@"controls"] boolValue]) [self fail:@"Virtual controls should start off"];
            NSLog(@"RENPY_IOS_NATIVE_READY: %@", state);
            [self command:@"inspect" values:@{@"names":@[@"aether_probe_step", @"aether_probe_route"]}];
            [self input:@{@"type":@"button", @"button":@1, @"pressed":@YES, @"x":@0.5, @"y":@0.5, @"touch":@YES}];
            [self input:@{@"type":@"button", @"button":@1, @"pressed":@NO, @"x":@0.5, @"y":@0.5, @"touch":@YES}];
            self.phase = 1; break;
        case 1:
            if (step != 1) return;
            [self key:@"return"]; self.phase = 2; break;
        case 2:
            if (step != 2) return;
            self.savedAt = CACurrentMediaTime(); self.phase = 13; break;
        case 13:
            if (CACurrentMediaTime() - self.savedAt < 0.25) return;
            [self input:@{@"type":@"button", @"button":@1, @"pressed":@YES, @"x":@0.5, @"y":@0.43, @"touch":@YES}];
            [self input:@{@"type":@"button", @"button":@1, @"pressed":@NO, @"x":@0.5, @"y":@0.43, @"touch":@YES}];
            self.phase = 3; break;
        case 3:
            if (step != 3) return;
            [self key:@"f5"]; self.savedAt = CACurrentMediaTime(); self.phase = 4; break;
        case 4:
            if (CACurrentMediaTime() - self.savedAt < 1) return;
            [self key:@"return"]; self.phase = 5; break;
        case 5:
            if (step != 4) return;
            [self key:@"f9"]; self.phase = 6; break;
        case 6:
            if (step != 3) return;
            [self command:@"quit" values:@{}]; self.phase = 7; break;
        case 7:
            if (![state[@"phase"] isEqual:@"exited"]) return;
            aether_renpy_native_close(self.runtime);
            [self openSession]; self.phase = 8; break;
        case 8:
            if (![state[@"phase"] isEqual:@"ready"] || ![state[@"main_menu"] boolValue]) return;
            if (!aether_renpy_native_is_embedded(self.runtime)) [self fail:@"Reopened SDL view is detached"];
            [self command:@"inspect" values:@{@"names":@[@"aether_probe_step", @"aether_probe_route"]}];
            [self key:@"return"]; self.phase = 9; break;
        case 9:
            if (step != 1) return;
            [self key:@"f9"]; self.phase = 10; break;
        case 10:
            if (step != 3) return;
            aether_renpy_native_pause(self.runtime, true);
            aether_renpy_native_pause(self.runtime, false);
            [self command:@"screenshot" values:@{}]; self.phase = 11; break;
        case 11:
            if ([state[@"ack"] integerValue] < self.sequence) return;
            [self command:@"quit" values:@{}]; self.phase = 12; break;
        case 12:
            if (![state[@"phase"] isEqual:@"exited"]) return;
            aether_renpy_native_close(self.runtime); self.runtime = nullptr;
            NSLog(@"RENPY_IOS_SMOKE_OK");
            [[NSJSONSerialization dataWithJSONObject:@{@"passed":@YES, @"platform":@"ios", @"session":self.session} options:0 error:nil]
                writeToFile:[self.session.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"result.json"] atomically:YES];
            [self.link invalidate]; exit(0);
    }
}
@end
@interface RenpySmokeApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation RenpySmokeApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [RenpySmokeView new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(RenpySmokeApp.class)); }
}
