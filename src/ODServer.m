#import "ODServer.h"
#import <CoreMedia/CoreMedia.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

static const uint16_t kPort = 9000;
static const uint16_t kCursorPort = 9001;              // §6.3：UDP 光标通道，惯例为 TCP 端口 + 1
static const NSInteger kProtocolVersion = 3;
static const uint32_t kJSONMaxLength = 32768;          // PROTOCOL.md §4
static const uint32_t kFrameMaxLength = 64u << 20;     // 防御：异常长度直接断开
static const double kPingIntervalSec = 2.0;            // §8.2
static const double kSilenceTimeoutMs = 5000.0;
// 标准画质：按 A7 的 H.264 Level 4.2 估算（每帧 ≤ 8704 宏块，吞吐 522240 MB/s），1600×1200。
// 原生画质：2048×1536，实测 A7 能硬解 60 fps，不再限制吞吐。
static const NSInteger kStandardLong = 1600, kStandardShort = 1200;
static const NSInteger kNativeLong = 2048, kNativeShort = 1536;
static const NSInteger kLevel42PixelsPerSecond = 522240 * 256;

static double ODNowMs(void) { return [[NSDate date] timeIntervalSince1970] * 1000.0; }

#pragma mark - Connection

@interface ODConn : NSObject
@property (nonatomic) int fd;
@property (nonatomic, strong) dispatch_source_t readSource;
@property (nonatomic, strong) dispatch_source_t writeSource;
@property (nonatomic) BOOL writeSourceResumed;
@property (nonatomic, strong) NSMutableData *inBuf;
@property (nonatomic) NSUInteger inOffset;
@property (nonatomic, strong) NSMutableData *outBuf;
@property (nonatomic) double createdMs;
@property (nonatomic) double lastRxMs;
@property (nonatomic) BOOL loopback;
@property (nonatomic) BOOL closed;
@end

@implementation ODConn
@end

#pragma mark - Server

@implementation ODServer {
    dispatch_queue_t _queue;
    int _listenFd;
    dispatch_source_t _listenSource;
    dispatch_source_t _timer;
    NSNetService *_netService;          // 仅主线程访问
    BOOL _running;                      // 仅主线程访问
    BOOL _usbOnlyMain;                  // 仅主线程访问（决定是否广播 Bonjour）

    ODConn *_active;
    ODConn *_pending;                   // 新来的连接先发 hello，收到数据才顶替旧连接（§6.4）

    NSInteger _panelWide, _panelHigh;
    double _scale;
    NSString *_installID;
    BOOL _nativeQuality;
    BOOL _usbOnly;                      // 队列上访问
    NSInteger _smoothDelayMs;

    // UDP 光标通道（§6.3）
    int _udpFd;
    dispatch_source_t _udpSource;
    struct sockaddr_storage _udpPeer;
    socklen_t _udpPeerLen;
    BOOL _udpAcked;

    // 解码状态
    NSData *_sps, *_pps;
    CMVideoFormatDescriptionRef _format;
    CMVideoDimensions _dims;
    BOOL _needsKeyframe;
    BOOL _videoStarted;
    double _lastKeyframeRequestMs;

    // 会话状态
    NSInteger _senderPV;
    long long _cursorMaxSeq;
    NSMutableArray<NSArray<NSNumber *> *> *_clockSamples;   // [rtt, offset]
    BOOL _offsetKnown;
    double _clockOffsetMs;
    NSUInteger _framesSinceStats;
    double _lastStatsMs;
    NSMutableArray<NSNumber *> *_latencies;   // 视频帧从 Mac 截屏到 iPad 收到的毫秒数
    NSUInteger _backlogSinceStats;            // 解码器忙、来不及接收新帧的次数
    NSUInteger _smoothedSinceStats;           // 经抖动缓冲按时显示的帧
    NSUInteger _lateSinceStats;               // 晚于计划显示时间才到的帧（直接显示）
    NSDictionary *_senderHealth;              // 发送端 ping 里带的 inp50/inp95（触摸到达 Mac 的延迟）、capFps
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("od.server", DISPATCH_QUEUE_SERIAL);
        _listenFd = -1;
        _udpFd = -1;
        _latencies = [NSMutableArray array];
        _scale = 2;
        _clockSamples = [NSMutableArray array];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        _installID = [defaults stringForKey:@"od.installID"];
        if (!_installID) {
            _installID = [[NSUUID UUID] UUIDString];
            [defaults setObject:_installID forKey:@"od.installID"];
        }
    }
    return self;
}

- (void)dealloc {
    if (_format) CFRelease(_format);
}

#pragma mark Lifecycle

