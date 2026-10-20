// ODVideoView — 显示画面、光标和状态文字，并把触摸转换成协议坐标（PROTOCOL.md §7）。
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ODVideoViewInputDelegate <NSObject>
/// x、y 为相对画面的 0..1 坐标，左上角为原点
- (void)videoViewTouchPhase:(NSString *)phase x:(double)x y:(double)y;
/// 画面像素，自然滚动方向（手指向下 dy 为正）
- (void)videoViewScrollDx:(double)dx dy:(double)dy;
@end

@interface ODVideoView : UIView

@property (nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, weak) id<ODVideoViewInputDelegate> inputDelegate;
@property (nonatomic) CGSize videoSize;

- (void)showStatus:(nullable NSString *)text;
/// 左上角的性能信息，nil 隐藏
- (void)showStats:(nullable NSString *)text;
- (void)setCursorX:(double)x y:(double)y visible:(BOOL)visible;
- (void)setCursorImage:(UIImage *)image nw:(double)nw nh:(double)nh ax:(double)ax ay:(double)ay;
- (void)resetCursor;

@end

NS_ASSUME_NONNULL_END
