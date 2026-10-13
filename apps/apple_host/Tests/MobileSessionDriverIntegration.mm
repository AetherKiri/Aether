// Debug-only real-engine notification injection. Does not simulate hardware audio.
#import "MobileSessionDriver.h"
#import <AVFAudio/AVFAudio.h>
#include "SessionTiming.h"
using namespace aether::mobile;
@interface MobileDriverTest : NSObject
@property(nonatomic) AetherMobileSessionDriver *driver;
@property(nonatomic) AetherEngineSession *session;
@property(nonatomic) NSArray<NSDictionary *> *cases;
@property(nonatomic) NSMutableArray<NSDictionary *> *results;
@property(nonatomic) NSUInteger index;
@property(nonatomic) uint64_t ticks;
@property(nonatomic) BOOL nextIsFirst;
@property(nonatomic) BOOL firstDeltaOK;
@property(nonatomic, copy) void (^originalTick)(uint32_t);
@property(nonatomic, copy) void (^originalState)(uint32_t);
@end
@implementation MobileDriverTest
- (void)waitForActiveScene:(UIWindowScene *)scene attempts:(NSUInteger)attempts {
    if (scene.activationState == UISceneActivationStateForegroundActive && self.driver.pauseReasons == 0) {
        [self next]; return;
    }
    if (!attempts) {
        [self.results addObject:@{@"name":@"foreground setup", @"passed":@NO}];
        self.cases=@[]; [self next]; return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        [self waitForActiveScene:scene attempts:attempts-1];
    });
}
- (void)next {
    if (self.index == self.cases.count) {
        self.driver.tick = self.originalTick; self.driver.stateChanged = self.originalState;
        BOOL passed = YES;
        for (NSDictionary *item in self.results) if (![item[@"passed"] boolValue]) passed = NO;
        NSDictionary *report = @{@"passed":@(passed), @"kind":@"simulator-notification-injection",
                                @"firstResumeDeltaZero":@(self.firstDeltaOK), @"cases":self.results};
        NSURL *root = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
             writeToURL:[root URLByAppendingPathComponent:@"mobile-lifecycle-test.json"] atomically:YES];
        NSLog(@"MOBILE TEST finished passed=%d", passed && self.firstDeltaOK);
        return;
    }
    NSDictionary *test = self.cases[self.index++];
    void (^action)(void) = test[@"action"]; action();
    uint64_t before = self.ticks;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        uint32_t expected = [test[@"reasons"] unsignedIntValue];
        BOOL expectTicks = test[@"ticking"] ? [test[@"ticking"] boolValue] : expected == 0;
        BOOL tickingCorrect = expectTicks ? self.ticks > before : self.ticks == before;
        BOOL passed = self.driver.pauseReasons == expected && tickingCorrect && self.firstDeltaOK;
        [self.results addObject:@{@"name":test[@"name"], @"expectedReasons":@(expected),
                                  @"actualReasons":@(self.driver.pauseReasons), @"ticksBefore":@(before),
                                  @"ticksAfter":@(self.ticks), @"passed":@(passed)}];
        NSLog(@"MOBILE TEST %@ passed=%d", test[@"name"], passed);
        [self next];
    });
}
@end
void RunMobileDriverIntegrationTests(AetherMobileSessionDriver *driver, AetherEngineSession *session, UIWindowScene *scene) {
    MobileDriverTest *test = [MobileDriverTest new];
    test.driver=driver; test.session=session; test.results=[NSMutableArray new]; test.firstDeltaOK=YES;
    test.originalTick=driver.tick; test.originalState=driver.stateChanged;
    __weak MobileDriverTest *weakTest = test;
    driver.tick = ^(uint32_t delta) {
        MobileDriverTest *owner=weakTest;
        owner.ticks++;
        if (owner.nextIsFirst) { owner.firstDeltaOK = owner.firstDeltaOK && delta == 0; owner.nextIsFirst=NO; }
        if (owner.originalTick) owner.originalTick(delta);
    };
    driver.stateChanged = ^(uint32_t reasons) {
        MobileDriverTest *owner=weakTest;
        if (!reasons) owner.nextIsFirst=YES;
        if (owner.originalState) owner.originalState(reasons);
    };
    void (^post)(NSNotificationName,id,NSDictionary *) = ^(NSNotificationName name,id object,NSDictionary *info) {
        [NSNotificationCenter.defaultCenter postNotificationName:name object:object userInfo:info];
    };
    id audio=AVAudioSession.sharedInstance;
    test.cases=@[
      @{@"name":@"background and interruption overlap", @"reasons":@(sceneInactive|audioInterruption), @"action":[^{
        post(UISceneWillDeactivateNotification,scene,nil);
        post(AVAudioSessionInterruptionNotification,audio,@{AVAudioSessionInterruptionTypeKey:@(AVAudioSessionInterruptionTypeBegan)});
      } copy]},
      @{@"name":@"foreground retains interruption", @"reasons":@(audioInterruption), @"action":[^{post(UISceneDidActivateNotification,scene,nil);} copy]},
      @{@"name":@"should-resume clears final reason", @"reasons":@0, @"action":[^{
        post(AVAudioSessionInterruptionNotification,audio,@{AVAudioSessionInterruptionTypeKey:@(AVAudioSessionInterruptionTypeEnded),AVAudioSessionInterruptionOptionKey:@(AVAudioSessionInterruptionOptionShouldResume)});
      } copy]},
      @{@"name":@"modal and background overlap", @"reasons":@(systemModal|sceneInactive), @"action":[^{[driver setSystemModalPresented:YES];post(UISceneWillDeactivateNotification,scene,nil);} copy]},
      @{@"name":@"dismiss modal retains background", @"reasons":@(sceneInactive), @"action":[^{[driver setSystemModalPresented:NO];} copy]},
      @{@"name":@"foreground resets elapsed", @"reasons":@0, @"action":[^{post(UISceneDidActivateNotification,scene,nil);} copy]},
      @{@"name":@"denied automatic resume stays paused", @"reasons":@(userResumeRequired), @"action":[^{
        post(AVAudioSessionInterruptionNotification,audio,@{AVAudioSessionInterruptionTypeKey:@(AVAudioSessionInterruptionTypeBegan)});
        post(AVAudioSessionInterruptionNotification,audio,@{AVAudioSessionInterruptionTypeKey:@(AVAudioSessionInterruptionTypeEnded)});
      } copy]},
      @{@"name":@"explicit user resume", @"reasons":@0, @"action":[^{[driver requestUserResume];} copy]},
      @{@"name":@"application and interruption overlap", @"reasons":@(applicationInactive|audioInterruption), @"action":[^{
        post(UIApplicationWillResignActiveNotification,UIApplication.sharedApplication,nil);
        post(AVAudioSessionInterruptionNotification,audio,@{AVAudioSessionInterruptionTypeKey:@(AVAudioSessionInterruptionTypeBegan)});
      } copy]},
      @{@"name":@"app activation retains interruption", @"reasons":@(audioInterruption), @"action":[^{post(UIApplicationDidBecomeActiveNotification,UIApplication.sharedApplication,nil);} copy]},
      @{@"name":@"interruption ends after app activation", @"reasons":@0, @"action":[^{
        post(AVAudioSessionInterruptionNotification,audio,@{AVAudioSessionInterruptionTypeKey:@(AVAudioSessionInterruptionTypeEnded),AVAudioSessionInterruptionOptionKey:@(AVAudioSessionInterruptionOptionShouldResume)});
      } copy]},
      @{@"name":@"output unplug pauses", @"reasons":@(userResumeRequired), @"action":[^{post(AVAudioSessionRouteChangeNotification,audio,@{AVAudioSessionRouteChangeReasonKey:@(AVAudioSessionRouteChangeReasonOldDeviceUnavailable)});} copy]},
      @{@"name":@"explicit resume after unplug", @"reasons":@0, @"action":[^{[driver requestUserResume];} copy]},
      @{@"name":@"media service loss requires restart", @"reasons":@(audioServicesLost), @"action":[^{post(AVAudioSessionMediaServicesWereLostNotification,audio,nil);[driver requestUserResume];} copy]},
      @{@"name":@"stop removes clock and observers", @"reasons":@0, @"ticking":@NO, @"action":[^{[driver stop];post(UISceneWillDeactivateNotification,scene,nil);post(AVAudioSessionInterruptionNotification,audio,@{AVAudioSessionInterruptionTypeKey:@(AVAudioSessionInterruptionTypeBegan)});} copy]},
    ];
    [test waitForActiveScene:scene attempts:200]; // continuation owns the fixture until completion.
}