- (void)start {
    NSAssert([NSThread isMainThread], @"start on main");
    if (_running) return;
    _running = YES;
    dispatch_async(_queue, ^{
        [self openListener];
        [self openCursorListener];
        [self startTimer];
    });
    if (!_usbOnlyMain) [self publishBonjour];
}

- (void)stopWithFarewell:(NSString *)type {
    NSAssert([NSThread isMainThread], @"stop on main");
    if (!_running) return;
    _running = NO;
    [_netService stop];
    _netService = nil;
    dispatch_sync(_queue, ^{
        // 先关 pending，否则关 active 时会把 pending 接管成新会话
        for (ODConn *c in @[self->_pending ?: [NSNull null], self->_active ?: [NSNull null]]) {
            if ([c isKindOfClass:[ODConn class]]) {
                [self sendObject:@{@"type": type} on:c];
                [self closeConn:c notify:NO];
            }
        }
        self->_active = nil;
        self->_pending = nil;
        if (self->_listenSource) { dispatch_source_cancel(self->_listenSource); self->_listenSource = nil; }
        if (self->_timer) { dispatch_source_cancel(self->_timer); self->_timer = nil; }
        if (self->_udpSource) { dispatch_source_cancel(self->_udpSource); self->_udpSource = nil; self->_udpFd = -1; }
    });
    [self.delegate serverDidDisconnect];
}

- (void)setPanelPixelsWide:(NSInteger)wide high:(NSInteger)high scale:(double)scale {
    dispatch_async(_queue, ^{
        if (wide == self->_panelWide && high == self->_panelHigh && scale == self->_scale) return;
        self->_panelWide = wide;
        self->_panelHigh = high;
        self->_scale = scale;
        if (self->_active) [self sendObject:[self helloMessageFor:self->_active] on:self->_active];   // §6.1 旋转时重发
    });
}

- (void)setSmoothingDelayMs:(NSInteger)delayMs {
    dispatch_async(_queue, ^{
        if (delayMs == self->_smoothDelayMs) return;
        self->_smoothDelayMs = MAX(0, delayMs);
        [self.displayLayer flush];        // 丢掉按旧延迟排好的帧，下一帧起按新延迟
        if (self->_active) { self->_needsKeyframe = YES; [self requestKeyframe]; }
    });
}

- (void)setNativeQuality:(BOOL)nativeQuality {
    dispatch_async(_queue, ^{
        if (nativeQuality == self->_nativeQuality) return;
        self->_nativeQuality = nativeQuality;
        if (self->_active) [self sendObject:[self helloMessageFor:self->_active] on:self->_active];   // 发送端按新上限重建串流
    });
}

#pragma mark Bonjour

- (void)setUsbOnly:(BOOL)usbOnly {
    NSAssert([NSThread isMainThread], @"setUsbOnly on main");
    if (usbOnly != _usbOnlyMain) {
        _usbOnlyMain = usbOnly;
        if (_running && usbOnly) { [_netService stop]; _netService = nil; }
        else if (_running && !_netService) [self publishBonjour];
    }
    dispatch_async(_queue, ^{
        self->_usbOnly = usbOnly;
        if (!usbOnly) return;
        // 断开已有的 WiFi 会话
        if (self->_pending && !self->_pending.loopback) [self closeConn:self->_pending notify:NO];
        if (self->_active && !self->_active.loopback) [self closeConn:self->_active notify:YES];
    });
}

- (void)publishBonjour {
    NSString *name = [UIDevice currentDevice].name ?: @"iPad";
    _netService = [[NSNetService alloc] initWithDomain:@"" type:@"_opensidecar._tcp." name:name port:kPort];
    NSDictionary *txt = @{
        @"id": [_installID dataUsingEncoding:NSUTF8StringEncoding],
        @"pv": [[NSString stringWithFormat:@"%ld", (long)kProtocolVersion] dataUsingEncoding:NSUTF8StringEncoding],
    };
    [_netService setTXTRecordData:[NSNetService dataFromTXTRecordDictionary:txt]];
    [_netService publish];
}

#pragma mark Listener

- (void)openListener {
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) { [self notice:[NSString stringWithFormat:@"socket 失败：%s", strerror(errno)]]; return; }
    int on = 1, off = 0;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof off);   // 同时接 IPv4
    struct sockaddr_in6 addr = {0};
    addr.sin6_len = sizeof addr;
    addr.sin6_family = AF_INET6;
    addr.sin6_port = htons(kPort);
    addr.sin6_addr = in6addr_any;
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(fd, 8) != 0) {
        [self notice:[NSString stringWithFormat:@"无法监听 %d 端口：%s", kPort, strerror(errno)]];
        close(fd);
        return;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    _listenFd = fd;
    _listenSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_listenSource, ^{ [weakSelf acceptPending]; });
    dispatch_source_set_cancel_handler(_listenSource, ^{ close(fd); });
    dispatch_resume(_listenSource);
}

