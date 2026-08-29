#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#pragma mark - 配置key
static NSString *const kConfigText1 = @"SFM_configText1";
static NSString *const kConfigText2 = @"SFM_configText2";

#pragma mark - 全局状态
static BOOL g_isExecuting = NO;
static UIButton *g_floatBtn = nil;
static dispatch_source_t g_scanTimer = nil;

// 调试可视化
static UIView *g_debugOverlay = nil;
static UIView *g_debugRect = nil;
static UIView *g_debugTapDot = nil;

#pragma mark - 颜色判断
static BOOL isOrangeColor(UIColor *color) {
    if (!color) return NO;
    CGFloat r, g, b, a;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return r > 0.7 && g > 0.28 && g < 0.52 && b < 0.42 && (r - g) > 0.25;
}

#pragma mark - 获取keyWindow
static UIWindow *getKeyWindow(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && !w.isHidden) return w;
    }
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (!w.isHidden) return w;
    }
    return nil;
}

#pragma mark - 获取当前ViewController
static UIViewController *topViewController(void) {
    UIWindow *keyWindow = getKeyWindow();
    if (!keyWindow) return nil;
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

#pragma mark - 截图取色
static UIColor *getColorAtPoint(CGPoint point) {
    UIWindow *keyWindow = getKeyWindow();
    if (!keyWindow) return [UIColor clearColor];
    CGRect captureRect = CGRectMake(point.x - 1, point.y - 1, 3, 3);
    UIGraphicsBeginImageContext(captureRect.size);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(context, -captureRect.origin.x, -captureRect.origin.y);
    [keyWindow drawViewHierarchyInRect:keyWindow.bounds afterScreenUpdates:NO];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (!image) return [UIColor clearColor];
    CGImageRef cgImage = image.CGImage;
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(cgImage));
    if (!data) return [UIColor clearColor];
    const UInt8 *rawData = CFDataGetBytePtr(data);
    NSUInteger bytesPerPixel = 4;
    NSUInteger pixelIndex = 1 * (3 * bytesPerPixel) + 1 * bytesPerPixel;
    if (pixelIndex + 2 < CFDataGetLength(data)) {
        CGFloat red = rawData[pixelIndex] / 255.0;
        CGFloat green = rawData[pixelIndex + 1] / 255.0;
        CGFloat blue = rawData[pixelIndex + 2] / 255.0;
        CFRelease(data);
        return [UIColor colorWithRed:red green:green blue:blue alpha:1.0];
    }
    CFRelease(data);
    return [UIColor clearColor];
}

#pragma mark - 模拟点击
static void simulateTapAtPoint(CGPoint point) {
    UIWindow *keyWindow = getKeyWindow();
    if (!keyWindow) return;
    UIView *hitView = [keyWindow hitTest:point withEvent:nil];
    if (!hitView) return;
    UITouch *touch = [[UITouch alloc] init];
    UIEvent *event = [[UIEvent alloc] init];
    [hitView touchesBegan:[NSSet setWithObject:touch] withEvent:event];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.001 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [hitView touchesEnded:[NSSet setWithObject:touch] withEvent:event];
    });
}

