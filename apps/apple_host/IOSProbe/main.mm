// Internal migration probe: actual KiriKiri, software frames, UIKit touch.
// Not the shipping SwiftUI shell; no store or agreement UI is claimed here.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "EngineSession.h"
#import "MobileSessionDriver.h"
extern "C" uint32_t aether_apple_host_core_initialize(void);
#if DEBUG
void RunMobileDriverIntegrationTests(AetherMobileSessionDriver *, AetherEngineSession *, UIWindowScene *);
#endif

@interface ProbeCanvas : UIImageView
@property(nonatomic, copy) void (^pointer)(uint32_t, CGPoint, int32_t);
@property(nonatomic) CGSize canvas;
@property(nonatomic) CGRect previousBounds;
@property(nonatomic, weak) UITouch *primary;
@end
@implementation ProbeCanvas
- (CGPoint)mapped:(UITouch *)touch clamp:(BOOL)clamp {
    CGPoint p = [touch locationInView:self];
    double scale = MIN(self.bounds.size.width / MAX(1, self.canvas.width),
                       self.bounds.size.height / MAX(1, self.canvas.height));
    if (scale <= 0 || self.canvas.width <= 0) return CGPointMake(-1, -1);
    CGRect rect = CGRectMake((self.bounds.size.width-self.canvas.width*scale)/2,
                             (self.bounds.size.height-self.canvas.height*scale)/2,
                             self.canvas.width*scale, self.canvas.height*scale);
    if (!clamp && !CGRectContainsPoint(rect, p)) return CGPointMake(-1, -1);
    return CGPointMake(MAX(0,MIN(self.canvas.width-1,(p.x-rect.origin.x)/scale)),
                       MAX(0,MIN(self.canvas.height-1,(p.y-rect.origin.y)/scale)));
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.primary || event.allTouches.count != 1) return;
    UITouch *touch = touches.anyObject;
    CGPoint p = [self mapped:touch clamp:NO];
    if (p.x < 0) return;
    self.primary = touch;
    if (self.pointer) self.pointer(ENGINE_INPUT_EVENT_POINTER_DOWN, p, 0);
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.primary && [touches containsObject:self.primary] && self.pointer)
        self.pointer(ENGINE_INPUT_EVENT_POINTER_MOVE, [self mapped:self.primary clamp:YES], 0);
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.primary && [touches containsObject:self.primary]) {
        if (self.pointer) self.pointer(ENGINE_INPUT_EVENT_POINTER_UP, [self mapped:self.primary clamp:YES], 0);
        self.primary = nil;
    }
}
- (void)cancelPointer {
    if (!self.primary) return;
    if (self.pointer) self.pointer(ENGINE_INPUT_EVENT_POINTER_UP, [self mapped:self.primary clamp:YES], ENGINE_INPUT_MODIFIER_POINTER_CANCEL);
    self.primary = nil;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self cancelPointer]; }
- (void)layoutSubviews {
    if (!CGRectEqualToRect(self.bounds, self.previousBounds)) [self cancelPointer];
    self.previousBounds = self.bounds; [super layoutSubviews];
}
@end

@interface ProbeController : UIViewController
@property(nonatomic) AetherEngineSession *session;
@property(nonatomic) AetherMobileSessionDriver *driver;
@property(nonatomic) ProbeCanvas *canvas;
@property(nonatomic) UILabel *status;
@property(nonatomic) CFTimeInterval lastStatus;
@property(nonatomic) uint64_t ticks;
@property(nonatomic) BOOL running;
@end
@implementation ProbeController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.status = [UILabel new]; self.status.textColor = UIColor.whiteColor;
    self.status.numberOfLines = 0;
    self.status.text = @"iOS migration probe · KiriKiri · software baseline";
    self.canvas = [ProbeCanvas new]; self.canvas.contentMode = UIViewContentModeScaleAspectFit;
    [self.canvas setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [self.canvas setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    self.canvas.userInteractionEnabled = YES; self.canvas.multipleTouchEnabled = YES;
    __weak ProbeController *weakSelf = self;
    self.canvas.pointer = ^(uint32_t type, CGPoint p, int32_t modifiers) {
        ProbeController *owner = weakSelf;
        if (!owner.running || (owner.driver.pauseReasons != 0 && !(modifiers & ENGINE_INPUT_MODIFIER_POINTER_CANCEL))) return;
        [owner.session sendPointerEventWithType:type pointerId:0 x:p.x y:p.y deltaX:0 deltaY:0 button:0 modifiers:modifiers];
        NSLog(@"PROBE pointer type=%u x=%.1f y=%.1f", type,p.x,p.y);
    };
    UIButton *start = [UIButton buttonWithType:UIButtonTypeSystem];
    [start setTitle:@"Run Demo" forState:UIControlStateNormal];
    [start addTarget:self action:@selector(startDemo) forControlEvents:UIControlEventTouchUpInside];
    UIButton *enter = [UIButton buttonWithType:UIButtonTypeSystem];
    [enter setTitle:@"Enter" forState:UIControlStateNormal];
    [enter addTarget:self action:@selector(enter) forControlEvents:UIControlEventTouchUpInside];
    UIButton *stop = [UIButton buttonWithType:UIButtonTypeSystem];
    [stop setTitle:@"Stop" forState:UIControlStateNormal];
    [stop addTarget:self action:@selector(stopDemo) forControlEvents:UIControlEventTouchUpInside];
    UIButton *resume = [UIButton buttonWithType:UIButtonTypeSystem];
    [resume setTitle:@"Resume Audio" forState:UIControlStateNormal];
    [resume addTarget:self action:@selector(resumeAudio) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[start,enter,stop,resume]];
    buttons.distribution = UIStackViewDistributionFillEqually;
    [buttons.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.status,buttons,self.canvas]];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor], [stack.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]]];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