- (void)openCursorListener {
    int fd = socket(AF_INET6, SOCK_DGRAM, 0);
    if (fd < 0) return;
    int off = 0;
    setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof off);
    struct sockaddr_in6 addr = {0};
    addr.sin6_len = sizeof addr;
    addr.sin6_family = AF_INET6;
    addr.sin6_port = htons(kCursorPort);
    addr.sin6_addr = in6addr_any;
    if (bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(fd);   // 没绑上就不在 hello 里提供 cursorPort，光标继续走 TCP
        return;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    _udpFd = fd;
    _udpSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_udpSource, ^{ [weakSelf readCursorDatagrams]; });
    dispatch_source_set_cancel_handler(_udpSource, ^{ close(fd); });
    dispatch_resume(_udpSource);
}

- (void)readCursorDatagrams {
    uint8_t buf[2048];
    for (;;) {
        struct sockaddr_storage from;
        socklen_t fromLen = sizeof from;
        ssize_t n = recvfrom(_udpFd, buf, sizeof buf, 0, (struct sockaddr *)&from, &fromLen);
        if (n <= 0) return;
        if (!_active || _usbOnly || buf[0] != '{') continue;

        // 新的 UDP 流：重置序号，只认最新的流（§6.3）
        if (fromLen != _udpPeerLen || memcmp(&from, &_udpPeer, fromLen) != 0) {
            memcpy(&_udpPeer, &from, fromLen);
            _udpPeerLen = fromLen;
            _udpAcked = NO;
            _cursorMaxSeq = 0;
        }
        NSData *json = [NSData dataWithBytesNoCopy:buf length:(NSUInteger)n freeWhenDone:NO];
        NSDictionary *msg = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        if (![msg isKindOfClass:[NSDictionary class]] || ![msg[@"type"] isEqual:@"cursor"]) continue;
        if ([self applyCursor:msg] && !_udpAcked) {
            _udpAcked = YES;
            [self sendObject:@{@"type": @"cursorAck"} on:_active];   // 告诉发送端 UDP 通了，可以停止 TCP 镜像
        }
    }
}

- (void)acceptPending {
    for (;;) {
        struct sockaddr_storage ss;
        socklen_t len = sizeof ss;
        int fd = accept(_listenFd, (struct sockaddr *)&ss, &len);
        if (fd < 0) return;
        if (_usbOnly && ![self isLoopback:&ss]) { close(fd); continue; }   // 仅 USB：WiFi 连接直接拒绝

        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        int on = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);    // §1：关闭 Nagle
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);

        ODConn *c = [ODConn new];
        c.fd = fd;
        c.inBuf = [NSMutableData dataWithCapacity:1 << 20];
        c.outBuf = [NSMutableData data];
        c.createdMs = c.lastRxMs = ODNowMs();
        c.loopback = [self isLoopback:&ss];
        [self attachSources:c];

        if (!_active) {
            [self adopt:c];
        } else {
            if (_pending) [self closeConn:_pending notify:NO];
            _pending = c;
            [self sendObject:[self helloMessageFor:c] on:c];
        }
    }
}

- (BOOL)isLoopback:(struct sockaddr_storage *)ss {
    if (ss->ss_family == AF_INET) {
        return (ntohl(((struct sockaddr_in *)ss)->sin_addr.s_addr) >> 24) == 127;
    }
    if (ss->ss_family == AF_INET6) {
        struct in6_addr *a = &((struct sockaddr_in6 *)ss)->sin6_addr;
        if (IN6_IS_ADDR_LOOPBACK(a)) return YES;
        if (IN6_IS_ADDR_V4MAPPED(a)) return a->s6_addr[12] == 127;
    }
    return NO;
}

- (void)attachSources:(ODConn *)c {
    __weak typeof(self) weakSelf = self;
    __weak ODConn *weakConn = c;
    int fd = c.fd;
    __block int remaining = 2;   // 两个 source 都取消后才关闭 fd
    dispatch_block_t closeWhenDone = ^{ if (--remaining == 0) close(fd); };

    c.readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);
    dispatch_source_set_event_handler(c.readSource, ^{
        ODConn *conn = weakConn;
        if (conn) [weakSelf readFrom:conn];
    });
    dispatch_source_set_cancel_handler(c.readSource, closeWhenDone);

    c.writeSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_WRITE, (uintptr_t)fd, 0, _queue);
    dispatch_source_set_event_handler(c.writeSource, ^{
        ODConn *conn = weakConn;
        if (conn) [weakSelf flush:conn];
    });
    dispatch_source_set_cancel_handler(c.writeSource, closeWhenDone);

    dispatch_resume(c.readSource);   // 写 source 保持挂起，写满时才启用
}

