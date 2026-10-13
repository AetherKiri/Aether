#import "MobilePointerPad.h"
#import <UIKit/UIGestureRecognizerSubclass.h>
#include "TouchSequence.h"
// Recognizer callbacks precede UIScrollView's delayed content touch delivery.
// Movement comes only from the captured primary, never a multi-finger centroid.
@interface AetherPrimaryDrag : UIGestureRecognizer
@property(nonatomic, readonly) CGSize delta;
@end
@implementation AetherPrimaryDrag {
    aether::mobile::TouchSequence _sequence;
    __weak UITouch *_primary;
    CGPoint _last;
    CGSize _delta;
}
- (CGSize)delta {return _delta;}
- (NSUInteger)active:(UIEvent *)event {
    NSUInteger count=0;
    for (UITouch *touch in event.allTouches) if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled) ++count;
    return count;
}
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_sequence.begin([self active:event])) return;
    _primary=touches.anyObject; _last=[_primary locationInView:self.view]; _delta=CGSizeZero;
    self.state=UIGestureRecognizerStateBegan;
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_primary || ![touches containsObject:_primary]) return;
    CGPoint point=[_primary locationInView:self.view]; _delta=CGSizeMake(point.x-_last.x,point.y-_last.y); _last=point;
    self.state=UIGestureRecognizerStateChanged;
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    BOOL ended=_primary && [touches containsObject:_primary];
    if (ended) _primary=nil;
    NSUInteger active=[self active:event]; _sequence.finish(active,ended);
    if (!active) self.state=self.state == UIGestureRecognizerStatePossible ? UIGestureRecognizerStateFailed : UIGestureRecognizerStateEnded;
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _primary=nil; _sequence.cancel(); _sequence.finish([self active:event],true);
    self.state=self.state == UIGestureRecognizerStatePossible ? UIGestureRecognizerStateFailed : UIGestureRecognizerStateCancelled;
}
- (void)reset {[super reset]; _primary=nil; _sequence={}; _delta=CGSizeZero;}
@end
@interface AetherMobilePointerPad () <UIGestureRecognizerDelegate>
@end
@implementation AetherMobilePointerPad {
    AetherPrimaryDrag *_drag;
    __weak UIScrollView *_scroll;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.multipleTouchEnabled=YES; self.backgroundColor=UIColor.clearColor;
        _drag=[[AetherPrimaryDrag alloc] initWithTarget:self action:@selector(recognizedDrag:)];
        _drag.delegate=self; [self addGestureRecognizer:_drag];
    }
    return self;
}
- (void)recognizedDrag:(AetherPrimaryDrag *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        if (_scroll.decelerating) [_scroll setContentOffset:_scroll.contentOffset animated:NO];
        if (self.began) self.began();
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        if (self.moved && (gesture.delta.width || gesture.delta.height)) self.moved(gesture.delta);
    } else if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        if (self.ended) self.ended();
    }
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    return gesture == _drag && [other.view isKindOfClass:UIScrollView.class];
}
- (void)didMoveToSuperview {[super didMoveToSuperview]; [self wireScrollView];}
- (void)didMoveToWindow {[super didMoveToWindow]; [self wireScrollView];}
- (void)layoutSubviews {[super layoutSubviews]; [self wireScrollView];}
- (void)wireScrollView {
    UIView *parent=self.superview;
    while (parent && ![parent isKindOfClass:UIScrollView.class]) parent=parent.superview;
    UIScrollView *scroll=(UIScrollView *)parent;
    if (scroll && scroll != _scroll) {[scroll.panGestureRecognizer requireGestureRecognizerToFail:_drag]; _scroll=scroll;}
}
@end
