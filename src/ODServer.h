// ODServer — OpenDisplay 协议接收端（PROTOCOL.md pv 3），iOS 12 / Objective-C 实现。
// 监听 TCP 9000，Bonjour 广播 _opensidecar._tcp，H.264 Annex B 送入
// AVSampleBufferDisplayLayer 硬件解码显示。网络与解码都跑在一条串行队列上。
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ODServerDelegate <NSObject>
// 以下回调都在主线程
- (void)serverDidConnect:(NSString *)transport;
- (void)serverDidDisconnect;
- (void)serverVideoSizeChanged:(CGSize)size;
- (void)serverDidStartVideo;
- (void)serverCursorX:(double)x y:(double)y visible:(BOOL)visible;
- (void)serverCursorImage:(UIImage *)image nw:(double)nw nh:(double)nh ax:(double)ax ay:(double)ay;
- (void)serverNotice:(NSString *)message;
/// 每 5 秒一次的性能摘要（传输方式、分辨率、帧率、延迟、解码积压）
- (void)serverStatsText:(NSString *)text;
@end

@interface ODServer : NSObject

@property (nonatomic, weak) id<ODServerDelegate> delegate;
@property (atomic, strong, nullable) AVSampleBufferDisplayLayer *displayLayer;

- (void)start;
/// 进入后台或退出前调用；type 为 "sleeping" 或 "closing"
- (void)stopWithFarewell:(NSString *)type;

/// 当前方向下的物理像素和缩放；变化时会在活动连接上重发 hello
- (void)setPanelPixelsWide:(NSInteger)wide high:(NSInteger)high scale:(double)scale;

/// YES：原生 2048×1536；NO：标准 1600×1200。变化时在活动连接上重发 hello
- (void)setNativeQuality:(BOOL)nativeQuality;

/// WiFi 抖动缓冲：按 Mac 截屏时间 + 该延迟（毫秒）均匀显示帧；0 关闭。USB 不受影响
- (void)setSmoothingDelayMs:(NSInteger)delayMs;

- (void)sendTouchPhase:(NSString *)phase x:(double)x y:(double)y;
- (void)sendScrollDx:(double)dx dy:(double)dy;

+ (nullable NSString *)wifiAddress;

@end

NS_ASSUME_NONNULL_END
