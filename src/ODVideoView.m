#import "ODVideoView.h"

@implementation ODVideoView {
    CALayer *_cursorLayer;
    UILabel *_statusLabel;
    UILabel *_statsLabel;

    // 光标状态（归一化坐标）
    double _cursorX, _cursorY, _cursorNW, _cursorNH;
    BOOL _cursorVisible;

    // 触摸状态：单指 = 鼠标拖动/点击，双指 = 滚动
    UITouch *_primary;
    BOOL _scrolling;
    BOOL _waitForAllUp;
    CGPoint _lastCentroid;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor blackColor];
        self.multipleTouchEnabled = YES;

        _displayLayer = [AVSampleBufferDisplayLayer layer];
        _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        _displayLayer.backgroundColor = [UIColor blackColor].CGColor;
        [self.layer addSublayer:_displayLayer];

        _cursorLayer = [CALayer layer];
        _cursorLayer.hidden = YES;
        _cursorLayer.contentsGravity = kCAGravityResize;
        _cursorLayer.actions = @{@"position": [NSNull null], @"bounds": [NSNull null],
                                 @"hidden": [NSNull null], @"contents": [NSNull null],
                                 @"anchorPoint": [NSNull null]};
        [self.layer addSublayer:_cursorLayer];
        [self resetCursor];

        _statusLabel = [[UILabel alloc] init];
        _statusLabel.numberOfLines = 0;
        _statusLabel.textAlignment = NSTextAlignmentCenter;
        _statusLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
        _statusLabel.font = [UIFont systemFontOfSize:20];
        [self addSubview:_statusLabel];

        _statsLabel = [[UILabel alloc] init];
        _statsLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
        _statsLabel.textColor = [UIColor whiteColor];
        _statsLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        _statsLabel.layer.cornerRadius = 6;
        _statsLabel.layer.masksToBounds = YES;
        _statsLabel.userInteractionEnabled = NO;
        _statsLabel.hidden = YES;
        [self addSubview:_statsLabel];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _displayLayer.frame = self.bounds;
    [self layoutCursor];
    [CATransaction commit];
    CGFloat inset = 40;
    _statusLabel.frame = CGRectInset(self.bounds, inset, inset);
    CGSize fit = [_statsLabel sizeThatFits:CGSizeMake(self.bounds.size.width - 24, 20)];
    _statsLabel.frame = CGRectMake(12, 12, fit.width + 16, fit.height + 8);
}

- (void)setVideoSize:(CGSize)videoSize {
    _videoSize = videoSize;
    [self setNeedsLayout];
}

/// 画面在视图中的实际区域（按比例适配后的矩形）
- (CGRect)videoRect {
    if (_videoSize.width <= 0 || _videoSize.height <= 0) return self.bounds;
    return AVMakeRectWithAspectRatioInsideRect(_videoSize, self.bounds);
}

#pragma mark Status

- (void)showStatus:(NSString *)text {
    _statusLabel.text = text;
    _statusLabel.hidden = (text.length == 0);
}

- (void)showStats:(NSString *)text {
    _statsLabel.text = text.length ? [NSString stringWithFormat:@" %@", text] : nil;
    _statsLabel.hidden = (text.length == 0);
    [self setNeedsLayout];
}

#pragma mark Cursor

- (void)resetCursor {
    // 收到 cursorImg 之前用一个白色圆点代替
    CGSize size = CGSizeMake(24, 24);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextSetStrokeColorWithColor(ctx, [UIColor blackColor].CGColor);
    CGContextSetLineWidth(ctx, 2);
    CGRect dot = CGRectInset(CGRectMake(0, 0, size.width, size.height), 6, 6);
    CGContextFillEllipseInRect(ctx, dot);
    CGContextStrokeEllipseInRect(ctx, dot);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    [self setCursorImage:image nw:0 nh:0 ax:0.5 ay:0.5];
    _cursorVisible = NO;
    _cursorLayer.hidden = YES;
}

- (void)setCursorImage:(UIImage *)image nw:(double)nw nh:(double)nh ax:(double)ax ay:(double)ay {
    _cursorLayer.contents = (__bridge id)image.CGImage;
    _cursorLayer.anchorPoint = CGPointMake(ax, ay);
    _cursorNW = nw;
    _cursorNH = nh;
    if (nw <= 0 || nh <= 0) _cursorLayer.bounds = CGRectMake(0, 0, image.size.width, image.size.height);
    [self layoutCursor];
}

