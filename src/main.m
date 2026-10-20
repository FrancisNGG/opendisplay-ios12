// OpenDisplay iOS 12 接收端：应用入口、视图控制器和生命周期。
#import <UIKit/UIKit.h>
#import "ODServer.h"
#import "ODVideoView.h"

@interface ODViewController : UIViewController <ODServerDelegate, ODVideoViewInputDelegate>
@property (nonatomic, strong) ODServer *server;
@property (nonatomic, strong) ODVideoView *videoView;
@end

@implementation ODViewController {
    BOOL _connected;
    BOOL _hasVideo;
    NSString *_notice;
    BOOL _showStats;
    NSString *_lastStats;
}

- (void)loadView {
    self.videoView = [[ODVideoView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.videoView.inputDelegate = self;
    self.view = self.videoView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.server = [[ODServer alloc] init];
    self.server.delegate = self;
    self.server.displayLayer = self.videoView.displayLayer;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [self.server setNativeQuality:[defaults boolForKey:@"od.nativeQuality"]];
    _showStats = [defaults boolForKey:@"od.showStats"];
    [self.server setSmoothingDelayMs:[self smoothDelayMs]];

    // 三指轻点打开设置菜单
    UITapGestureRecognizer *menuTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showMenu:)];
    menuTap.numberOfTouchesRequired = 3;
    [self.videoView addGestureRecognizer:menuTap];
    [self refreshStatus];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self announcePanel:self.view.bounds.size];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self announcePanel:size];   // §6.1：旋转后用新方向重发 hello
}

- (void)announcePanel:(CGSize)points {
    CGFloat scale = [UIScreen mainScreen].nativeScale;
    [self.server setPanelPixelsWide:(NSInteger)lround(points.width * scale)
                               high:(NSInteger)lround(points.height * scale)
                              scale:scale];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (void)refreshStatus {
    if (_hasVideo) { [self.videoView showStatus:_notice]; return; }
    NSMutableString *text = [NSMutableString stringWithString:@"OpenDisplay · iOS 12 移植版\n\n"];
    if (_connected) {
        [text appendString:@"已连接，等待画面…"];
    } else {
        [text appendString:@"等待 Mac 上的 OpenDisplay 连接\n\n用数据线连接，或连到同一个 WiFi"];
        NSString *ip = [ODServer wifiAddress];
        if (ip) [text appendFormat:@"\nWiFi 地址：%@:9000", ip];
    }
    if (_notice.length) [text appendFormat:@"\n\n%@", _notice];
    [self.videoView showStatus:text];
}

/// 默认 60 ms，用户改过就用保存的值（0 = 关闭）
- (NSInteger)smoothDelayMs {
    NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"od.smoothDelayMs"];
    return saved ? saved.integerValue : 60;
}

- (void)showMenu:(UITapGestureRecognizer *)gesture {
    if (self.presentedViewController) return;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL native = [defaults boolForKey:@"od.nativeQuality"];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"OpenDisplay 设置"
                                                                  message:@"原生画质只在 USB 下生效；WiFi 带宽不够，总用标准画质。\nWiFi 卡顿时，请在 Mac 端 OpenDisplay 把画质调成 Balanced 或 Fast。"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    void (^setQuality)(BOOL) = ^(BOOL value) {
        [defaults setBool:value forKey:@"od.nativeQuality"];
        [self.server setNativeQuality:value];
    };
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@标准画质 1600×1200", native ? @"" : @"✓ "]
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { setQuality(NO); }]];
    [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@原生画质 2048×1536（仅 USB）", native ? @"✓ " : @""]
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) { setQuality(YES); }]];
    NSInteger smooth = [self smoothDelayMs];
    for (NSNumber *option in @[@0, @60, @100]) {
        NSInteger value = option.integerValue;
        NSString *name = value == 0 ? @"WiFi 平滑播放：关闭（延迟最低）"
                                    : [NSString stringWithFormat:@"WiFi 平滑播放：%ld ms", (long)value];
        [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@%@", smooth == value ? @"✓ " : @"", name]
                                                 style:UIAlertActionStyleDefault
                                               handler:^(UIAlertAction *a) {
            [defaults setInteger:value forKey:@"od.smoothDelayMs"];
            [self.server setSmoothingDelayMs:value];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:_showStats ? @"隐藏性能信息" : @"显示性能信息"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
        self->_showStats = !self->_showStats;
        [defaults setBool:self->_showStats forKey:@"od.showStats"];
        [self.videoView showStats:self->_showStats ? (self->_lastStats ?: @"等待统计…") : nil];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    CGPoint at = [gesture locationInView:self.view];
    menu.popoverPresentationController.sourceView = self.view;
    menu.popoverPresentationController.sourceRect = CGRectMake(at.x, at.y, 1, 1);
    [self presentViewController:menu animated:YES completion:nil];
}

#pragma mark ODServerDelegate

- (void)serverDidConnect:(NSString *)transport {
    _connected = YES;
    _hasVideo = NO;
    _notice = nil;
    [self.videoView resetCursor];
    [self refreshStatus];
}

- (void)serverDidDisconnect {
    _connected = NO;
    _lastStats = nil;
    if (_showStats) [self.videoView showStats:@"未连接"];
    _hasVideo = NO;
    [self.videoView resetCursor];
    [self refreshStatus];
}

- (void)serverVideoSizeChanged:(CGSize)size {
    self.videoView.videoSize = size;
}

- (void)serverDidStartVideo {
    _hasVideo = YES;
    [self refreshStatus];
}

- (void)serverCursorX:(double)x y:(double)y visible:(BOOL)visible {
    [self.videoView setCursorX:x y:y visible:visible];
}

- (void)serverCursorImage:(UIImage *)image nw:(double)nw nh:(double)nh ax:(double)ax ay:(double)ay {
    [self.videoView setCursorImage:image nw:nw nh:nh ax:ax ay:ay];
}

- (void)serverStatsText:(NSString *)text {
    _lastStats = text;
    if (_showStats) [self.videoView showStats:text];
}

- (void)serverNotice:(NSString *)message {
    _notice = message;
    [self refreshStatus];
}

#pragma mark ODVideoViewInputDelegate

- (void)videoViewTouchPhase:(NSString *)phase x:(double)x y:(double)y {
    [self.server sendTouchPhase:phase x:x y:y];
}

- (void)videoViewScrollDx:(double)dx dy:(double)dy {
    [self.server sendScrollDx:dx dy:dy];
}

@end

#pragma mark - App delegate

@interface ODAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) ODViewController *controller;
@end

@implementation ODAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.controller = [[ODViewController alloc] init];
    self.window.rootViewController = self.controller;
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    application.idleTimerDisabled = YES;   // 当副屏用时不自动锁屏
    [self.controller.server start];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    application.idleTimerDisabled = NO;
    __block UIBackgroundTaskIdentifier task = [application beginBackgroundTaskWithExpirationHandler:^{
        [application endBackgroundTask:task];
        task = UIBackgroundTaskInvalid;
    }];
    [self.controller.server stopWithFarewell:@"sleeping"];   // §6.1：设备锁屏/切走，Mac 会等待重连
    [application endBackgroundTask:task];
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [self.controller.server stopWithFarewell:@"closing"];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([ODAppDelegate class]));
    }
}