- (void)adopt:(ODConn *)c {
    BOOL helloAlreadySent = (c == _pending);
    _pending = nil;
    _active = c;

    _senderPV = 1;                    // 没收到 welcome 前按 pv 1 处理（§6.2）
    _cursorMaxSeq = 0;
    _udpPeerLen = 0;
    _udpAcked = NO;
    _senderHealth = nil;
    [_latencies removeAllObjects];
    _backlogSinceStats = 0;
    _offsetKnown = NO;
    [_clockSamples removeAllObjects];
    _needsKeyframe = YES;
    _videoStarted = NO;
    _framesSinceStats = 0;
    _lastStatsMs = ODNowMs();
    [self.displayLayer flushAndRemoveImage];

    if (!helloAlreadySent) [self sendObject:[self helloMessageFor:c] on:c];
    NSString *transport = c.loopback ? @"USB" : @"WiFi";
    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate serverDidConnect:transport]; });
}

- (void)closeConn:(ODConn *)c notify:(BOOL)notify {
    if (c.closed) return;
    c.closed = YES;
    dispatch_source_cancel(c.readSource);
    if (!c.writeSourceResumed) dispatch_resume(c.writeSource);   // 挂起的 source 必须先恢复才能触发取消回调
    dispatch_source_cancel(c.writeSource);

    if (c == _pending) {
        _pending = nil;
    } else if (c == _active) {
        _active = nil;
        if (_pending) {
            [self adopt:_pending];
        } else if (notify) {
            [self.displayLayer flushAndRemoveImage];
            dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate serverDidDisconnect]; });
        }
    }
}

#pragma mark Reading

- (void)readFrom:(ODConn *)c {
    uint8_t buf[64 * 1024];
    BOOL gotBytes = NO;
    for (;;) {
        ssize_t n = read(c.fd, buf, sizeof buf);
        if (n > 0) { [c.inBuf appendBytes:buf length:(NSUInteger)n]; gotBytes = YES; continue; }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && errno == EAGAIN) break;
        [self closeConn:c notify:YES];   // n == 0：对端关闭；其他错误同样断开
        return;
    }
    if (!gotBytes) return;
    c.lastRxMs = ODNowMs();

    if (c == _pending) {
        // 新连接已经用数据证明自己是真正的发送端，顶替旧会话
        if (_active) {
            ODConn *old = _active;
            _active = nil;
            [self closeConn:old notify:NO];
        }
        [self adopt:c];
    }
    if (c != _active) return;
    [self parseFrames:c];
}

- (void)parseFrames:(ODConn *)c {
    NSMutableData *data = c.inBuf;
    const uint8_t *p = data.bytes;
    NSUInteger length = data.length;
    NSUInteger off = c.inOffset;

    while (length - off >= 4) {
        uint32_t n = ((uint32_t)p[off] << 24) | ((uint32_t)p[off + 1] << 16) | ((uint32_t)p[off + 2] << 8) | p[off + 3];
        if (n == 0 || n > kFrameMaxLength) { [self closeConn:c notify:YES]; return; }
        if (length - off - 4 < n) break;
        [self handlePayload:p + off + 4 length:n];
        if (c.closed || c != _active) return;
        off += 4 + n;
    }

    if (off == length) {
        data.length = 0;
        off = 0;
    } else if (off > (1u << 20)) {
        memmove(data.mutableBytes, p + off, length - off);
        data.length = length - off;
        off = 0;
    }
    c.inOffset = off;
}

- (void)handlePayload:(const uint8_t *)p length:(uint32_t)n {
    // §4 的启发式分流：<32768 字节、以 { 开头、不含 NUL 的是 JSON，其余是视频
    if (n < kJSONMaxLength && p[0] == '{' && memchr(p, 0, n) == NULL) {
        NSData *json = [NSData dataWithBytesNoCopy:(void *)p length:n freeWhenDone:NO];
        id obj = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        if ([obj isKindOfClass:[NSDictionary class]] && [obj[@"type"] isKindOfClass:[NSString class]]) {
            [self handleControl:obj];
        }
        return;
    }
    [self handleVideo:p length:n];
}

#pragma mark Control messages

static double ODNum(id v, double fallback) {
    return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : fallback;
}