- (void)setCursorX:(double)x y:(double)y visible:(BOOL)visible {
    if (!isnan(x)) _cursorX = x;
    if (!isnan(y)) _cursorY = y;
    _cursorVisible = visible;
    [self layoutCursor];
}

- (void)layoutCursor {
    CGRect r = [self videoRect];
    if (_cursorNW > 0 && _cursorNH > 0) {
        _cursorLayer.bounds = CGRectMake(0, 0, _cursorNW * r.size.width, _cursorNH * r.size.height);
    }
    _cursorLayer.position = CGPointMake(r.origin.x + _cursorX * r.size.width, r.origin.y + _cursorY * r.size.height);
    _cursorLayer.hidden = !_cursorVisible;
}

#pragma mark Touch

- (CGPoint)normalized:(CGPoint)p {
    CGRect r = [self videoRect];
    double x = (p.x - r.origin.x) / r.size.width;
    double y = (p.y - r.origin.y) / r.size.height;
    return CGPointMake(fmin(fmax(x, 0), 1), fmin(fmax(y, 0), 1));
}

- (NSArray<UITouch *> *)liveTouches:(UIEvent *)event {
    NSMutableArray *live = [NSMutableArray array];
    for (UITouch *t in [event touchesForView:self]) {
        if (t.phase != UITouchPhaseEnded && t.phase != UITouchPhaseCancelled) [live addObject:t];
    }
    return live;
}

- (CGPoint)centroid:(NSArray<UITouch *> *)touches {
    CGPoint sum = CGPointZero;
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        sum.x += p.x;
        sum.y += p.y;
    }
    return CGPointMake(sum.x / touches.count, sum.y / touches.count);
}

- (void)sendTouch:(UITouch *)t phase:(NSString *)phase {
    CGPoint n = [self normalized:[t locationInView:self]];
    [self.inputDelegate videoViewTouchPhase:phase x:n.x y:n.y];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    NSArray *live = [self liveTouches:event];
    if (live.count >= 2) {
        // 第二根手指落下：结束单指拖动，切换成滚动
        if (_primary) { [self sendTouch:_primary phase:@"ended"]; _primary = nil; }
        _scrolling = YES;
        _lastCentroid = [self centroid:live];
    } else if (live.count == 1 && !_primary && !_scrolling && !_waitForAllUp) {
        _primary = touches.anyObject;
        [self sendTouch:_primary phase:@"began"];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    NSArray *live = [self liveTouches:event];
    if (_scrolling && live.count >= 2) {
        CGPoint c = [self centroid:live];
        CGRect r = [self videoRect];
        double pixelsPerPoint = _videoSize.width > 0 ? _videoSize.width / r.size.width : 2.0;
        double dx = (c.x - _lastCentroid.x) * pixelsPerPoint;
        double dy = (c.y - _lastCentroid.y) * pixelsPerPoint;
        _lastCentroid = c;
        if (dx != 0 || dy != 0) [self.inputDelegate videoViewScrollDx:dx dy:dy];
    } else if (_primary && [touches containsObject:_primary]) {
        [self sendTouch:_primary phase:@"moved"];
    }
}

- (void)finishTouches:(NSSet<UITouch *> *)touches event:(UIEvent *)event cancelled:(BOOL)cancelled {
    if (_primary && [touches containsObject:_primary]) {
        [self sendTouch:_primary phase:cancelled ? @"cancelled" : @"ended"];
        _primary = nil;
    }
    NSUInteger remaining = [self liveTouches:event].count;
    if (_scrolling && remaining >= 2) {
        _lastCentroid = [self centroid:[self liveTouches:event]];   // 手指数变化时重置，避免跳动
    } else if (_scrolling) {
        _scrolling = NO;
        _waitForAllUp = remaining > 0;   // 滚动结束后剩下的那根手指不当作拖动
    }
    if (remaining == 0) _waitForAllUp = NO;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self finishTouches:touches event:event cancelled:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self finishTouches:touches event:event cancelled:YES];
}

@end
