#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#include "tyrano_webview.h"

@interface TyranoMobileProbe : NSObject
@property(nonatomic, strong) UIView *surface;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSString *game;
@property(nonatomic, strong) NSString *save;
@property(nonatomic, strong) NSURL *result;
@property(nonatomic) void *handle;
@property(nonatomic) NSInteger documents;
@property(nonatomic) NSInteger frozen;
@property(nonatomic) BOOL finished;
- (void)start;
@end

@implementation TyranoMobileProbe
- (void)finish:(NSString *)failure {
    if (self.finished) return;
    self.finished = YES;
    [self.timer invalidate];
    if (self.handle) { aether_tyrano_close(self.handle); self.handle = nullptr; }
    NSDictionary *report = @{@"passed":@(!failure), @"error":failure ?: @"", @"documents":@(self.documents),
        @"checks":@[@"UIKit view and touch target", @"Chinese text and choices", @"virtual Enter", @"save thumbnail",
        @"page reload", @"player recreation", @"resource ranges and isolation", @"background/resume", @"viewport sizing"]};
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToURL:self.result atomically:YES];
    NSLog(@"%@", failure ? [@"TYRANO_IOS_HOST_FAILED: " stringByAppendingString:failure] : @"TYRANO_IOS_HOST_OK");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{ exit(failure ? 1 : 0); });
}
- (void)script:(NSString *)source { aether_tyrano_evaluate(self.handle, source.UTF8String); }
- (void)open {
    char *error = nullptr;
    self.handle = aether_tyrano_open((uint64_t)(__bridge void *)self.surface, self.game.UTF8String, self.save.UTF8String, &error);
    if (!self.handle) {
        NSString *message = error ? @(error) : @"Could not open the UIKit host";
        aether_tyrano_free_string(error);
        [self finish:message]; return;
    }
    aether_tyrano_rect(self.handle, 0, 0, 1, 1);
}
- (void)ready {
    self.documents++;
    aether_tyrano_controls(self.handle, true);
    if (self.documents == 1) {
        UIView *web = self.surface.subviews.lastObject;
        if (![web isKindOfClass:WKWebView.class] || ![[self.surface hitTest:CGPointMake(20, 20) withEvent:nil] isDescendantOfView:web]) {
            [self finish:@"Touches do not reach the child WKWebView"]; return;
        }
        [self script:@"window.__ios_test=(async()=>{"
            "const wait=async(f)=>{for(let n=0;n<300;n++){if(f())return;await new Promise(r=>setTimeout(r,20))}throw Error('scenario wait timed out: '+JSON.stringify({step:TYRANO.kag.stat.f.probe_step,adding:TYRANO.kag.stat.is_adding_text,route:TYRANO.kag.stat.f.probe_route,text:document.body.innerText}))};"
            "const check=(v,m)=>{if(!v)throw Error(m)};"
            "const waiting=()=>TYRANO.kag.ftag.array_tag[TYRANO.kag.ftag.current_order_index]?.name==='l'&&!TYRANO.kag.stat.is_adding_text&&TYRANO.kag.key_mouse.util.canClick();"
            "await wait(()=>TYRANO.kag.stat.f.probe_step===1&&waiting());"
            "check(document.body.innerText.includes('第一句'),'Chinese text');"
            "let leaked=0;const touch=()=>leaked++;document.addEventListener('touchstart',touch);"
            "const touchEvent=new Event('touchstart',{bubbles:true,cancelable:true});document.getElementById('aether-tyrano-controls').dispatchEvent(touchEvent);"
            "document.removeEventListener('touchstart',touch);check(leaked===0&&touchEvent.defaultPrevented,'virtual-key touch isolation');"
            "AetherTyranoHost.key(13,true);AetherTyranoHost.key(13,false);"
            "await wait(()=>TYRANO.kag.stat.f.probe_step===2&&waiting());"
            "jQuery('.layer_event_click').click();"
            "await wait(()=>TYRANO.kag.stat.f.probe_step===3&&jQuery('.glink_button').length===2);"
            "jQuery('.glink_button').filter(function(){return this.textContent.includes('中文选项 A')}).click();"
            "await wait(()=>TYRANO.kag.stat.f.probe_route==='A'&&waiting());"
            "TYRANO.kag.config.configThumbnail='true';await new Promise(r=>TYRANO.kag.menu.doSave(0,r));"
            "check(TYRANO.kag.menu.getSaveData().data[0].img_data.startsWith('data:image/'),'save thumbnail');"
            "localStorage.setItem('__ios_probe','中文存档');"
            "let r=await fetch('data/scenario/first.ks',{headers:{Range:'bytes=0-2'}});check(r.status===206&&(await r.arrayBuffer()).byteLength===3,'range');"
            "r=await fetch('data/outside.txt');check(r.status===403,'resource root');"
            "window.webkit.messageHandlers.aetherTyrano.postMessage({type:'log',value:'AETHER_IOS_ONE'});"
            "})().catch(e=>window.webkit.messageHandlers.aetherTyrano.postMessage({type:'log',value:'AETHER_IOS_FAIL:'+e.message}));void 0"];
    } else {
        NSString *marker = self.documents == 2 ? @"AETHER_IOS_TWO" : @"AETHER_IOS_THREE";
        [self script:[NSString stringWithFormat:@"(async()=>{"
            "if(localStorage.getItem('__ios_probe')!=='中文存档'||TYRANO.kag.menu.getSaveData().data[0].stat.f.probe_route!=='A')throw Error('persistent save');"
            "TYRANO.kag.menu.loadGame(0);"
            "for(let n=0;n<300;n++){if(TYRANO.kag.stat.f.probe_route==='A'&&document.body.innerText.includes('已选择 A'))break;if(n===299)throw Error('restore');await new Promise(r=>setTimeout(r,20))}"
            "window.__ios_counter=0;setInterval(()=>window.__ios_counter++,20);"
            "window.webkit.messageHandlers.aetherTyrano.postMessage({type:'log',value:'%@'});"
            "})().catch(e=>window.webkit.messageHandlers.aetherTyrano.postMessage({type:'log',value:'AETHER_IOS_FAIL:'+e.message}));void 0", marker]];
    }
}
- (void)event:(NSDictionary *)event {
    NSString *type = event[@"type"];
    if ([type isEqualToString:@"error"]) { [self finish:[event[@"value"] description]]; return; }
    if ([type isEqualToString:@"ready"]) { [self ready]; return; }
    NSString *value = [event[@"value"] isKindOfClass:NSString.class] ? event[@"value"] : @"";
    if ([type isEqualToString:@"log"]) {
        if ([value hasPrefix:@"AETHER_IOS_FAIL:"]) [self finish:value];
        else if ([value isEqualToString:@"AETHER_IOS_ONE"]) [self script:@"location.reload()"];
        else if ([value isEqualToString:@"AETHER_IOS_TWO"]) {
            aether_tyrano_close(self.handle); self.handle = nullptr; [self open];
        } else if ([value isEqualToString:@"AETHER_IOS_THREE"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];
                [self script:@"JSON.stringify({kind:'frozen',value:window.__ios_counter})"];
            });
        }
    } else if ([type isEqualToString:@"evaluation"]) {
        NSDictionary *answer = [NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:nil];
        if (![answer isKindOfClass:NSDictionary.class]) return;
        if ([answer[@"kind"] isEqualToString:@"frozen"]) {
            self.frozen = [answer[@"value"] integerValue];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 3), dispatch_get_main_queue(), ^{ [self script:@"JSON.stringify({kind:'still',value:window.__ios_counter})"]; });
        } else if ([answer[@"kind"] isEqualToString:@"still"]) {
            if ([answer[@"value"] integerValue] != self.frozen) { [self finish:@"Background timers did not pause"]; return; }
            [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{ [self script:@"JSON.stringify({kind:'resumed',value:window.__ios_counter})"]; });
        } else if ([answer[@"kind"] isEqualToString:@"resumed"]) {
            if ([answer[@"value"] integerValue] <= self.frozen) { [self finish:@"Foreground timers did not resume"]; return; }
            aether_tyrano_rect(self.handle, 0.1, 0.2, 0.7, 0.6);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{ [self script:@"JSON.stringify({kind:'size',width:innerWidth,height:innerHeight})"]; });
        } else if ([answer[@"kind"] isEqualToString:@"size"]) {
            CGSize size = self.surface.bounds.size;
            BOOL fits = fabs([answer[@"width"] doubleValue] - size.width * 0.7) < 3 && fabs([answer[@"height"] doubleValue] - size.height * 0.6) < 3;
            [self finish:fits ? nil : [NSString stringWithFormat:@"Native viewport mismatch: %@ in %@", answer, NSStringFromCGSize(size)]];
        }
    }
}
- (void)start {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    self.result = [documents URLByAppendingPathComponent:@"tyrano-mobile-result.json"];
    NSURL *game = [documents URLByAppendingPathComponent:@"Game"];
    NSError *error = nil;
    [NSFileManager.defaultManager copyItemAtURL:[NSBundle.mainBundle URLForResource:@"Game" withExtension:nil] toURL:game error:&error];
    if (error) { [self finish:error.localizedDescription]; return; }
    NSURL *outside = [documents URLByAppendingPathComponent:@"outside.txt"];
    [@"Private test sentinel" writeToURL:outside atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager createSymbolicLinkAtURL:[game URLByAppendingPathComponent:@"data/outside.txt"] withDestinationURL:outside error:&error];
    if (error) { [self finish:error.localizedDescription]; return; }
    self.game = [game URLByAppendingPathComponent:@"index.html"].path;
    self.save = [documents URLByAppendingPathComponent:@"Saves/local_storage.json"].path;
    [self open];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.02 repeats:YES block:^(NSTimer *timer) {
        for (int n = 0; self.handle && n < 64; n++) {
            char *json = aether_tyrano_poll(self.handle); if (!json) break;
            NSDictionary *event = [NSJSONSerialization JSONObjectWithData:[@(json) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            aether_tyrano_free_string(json);
            [self event:event];
        }
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self finish:@"The mobile engine test timed out"]; });
}
@end

@interface TyranoProbeApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) TyranoMobileProbe *probe;
@end
@implementation TyranoProbeApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *controller = [UIViewController new];
    self.window.rootViewController = controller;
    controller.view.backgroundColor = UIColor.blackColor;
    [self.window makeKeyAndVisible];
    self.probe = [TyranoMobileProbe new]; self.probe.surface = controller.view;
    dispatch_async(dispatch_get_main_queue(), ^{ [self.probe start]; });
    return YES;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(TyranoProbeApp.class)); }
}