- (void)handleControl:(NSDictionary *)msg {
    NSString *type = msg[@"type"];

    if ([type isEqualToString:@"pong"]) {
        double t1 = ODNum(msg[@"t"], NAN), mt = ODNum(msg[@"mt"], NAN);
        double t2 = ODNowMs(), rtt = t2 - t1;
        if (isnan(t1) || isnan(mt) || rtt < 0 || rtt >= 2000) return;
        [_clockSamples addObject:@[@(rtt), @(mt - (t1 + t2) / 2)]];
        if (_clockSamples.count > 15) [_clockSamples removeObjectAtIndex:0];
        NSArray *best = _clockSamples.firstObject;
        for (NSArray *s in _clockSamples) if ([s[0] doubleValue] < [best[0] doubleValue]) best = s;
        _clockOffsetMs = [best[1] doubleValue];
        _offsetKnown = YES;

    } else if ([type isEqualToString:@"ping"]) {
        _senderHealth = msg;   // §6.2：发送端的心跳，附带它那边的健康指标

    } else if ([type isEqualToString:@"welcome"]) {
        _senderPV = (NSInteger)ODNum(msg[@"pv"], 1);

    } else if ([type isEqualToString:@"cursor"]) {
        [self applyCursor:msg];

    } else if ([type isEqualToString:@"cursorImg"]) {
        NSString *b64 = msg[@"png"];
        if (![b64 isKindOfClass:[NSString class]]) return;
        NSData *png = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        UIImage *image = png ? [UIImage imageWithData:png] : nil;
        if (!image) return;
        double nw = ODNum(msg[@"nw"], 0.02), nh = ODNum(msg[@"nh"], 0.03);
        double ax = ODNum(msg[@"ax"], 0), ay = ODNum(msg[@"ay"], 0);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate serverCursorImage:image nw:nw nh:nh ax:ax ay:ay];
        });

    } else if ([type isEqualToString:@"streamConfig"]) {
        NSString *codec = msg[@"codec"];
        if ([codec isKindOfClass:[NSString class]] && ![codec isEqualToString:@"h264"]) {
            [self notice:[NSString stringWithFormat:@"Mac 选择了不支持的编码：%@", codec]];
        }

    } else if ([type isEqualToString:@"updateRequired"]) {
        NSString *text = [msg[@"message"] isKindOfClass:[NSString class]] ? msg[@"message"] : @"Mac 端要求更新接收端";
        [self notice:text];
    }
    // ping 及其他未知类型：按 §6 忽略
}

/// TCP 和 UDP 共用：按序号去重后更新光标，返回是否采用了这条消息
- (BOOL)applyCursor:(NSDictionary *)msg {
    id seq = msg[@"s"];
    if ([seq isKindOfClass:[NSNumber class]]) {
        long long s = [seq longLongValue];
        if (s <= _cursorMaxSeq) return NO;    // §6.3：不比已见序号新的丢弃
        _cursorMaxSeq = s;
    }
    BOOL visible = ODNum(msg[@"v"], 1) != 0;
    double x = ODNum(msg[@"x"], NAN), y = ODNum(msg[@"y"], NAN);
    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate serverCursorX:x y:y visible:visible]; });
    return YES;
}

- (NSDictionary *)helloMessageFor:(ODConn *)conn {
    NSInteger w = _panelWide > 0 ? _panelWide : 2048;
    NSInteger h = _panelHigh > 0 ? _panelHigh : 1536;
    BOOL landscape = w >= h;
    // WiFi 带宽有限（实测约 25 Mbps），码率又由 Mac 固定，所以 WiFi 下总用标准尺寸：同样码率像素越少越清楚
    BOOL native = _nativeQuality && conn.loopback;
    NSInteger longSide = native ? kNativeLong : kStandardLong;
    NSInteger shortSide = native ? kNativeShort : kStandardShort;
    NSInteger maxW = landscape ? longSide : shortSide;
    NSInteger maxH = landscape ? shortSide : longSide;
    NSMutableDictionary *h264 = [@{@"codec": @"h264", @"maxFrameRate": @60,
                                   @"maxWidth": @(maxW), @"maxHeight": @(maxH)} mutableCopy];
    if (!native) h264[@"maxPixelsPerSecond"] = @(kLevel42PixelsPerSecond);
    NSMutableDictionary *hello = [@{
        @"type": @"hello",
        @"pixelsWide": @(w),
        @"pixelsHigh": @(h),
        @"scale": @(_scale),
        @"device": @"iPad",
        @"id": _installID,
        @"pv": @(kProtocolVersion),
        @"displayMaxFrameRate": @60,
        @"panel": @{@"pixelsWide": @(w), @"pixelsHigh": @(h), @"scale": @(_scale)},
        @"videoCaps": @[h264],
        @"maxEncodeWide": @(maxW),
        @"maxEncodeHigh": @(maxH),
    } mutableCopy];
    if (_udpFd >= 0 && !_usbOnly) hello[@"cursorPort"] = @(kCursorPort);   // 仅在 UDP 已绑定时提供；USB 下发送端会忽略
    return hello;
}