#if DEBUG
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--lifecycle-self-test"]) {
        [self startDemo];
        if (self.running) RunMobileDriverIntegrationTests(self.driver,self.session,self.view.window.windowScene);
    }
#endif
}
- (void)startDemo {
    [self stopDemo];
    aether_apple_host_core_initialize(); // Pulls static registration object into the final link.
    self.session = [AetherEngineSession new];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *documents = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *cache = [fm URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *game = [documents URLByAppendingPathComponent:@"Games/Demo" isDirectory:YES];
    NSError *error = nil;
    if (![fm createDirectoryAtURL:game withIntermediateDirectories:YES attributes:nil error:&error]) { [self failed:error]; return; }
    NSURL *source = [NSBundle.mainBundle URLForResource:@"data" withExtension:@"xp3"];
    NSString *font = [NSBundle.mainBundle pathForResource:@"aetherkiri-runtime-cjk" ofType:@"otf"];
    if (!source || !font) {
        [self failed:[NSError errorWithDomain:@"Probe" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Missing bundled Demo or font"}]]; return;
    }
    NSURL *packed = [game URLByAppendingPathComponent:@"data.xp3"];
    if (![fm fileExistsAtPath:packed.path] && ![fm copyItemAtURL:source toURL:packed error:&error]) {
        [self failed:error]; return;
    }
    if (![self.session initializeWithWritablePath:documents.path cachePath:cache.path error:&error]
        || ![self.session setOption:@"renderer" value:@"software" error:&error]
        || ![self.session setOption:@"frame_output" value:@"raw_source" error:&error]
        || ![self.session setOption:@"default_font" value:font error:&error]) { [self failed:error]; return; }
    self.running = YES; self.ticks = 0; self.lastStatus = 0;
    self.driver = [[AetherMobileSessionDriver alloc] initWithSession:self.session scene:self.view.window.windowScene];
    __weak ProbeController *weakSelf = self;
    self.driver.tick = ^(uint32_t delta) { [weakSelf tickWithDelta:delta]; };
    self.driver.willPause = ^{ [weakSelf.canvas cancelPointer]; };
    self.driver.stateChanged = ^(uint32_t reasons) {
        if (reasons) weakSelf.status.text = [NSString stringWithFormat:@"Paused · reasons %u · %@",reasons,
            (reasons & (1u << 5)) ? @"Audio services lost; restart Demo" : @"Resume Audio when all interruption reasons have cleared"];
    };
    if (![self.driver start:&error] || ![self.session openGameAtPath:game.path error:&error]) { [self failed:error]; return; }
    NSLog(@"PROBE started api=%u",self.session.engineAPIVersion);
}
- (void)failed:(NSError *)error { [self stopDemo]; self.status.text = error.localizedDescription ?: @"Engine start failed"; NSLog(@"PROBE failed %@",error); }
- (void)tickWithDelta:(uint32_t)delta {
    CFTimeInterval timestamp = CACurrentMediaTime();
    [self.session tickWithDeltaMS:delta]; self.ticks++;
    CGImageRef image = [self.session copyFrameImage];
    if (image) {
        self.canvas.canvas = CGSizeMake(CGImageGetWidth(image),CGImageGetHeight(image));
        self.canvas.image = [UIImage imageWithCGImage:image]; CGImageRelease(image);
        [self.session setSurfaceSize:(uint32_t)self.canvas.canvas.width height:(uint32_t)self.canvas.canvas.height error:nil];
    }
    if (self.session.startupState == ENGINE_STARTUP_STATE_FAILED) { [self failed:[NSError errorWithDomain:@"Probe" code:1 userInfo:@{NSLocalizedDescriptionKey:self.session.lastError}]]; return; }
    if (timestamp-self.lastStatus > 0.25) {
        self.lastStatus = timestamp;
        self.status.text = [NSString stringWithFormat:@"Software · state %u · tick %llu · %.0f×%.0f",self.session.startupState,self.ticks,self.canvas.canvas.width,self.canvas.canvas.height];
    }
}
- (void)enter {
    if (!self.running || self.driver.pauseReasons != 0) return;
    [self.session sendKeyEvent:YES keyCode:0x0D modifiers:0 unicode:0];
    [self.session sendKeyEvent:NO keyCode:0x0D modifiers:0 unicode:0];
    NSLog(@"PROBE enter");
}
- (void)resumeAudio { [self.driver requestUserResume]; }
- (void)stopDemo {
    [self.canvas cancelPointer]; [self.driver stop]; self.driver = nil;
    [self.session shutdown]; self.session = nil; self.running = NO;
    self.canvas.image = nil; self.status.text = @"Stopped · Run Demo to start";
    NSLog(@"PROBE stopped");
}
- (void)dealloc { [self.driver stop]; [self.session shutdown]; }
@end

@interface ProbeScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic) UIWindow *window;
@end
@implementation ProbeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [ProbeController new]; [self.window makeKeyAndVisible];
}
- (void)sceneDidDisconnect:(UIScene *)scene { [(ProbeController *)self.window.rootViewController stopDemo]; }
@end
@interface ProbeApp : UIResponder <UIApplicationDelegate>
@end
@implementation ProbeApp
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Probe" sessionRole:session.role];
    configuration.delegateClass = ProbeScene.class; return configuration;
}
@end
int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(ProbeApp.class)); } }
