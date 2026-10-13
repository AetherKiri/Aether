#import <UIKit/UIKit.h>
#import "EngineSession.h"
@interface AetherMobileCanvas : UIImageView
@property(nonatomic, copy) void (^pointer)(uint32_t, CGPoint, int32_t);
@property(nonatomic) CGSize canvas;
- (void)cancelPointer;
@end