#pragma mark Writing

- (void)sendObject:(NSDictionary *)obj on:(ODConn *)c {
    if (!c || c.closed) return;
    NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (json.length == 0 || json.length >= (1u << 20)) return;
    uint32_t be = htonl((uint32_t)json.length);
    [c.outBuf appendBytes:&be length:4];
    [c.outBuf appendData:json];
    [self flush:c];
}

- (void)flush:(ODConn *)c {
    while (c.outBuf.length > 0 && !c.closed) {
        ssize_t n = write(c.fd, c.outBuf.bytes, c.outBuf.length);
        if (n > 0) {
            [c.outBuf replaceBytesInRange:NSMakeRange(0, (NSUInteger)n) withBytes:NULL length:0];
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else if (n < 0 && errno == EAGAIN) {
            if (!c.writeSourceResumed) { c.writeSourceResumed = YES; dispatch_resume(c.writeSource); }
            return;
        } else {
            [self closeConn:c notify:YES];
            return;
        }
    }
    if (c.writeSourceResumed && !c.closed) { c.writeSourceResumed = NO; dispatch_suspend(c.writeSource); }
}

- (void)sendInput:(NSMutableDictionary *)msg {
    dispatch_async(_queue, ^{
        if (!self->_active) return;
        if (self->_offsetKnown) msg[@"t"] = @(ODNowMs() + self->_clockOffsetMs);   // §6.1：发送端时钟
        [self sendObject:msg on:self->_active];
    });
}

- (void)sendTouchPhase:(NSString *)phase x:(double)x y:(double)y {
    [self sendInput:[@{@"type": @"touch", @"phase": phase, @"x": @(x), @"y": @(y)} mutableCopy]];
}

- (void)sendScrollDx:(double)dx dy:(double)dy {
    dispatch_async(_queue, ^{
        if (self->_active) [self sendObject:@{@"type": @"scroll", @"dx": @(dx), @"dy": @(dy)} on:self->_active];
    });
}

- (void)requestKeyframe {
    double now = ODNowMs();
    if (now - _lastKeyframeRequestMs < 500) return;
    _lastKeyframeRequestMs = now;
    [self sendObject:@{@"type": @"kf"} on:_active];
}

#pragma mark Timer

- (void)startTimer {
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(kPingIntervalSec * NSEC_PER_SEC), NSEC_PER_SEC / 10);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
    dispatch_resume(_timer);
}

- (void)tick {
    double now = ODNowMs();
    if (_pending && now - _pending.createdMs > kSilenceTimeoutMs) [self closeConn:_pending notify:NO];
    if (!_active) return;
    if (now - _active.lastRxMs > kSilenceTimeoutMs) {   // §8.2：超过 5 秒没数据视为断线
        [self closeConn:_active notify:YES];
        return;
    }
    [self sendObject:@{@"type": @"ping", @"t": @(now)} on:_active];

    if (now - _lastStatsMs >= 5000) [self sendStats:now];
}

- (void)sendStats:(double)now {
    double fps = _framesSinceStats * 1000.0 / (now - _lastStatsMs);
    NSArray<NSNumber *> *sorted = [_latencies sortedArrayUsingSelector:@selector(compare:)];
    NSMutableDictionary *stats = [@{@"type": @"stats",
                                    @"transport": _active.loopback ? @"usb" : @"wifi",
                                    @"fps": @(round(fps * 10) / 10),
                                    @"backlog": @(_backlogSinceStats),
                                    @"res": [NSString stringWithFormat:@"%dx%d", _dims.width, _dims.height],
                                    @"quality": (_nativeQuality && _active.loopback) ? @"native" : @"standard",
                                    @"cursorUdp": @(_udpAcked),
                                    @"jb": @(_active.loopback ? 0 : _smoothDelayMs),
                                    @"smoothed": @(_smoothedSinceStats),
                                    @"late": @(_lateSinceStats),
                                    @"offsetKnown": @(_offsetKnown),
                                    @"client": @"ios12-port"} mutableCopy];
    for (NSString *key in @[@"inp50", @"inp95", @"capFps"]) {
        if ([_senderHealth[key] isKindOfClass:[NSNumber class]]) stats[[@"mac_" stringByAppendingString:key]] = _senderHealth[key];
    }
    if (sorted.count) {
        stats[@"e2e50"] = @(lround(sorted[sorted.count / 2].doubleValue));
        stats[@"e2e95"] = @(lround(sorted[MIN(sorted.count - 1, sorted.count * 95 / 100)].doubleValue));
    }
    [self sendObject:stats on:_active];

    NSMutableString *text = [NSMutableString stringWithFormat:@"%@ · %@ · %.0f fps",
                             _active.loopback ? @"USB" : @"WiFi", stats[@"res"], fps];
    if (stats[@"e2e50"]) [text appendFormat:@" · 延迟 %@/%@ ms", stats[@"e2e50"], stats[@"e2e95"]];
    if (stats[@"mac_inp50"]) [text appendFormat:@" · 触摸 %@/%@ ms", stats[@"mac_inp50"], stats[@"mac_inp95"]];
    if (stats[@"mac_capFps"]) [text appendFormat:@" · Mac 截屏 %@ fps", stats[@"mac_capFps"]];
    if (_backlogSinceStats) [text appendFormat:@" · 解码积压 %lu", (unsigned long)_backlogSinceStats];
    if (_udpAcked) [text appendString:@" · 光标 UDP"];
    if (!_active.loopback && _smoothDelayMs > 0) {
        [text appendFormat:@" · 平滑 %ldms（迟到 %lu）", (long)_smoothDelayMs, (unsigned long)_lateSinceStats];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate serverStatsText:text]; });

    _framesSinceStats = 0;
    _backlogSinceStats = 0;
    _smoothedSinceStats = 0;
    _lateSinceStats = 0;
    [_latencies removeAllObjects];
    _lastStatsMs = now;
}