#pragma mark - 调试可视化
static void ensureDebugOverlay(void) {
    if (g_debugOverlay) return;
    UIWindow *keyWindow = getKeyWindow();
    if (!keyWindow) return;
    g_debugOverlay = [[UIView alloc] initWithFrame:keyWindow.bounds];
    g_debugOverlay.backgroundColor = [UIColor clearColor];
    g_debugOverlay.userInteractionEnabled = NO;
    [keyWindow addSubview:g_debugOverlay];
    [keyWindow bringSubviewToFront:g_debugOverlay];
}
static void showDebugRect(CGRect frame) {
    ensureDebugOverlay();
    if (!g_debugRect) {
        g_debugRect = [[UIView alloc] init];
        g_debugRect.backgroundColor = [UIColor clearColor];
        g_debugRect.layer.borderColor = [UIColor redColor].CGColor;
        g_debugRect.layer.borderWidth = 2.0;
        [g_debugOverlay addSubview:g_debugRect];
    }
    g_debugRect.frame = frame;
    g_debugRect.hidden = NO;
}
static void showDebugTapDot(CGPoint point) {
    ensureDebugOverlay();
    if (!g_debugTapDot) {
        g_debugTapDot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 20, 20)];
        g_debugTapDot.backgroundColor = [UIColor whiteColor];
        g_debugTapDot.layer.cornerRadius = 10;
        [g_debugOverlay addSubview:g_debugTapDot];
    }
    g_debugTapDot.center = point;
    g_debugTapDot.hidden = NO;
    g_debugTapDot.alpha = 1.0;
    [UIView animateWithDuration:0.15 animations:^{
        g_debugTapDot.alpha = 0.3;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.1 animations:^{
            g_debugTapDot.alpha = 1.0;
        }];
    }];
}
static void clearDebugMarks(void) {
    if (g_debugRect) g_debugRect.hidden = YES;
    if (g_debugTapDot) g_debugTapDot.hidden = YES;
}

#pragma mark - 识字辨色点击
static void scanAndClick(void) {
    if (!g_isExecuting) return;
    NSString *targetText1 = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText1];
    NSString *targetText2 = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText2];
    if ((!targetText1 || targetText1.length == 0) && (!targetText2 || targetText2.length == 0)) return;
    
    for (UIWindow *keyWindow in [UIApplication sharedApplication].windows) {
        if (keyWindow.hidden || keyWindow.alpha < 0.1) continue;
        NSMutableArray *queue = [NSMutableArray arrayWithArray:keyWindow.subviews];
        while (queue.count > 0) {
            UIView *view = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([view isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)view;
                if (label.text && !label.hidden && label.alpha > 0.1) {
                    BOOL match = NO;
                    if (targetText1 && targetText1.length > 0 && [label.text containsString:targetText1]) match = YES;
                    if (targetText2 && targetText2.length > 0 && [label.text containsString:targetText2]) match = YES;
                    if (match) {
                        CGRect labelFrame = [label convertRect:label.bounds toView:nil];
                        showDebugRect(CGRectMake(labelFrame.origin.x - 5, labelFrame.origin.y - 5, labelFrame.size.width + 10, labelFrame.size.height + 10));
                        CGFloat bodyHeight = labelFrame.size.height;
                        CGFloat checkX = labelFrame.origin.x + labelFrame.size.width / 2;
                        CGFloat checkY = labelFrame.origin.y + labelFrame.size.height + bodyHeight;
                        CGPoint checkPoint = CGPointMake(checkX, checkY);
                        UIColor *color = getColorAtPoint(checkPoint);
                        if (isOrangeColor(color)) {
                            showDebugTapDot(checkPoint);
                            simulateTapAtPoint(checkPoint);
                            return;
                        }
                    }
                }
            }
            for (UIView *sub in view.subviews) {
                [queue addObject:sub];
            }
        }
    }
}

#pragma mark - 事件处理
@interface SFMHandler : NSObject
+ (void)floatBtnTapped;
+ (void)floatBtnLongPressed:(UILongPressGestureRecognizer *)gesture;
+ (void)showSettings;
+ (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

@implementation SFMHandler

+ (void)floatBtnTapped {
    g_isExecuting = !g_isExecuting;
    NSLog(@"[SFM] 执行状态切换: %@", g_isExecuting ? @"开启" : @"暂停");
    if (g_isExecuting) {
        [g_floatBtn setTitle:@"▶️" forState:UIControlStateNormal];
        g_floatBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:0.8];
        if (g_scanTimer) dispatch_source_cancel(g_scanTimer);
        g_scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(g_scanTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 0.01 * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(g_scanTimer, ^{
            scanAndClick();
        });
        dispatch_resume(g_scanTimer);
    } else {
        [g_floatBtn setTitle:@"⏸" forState:UIControlStateNormal];
        g_floatBtn.backgroundColor = [UIColor colorWithRed:0.7 green:0.2 blue:0.2 alpha:0.8];
        if (g_scanTimer) { dispatch_source_cancel(g_scanTimer); g_scanTimer = nil; }
        clearDebugMarks();
    }
}

+ (void)floatBtnLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        [self showSettings];
    }
}

