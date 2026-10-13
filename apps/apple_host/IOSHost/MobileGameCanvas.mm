#import "MobileGameCanvas.h"
#import <QuartzCore/QuartzCore.h>
#include "TouchSequence.h"
#include <cmath>
@interface AetherMobileCanvas ()
@property(nonatomic) CGRect previousBounds;
@property(nonatomic, weak) UITouch *primary;
@end
@implementation AetherMobileCanvas {
    aether::mobile::TouchSequence _sequence;
    CGPoint _lastPoint;
    CGPoint _cursorPosition;
    CAShapeLayer *_cursorLayer;
}
- (CGRect)contentRect {
    if (self.canvas.width <= 0 || self.canvas.height <= 0 || self.bounds.size.width <= 0 || self.bounds.size.height <= 0) return CGRectZero;
    CGFloat scale=MIN(self.bounds.size.width/self.canvas.width,self.bounds.size.height/self.canvas.height);
    return CGRectMake((self.bounds.size.width-self.canvas.width*scale)/2,
                      (self.bounds.size.height-self.canvas.height*scale)/2,self.canvas.width*scale,self.canvas.height*scale);
}
- (CGPoint)logicalPointForViewPoint:(CGPoint)p clamp:(BOOL)clamp {
    CGRect rect=self.contentRect;
    if (CGRectIsEmpty(rect) || !std::isfinite(p.x) || !std::isfinite(p.y) || (!clamp && !CGRectContainsPoint(rect,p))) return CGPointMake(-1,-1);
    CGFloat scale=rect.size.width/self.canvas.width;
    return CGPointMake(MAX(0,MIN(self.canvas.width-1,(p.x-rect.origin.x)/scale)),
                       MAX(0,MIN(self.canvas.height-1,(p.y-rect.origin.y)/scale)));
}
- (void)setCanvas:(CGSize)canvas {
    if (CGSizeEqualToSize(_canvas,canvas)) return;
    [self cancelPointer]; if (self.inputInvalidated) self.inputInvalidated();
    _canvas=canvas; _cursorPosition=CGPointMake(MAX(0,(canvas.width-1)/2),MAX(0,(canvas.height-1)/2));
    [self updateCursor];
}
- (void)setVirtualMouse:(BOOL)mouse {
    if (_virtualMouse == mouse) return;
    [self cancelPointer]; _virtualMouse=mouse; [self updateCursor];
}
- (CGPoint)cursorPosition {return _cursorPosition;}
- (CGPoint)moveCursorBy:(CGSize)delta {
    CGRect rect=self.contentRect;
    if (CGRectIsEmpty(rect) || !std::isfinite(delta.width) || !std::isfinite(delta.height)) return _cursorPosition;
    CGFloat scale=rect.size.width/self.canvas.width;
    _cursorPosition=CGPointMake(MAX(0,MIN(self.canvas.width-1,_cursorPosition.x+delta.width/scale)),
                               MAX(0,MIN(self.canvas.height-1,_cursorPosition.y+delta.height/scale)));
    [self updateCursor]; return _cursorPosition;
}
- (void)updateCursor {
    if (!_cursorLayer) {
        _cursorLayer=[CAShapeLayer layer]; _cursorLayer.strokeColor=UIColor.whiteColor.CGColor;
        _cursorLayer.fillColor=UIColor.clearColor.CGColor; _cursorLayer.lineWidth=2;
        _cursorLayer.shadowColor=UIColor.blackColor.CGColor; _cursorLayer.shadowOpacity=1; _cursorLayer.shadowRadius=2;
        [self.layer addSublayer:_cursorLayer];
    }
    CGRect rect=self.contentRect; _cursorLayer.hidden=!self.virtualMouse || CGRectIsEmpty(rect);
    if (_cursorLayer.hidden) return;
    CGFloat scale=rect.size.width/self.canvas.width;
    CGPoint p=CGPointMake(rect.origin.x+_cursorPosition.x*scale,rect.origin.y+_cursorPosition.y*scale);
    UIBezierPath *path=[UIBezierPath bezierPathWithOvalInRect:CGRectMake(p.x-7,p.y-7,14,14)];
    [path moveToPoint:CGPointMake(p.x-11,p.y)]; [path addLineToPoint:CGPointMake(p.x+11,p.y)];
    [path moveToPoint:CGPointMake(p.x,p.y-11)]; [path addLineToPoint:CGPointMake(p.x,p.y+11)];
    [CATransaction begin]; [CATransaction setDisableActions:YES]; _cursorLayer.frame=self.bounds; _cursorLayer.path=path.CGPath; [CATransaction commit];
}
- (NSUInteger)activeTouches:(UIEvent *)event {
    NSUInteger count=0;
    for (UITouch *touch in event.allTouches) if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) ++count;
    return count;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.virtualMouse || !_sequence.begin([self activeTouches:event])) return;
    UITouch *touch=touches.anyObject;
    CGPoint p=[self logicalPointForViewPoint:[touch locationInView:self] clamp:NO];
    if (p.x < 0) {_sequence.reject(); return;}
    self.primary=touch; _lastPoint=p;
    if (self.pointer) self.pointer(ENGINE_INPUT_EVENT_POINTER_DOWN,p,0);
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.primary && [touches containsObject:self.primary]) {
        _lastPoint=[self logicalPointForViewPoint:[self.primary locationInView:self] clamp:YES];
        if (self.pointer) self.pointer(ENGINE_INPUT_EVENT_POINTER_MOVE,_lastPoint,0);
    }
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    BOOL ended=self.primary && [touches containsObject:self.primary];
    if (ended) {
        _lastPoint=[self logicalPointForViewPoint:[self.primary locationInView:self] clamp:YES];
        if (self.pointer) self.pointer(ENGINE_INPUT_EVENT_POINTER_UP,_lastPoint,0);
        self.primary=nil;
    }
    _sequence.finish([self activeTouches:event],ended);
}
- (void)cancelPointer {
    if (self.primary) {
        if (self.pointer) self.pointer(ENGINE_INPUT_EVENT_POINTER_UP,_lastPoint,ENGINE_INPUT_MODIFIER_POINTER_CANCEL);
        self.primary=nil;
    }
    _sequence.cancel();
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self cancelPointer]; _sequence.finish([self activeTouches:event],false);
    if (self.inputInvalidated) self.inputInvalidated();
}
- (void)layoutSubviews {
    if (!CGRectEqualToRect(self.bounds,self.previousBounds)) [self cancelPointer];
    self.previousBounds=self.bounds; [super layoutSubviews]; [self updateCursor];
}
@end