#pragma mark Video

- (void)handleVideo:(const uint8_t *)p length:(size_t)n {
    // 找出所有 4 字节起始码（§5.1：只会有 4 字节起始码），起始码之前是遥测 JSON，跳过
    enum { kMaxNalus = 128 };
    size_t starts[kMaxNalus], ends[kMaxNalus];
    int count = 0;
    size_t i = 0;
    while (i + 3 < n) {
        if (p[i + 2] != 0) { i += 3; continue; }
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 3] == 1) {
            if (count > 0) ends[count - 1] = i;
            if (count == kMaxNalus) break;
            starts[count++] = i + 4;
            i += 4;
            continue;
        }
        i++;
    }
    if (count == 0) return;
    ends[count - 1] = n;
    double captureMs = NAN;   // 本机时钟下的截屏时间
    if (starts[0] > 4 && _offsetKnown) captureMs = [self captureTimeFromPrefix:p length:starts[0] - 4];

    const uint8_t *sps = NULL, *pps = NULL;
    size_t spsLen = 0, ppsLen = 0, payloadBytes = 0;
    BOOL isIDR = NO;
    for (int k = 0; k < count; k++) {
        if (ends[k] <= starts[k]) continue;
        uint8_t type = p[starts[k]] & 0x1F;
        size_t len = ends[k] - starts[k];
        if (type == 7) { sps = p + starts[k]; spsLen = len; }
        else if (type == 8) { pps = p + starts[k]; ppsLen = len; }
        else if (type >= 1 && type <= 5) { payloadBytes += 4 + len; if (type == 5) isIDR = YES; }
    }

    if (sps && pps) [self updateFormatWithSPS:sps length:spsLen pps:pps length:ppsLen];

    if (!_format || (_needsKeyframe && !isIDR)) { [self requestKeyframe]; return; }
    if (payloadBytes == 0) return;

    AVSampleBufferDisplayLayer *layer = self.displayLayer;
    if (!layer) return;
    if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [layer flush];
        _needsKeyframe = YES;
        [self requestKeyframe];
        return;
    }
    if (isIDR) _needsKeyframe = NO;

    // Annex B → AVCC（4 字节长度前缀）
    uint8_t *mem = malloc(payloadBytes);
    if (!mem) return;
    size_t w = 0;
    for (int k = 0; k < count; k++) {
        if (ends[k] <= starts[k]) continue;
        uint8_t type = p[starts[k]] & 0x1F;
        if (type < 1 || type > 5) continue;
        uint32_t len = (uint32_t)(ends[k] - starts[k]);
        uint32_t be = htonl(len);
        memcpy(mem + w, &be, 4);
        memcpy(mem + w + 4, p + starts[k], len);
        w += 4 + len;
    }

    CMBlockBufferRef block = NULL;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, mem, payloadBytes, kCFAllocatorMalloc,
                                           NULL, 0, payloadBytes, 0, &block) != kCMBlockBufferNoErr) {
        free(mem);
        return;
    }
    CMSampleBufferRef sample = NULL;
    size_t sampleSize = payloadBytes;
    OSStatus st = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _format, 1, 0, NULL, 1, &sampleSize, &sample);
    CFRelease(block);
    if (st != noErr || !sample) return;

    // WiFi 抖动缓冲：按截屏节奏 + 固定延迟显示，把一团一团到达的帧摊平；来晚了就立即显示
    BOOL scheduled = NO;
    if (_smoothDelayMs > 0 && !_active.loopback && !isnan(captureMs)) {
        double now = ODNowMs();
        double dueMs = captureMs + _smoothDelayMs;
        if (dueMs > now + 2) {
            [self ensureTimebase:layer];
            CMTime pts = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()),
                                   CMTimeMakeWithSeconds((dueMs - now) / 1000.0, 1000000));
            CMSampleBufferSetOutputPresentationTimeStamp(sample, pts);
            scheduled = YES;
            _smoothedSinceStats++;
        } else {
            _lateSinceStats++;
        }
    }

    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, YES);
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        // §5.1：协议本身不带显示时间戳，未排期的帧到即显示
        if (!scheduled) CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        if (!isIDR) CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, kCFBooleanTrue);
    }
    if (!layer.isReadyForMoreMediaData) _backlogSinceStats++;
    [layer enqueueSampleBuffer:sample];
    CFRelease(sample);

    _framesSinceStats++;
    if (!_videoStarted) {
        _videoStarted = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate serverDidStartVideo]; });
    }
}

