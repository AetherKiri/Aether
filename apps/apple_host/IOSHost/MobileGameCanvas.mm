#import "MobileGameCanvas.h"
@interface AetherMobileCanvas ()
@property(nonatomic) CGRect previousBounds;
@property(nonatomic, weak) UITouch *primary;
@end
@implementation AetherMobileCanvas
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

