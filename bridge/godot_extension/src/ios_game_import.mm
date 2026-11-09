#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <cstdlib>
#include <cstring>

// Implemented by GameImportHost.swift, compiled into the iOS Swift archive.
@interface AetherGameImportHost : NSObject
+ (instancetype)shared;
- (BOOL)acceptURL:(NSURL *)url;
- (void)consumePending;
- (NSString *)takeEventJSON;
@end

// Godot's delegate service API forwards both cold scene connection options and
// warm open-URL callbacks without replacing any engine or StoreKit delegate.
@interface AetherGameImportDelegate : NSObject <UIApplicationDelegate, UIWindowSceneDelegate>
@end
@implementation AetherGameImportDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSURL *url = options[UIApplicationLaunchOptionsURLKey];
    if (url) [[AetherGameImportHost shared] acceptURL:url];
    return YES;
}
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary *)options {
    return [[AetherGameImportHost shared] acceptURL:url];
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    for (UIOpenURLContext *context in options.URLContexts) [[AetherGameImportHost shared] acceptURL:context.URL];
}
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    for (UIOpenURLContext *context in contexts) [[AetherGameImportHost shared] acceptURL:context.URL];
}
- (void)applicationDidBecomeActive:(UIApplication *)application { [[AetherGameImportHost shared] consumePending]; }
- (void)sceneDidBecomeActive:(UIScene *)scene { [[AetherGameImportHost shared] consumePending]; }
@end

// Constructors run after Objective-C +load initializes Godot's services list,
// and before UIApplicationMain can deliver a cold-start file URL.
__attribute__((constructor)) static void InstallGameImportDelegate() {
    @autoreleasepool {
        Class delegate = NSClassFromString(@"GDTApplicationDelegate"); // Godot 4.7
        if (!delegate) delegate = NSClassFromString(@"GDTAppDelegate");
        SEL addService = NSSelectorFromString(@"addService:");
        if ([delegate respondsToSelector:addService]) {
            ((void (*)(id, SEL, id))objc_msgSend)(delegate, addService, [AetherGameImportDelegate new]);
        } else {
            NSLog(@"[AetherImport] This Godot template has no application delegate service API");
        }
    }
}

char *aether_ios_import_take_event() {
    NSString *json = [[AetherGameImportHost shared] takeEventJSON];
    return json ? strdup(json.UTF8String) : nullptr;
}
void aether_ios_import_consume_pending() { [[AetherGameImportHost shared] consumePending]; }