/// 起始码前的遥测前缀 {"cap":..,"snd":..}（§5.1），cap 是发送端时钟的截屏时间
/// 同时记录端到端延迟，返回换算到本机时钟的截屏时间（失败为 NAN）
- (double)captureTimeFromPrefix:(const uint8_t *)p length:(size_t)n {
    NSData *json = [NSData dataWithBytesNoCopy:(void *)p length:n freeWhenDone:NO];
    NSDictionary *t = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (![t isKindOfClass:[NSDictionary class]]) return NAN;
    double cap = ODNum(t[@"cap"], NAN);
    if (isnan(cap)) return NAN;
    double captureMs = cap - _clockOffsetMs;   // offset = 发送端时钟 − 本机时钟
    double latency = ODNowMs() - captureMs;
    if (latency >= 0 && latency < 10000 && _latencies.count < 2000) [_latencies addObject:@(latency)];
    return captureMs;
}

/// 让显示层跟随系统主机时钟，这样可以给帧设定未来的显示时间
- (void)ensureTimebase:(AVSampleBufferDisplayLayer *)layer {
    if (layer.controlTimebase) return;
    CMTimebaseRef timebase = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // iOS 12 没有 CMTimebaseCreateWithSourceClock（iOS 15+）
    if (CMTimebaseCreateWithMasterClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &timebase) != noErr) return;
#pragma clang diagnostic pop
    CMTimebaseSetTime(timebase, CMClockGetTime(CMClockGetHostTimeClock()));
    CMTimebaseSetRate(timebase, 1.0);
    layer.controlTimebase = timebase;
    CFRelease(timebase);
}

- (void)updateFormatWithSPS:(const uint8_t *)sps length:(size_t)spsLen pps:(const uint8_t *)pps length:(size_t)ppsLen {
    NSData *newSPS = [NSData dataWithBytes:sps length:spsLen];
    NSData *newPPS = [NSData dataWithBytes:pps length:ppsLen];
    if (_format && [newSPS isEqualToData:_sps] && [newPPS isEqualToData:_pps]) return;

    const uint8_t *sets[2] = {sps, pps};
    const size_t sizes[2] = {spsLen, ppsLen};
    CMVideoFormatDescriptionRef format = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, sets, sizes, 4, &format);
    if (st != noErr || !format) {
        [self notice:[NSString stringWithFormat:@"无法解析 SPS/PPS（%d）", (int)st]];
        return;
    }
    // §5.2：参数集变化（旋转、换画质）时重建解码器并丢掉旧格式的帧
    if (_format) CFRelease(_format);
    _format = format;
    _sps = newSPS;
    _pps = newPPS;
    _needsKeyframe = YES;
    [self.displayLayer flush];

    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(format);
    if (dims.width != _dims.width || dims.height != _dims.height) {
        _dims = dims;
        CGSize size = CGSizeMake(dims.width, dims.height);
        dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate serverVideoSizeChanged:size]; });
    }
}

#pragma mark Helpers

- (void)notice:(NSString *)text {
    NSLog(@"[OpenDisplay] %@", text);
    dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate serverNotice:text]; });
}

+ (NSString *)wifiAddress {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return nil;
    NSString *result = nil;
    for (struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        if (!(ifa->ifa_flags & IFF_UP) || strcmp(ifa->ifa_name, "en0") != 0) continue;
        char host[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((struct sockaddr_in *)ifa->ifa_addr)->sin_addr, host, sizeof host);
        result = [NSString stringWithUTF8String:host];
        break;
    }
    freeifaddrs(list);
    return result;
}

@end
