#import <UIKit/UIKit.h>
#import "EngineSession.h"
@interface AetherMobileCanvas : UIImageView
@property(nonatomic, copy) void (^pointer)(uint32_t, CGPoint, int32_t);
@property(nonatomic, copy) void (^inputInvalidated)(void);
@property(nonatomic) CGSize canvas;
@property(nonatomic) BOOL virtualMouse;
@property(nonatomic, readonly) CGPoint cursorPosition;
@property(nonatomic, readonly) CGRect contentRect;
- (CGPoint)logicalPointForViewPoint:(CGPoint)point clamp:(BOOL)clamp;
- (CGPoint)moveCursorBy:(CGSize)delta;
- (void)cancelPointer;
@end
