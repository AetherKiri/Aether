#import <UIKit/UIKit.h>
@interface AetherMobilePointerPad : UIView
@property(nonatomic, copy) void (^began)(void);
@property(nonatomic, copy) void (^moved)(CGSize);
@property(nonatomic, copy) void (^ended)(void);
@end