+ (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *view = pan.view;
    UIWindow *window = view.window;
    CGPoint translation = [pan translationInView:window];
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        view.center = CGPointMake(view.center.x + translation.x, view.center.y + translation.y);
        [pan setTranslation:CGPointZero inView:window];
    }
}

+ (void)showSettings {
    UIViewController *vc = topViewController();
    if (!vc) return;
    
    NSString *saved1 = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText1] ?: @"";
    NSString *saved2 = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText2] ?: @"";
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"识别文字设置" message:@"输入需要识别的文字（下方橙色则点击）" preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"识别文字1";
        textField.text = saved1;
    }];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"识别文字2";
        textField.text = saved2;
    }];
    
    UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text1 = alert.textFields[0].text;
        NSString *text2 = alert.textFields[1].text;
        [[NSUserDefaults standardUserDefaults] setObject:text1 forKey:kConfigText1];
        [[NSUserDefaults standardUserDefaults] setObject:text2 forKey:kConfigText2];
        [[NSUserDefaults standardUserDefaults] synchronize];
        NSLog(@"[SFM] 保存设置: text1=%@, text2=%@", text1, text2);
    }];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    
    [alert addAction:saveAction];
    [alert addAction:cancelAction];
    
    [vc presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - 安装悬浮按钮
static void installFloatButton(void) {
    if (g_floatBtn) return;
    
    UIWindow *keyWindow = getKeyWindow();
    if (!keyWindow) {
        NSLog(@"[SFM] keyWindow 为 nil，1秒后重试");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            installFloatButton();
        });
        return;
    }
    
    CGSize screenSize = keyWindow.bounds.size;
    NSLog(@"[SFM] 屏幕尺寸: %.0fx%.0f, window数量: %lu", screenSize.width, screenSize.height, (unsigned long)[UIApplication sharedApplication].windows.count);
    
    // 创建悬浮按钮
    g_floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    g_floatBtn.frame = CGRectMake(0, 0, 50, 50);
    g_floatBtn.center = CGPointMake(screenSize.width - 35, 150);
    g_floatBtn.backgroundColor = [UIColor colorWithRed:0.7 green:0.2 blue:0.2 alpha:0.8];
    g_floatBtn.layer.cornerRadius = 25;
    g_floatBtn.layer.borderWidth = 2;
    g_floatBtn.layer.borderColor = [UIColor whiteColor].CGColor;
    g_floatBtn.titleLabel.font = [UIFont systemFontOfSize:20];
    [g_floatBtn setTitle:@"⏸" forState:UIControlStateNormal];
    [g_floatBtn addTarget:[SFMHandler class] action:@selector(floatBtnTapped) forControlEvents:UIControlEventTouchUpInside];
    
    // 长按手势
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:[SFMHandler class] action:@selector(floatBtnLongPressed:)];
    longPress.minimumPressDuration = 0.6;
    [g_floatBtn addGestureRecognizer:longPress];
    
    // 拖动手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[SFMHandler class] action:@selector(handlePan:)];
    [g_floatBtn addGestureRecognizer:pan];
    
    [keyWindow addSubview:g_floatBtn];
    [keyWindow bringSubviewToFront:g_floatBtn];
    
    NSLog(@"[SFM] 悬浮按钮已安装，位置: (%.0f, %.0f)", g_floatBtn.center.x, g_floatBtn.center.y);
}

#pragma mark - 监听APP进入前台
static void appDidBecomeActive(NSNotification *note) {
    NSLog(@"[SFM] APP进入前台");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        installFloatButton();
    });
}

#pragma mark - 入口
__attribute__((constructor))
static void init_tweak(void) {
    NSLog(@"[SFM] SmartFloatMenu 已加载");
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        appDidBecomeActive(note);
    }];
}
