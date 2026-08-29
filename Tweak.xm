#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Vision/Vision.h>

#pragma mark - 日志功能
static NSMutableString *g_logString = nil;
static NSString *const kLogPath = @"/tmp/SmartFloatMenu_log.txt";
static void SFMLog(NSString *format, ...) {
    if (!g_logString) {
        g_logString = [[NSMutableString alloc] init];
        [g_logString appendString:@"=== SmartFloatMenu 日志 ===\n"];
    }
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSDate *now = [NSDate date];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss.SSS"];
    NSString *timeStr = [fmt stringFromDate:now];
    NSString *logLine = [NSString stringWithFormat:@"[%@] %@\n", timeStr, msg];
    [g_logString appendString:logLine];
    NSLog(@"[SFM] %@", msg);
    // 保存到文件
    @try {
        [g_logString writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } @catch (NSException *e) {}
}

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
#pragma mark - 获取keyWindow
static UIWindow *getKeyWindow(void) {
    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *w in windows) {
        if (w.isKeyWindow && !w.isHidden) {
            return w;
        }
    }
    // 兜底：返回第一个可见window
    for (UIWindow *w in windows) {
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

#pragma mark - 截图全屏
static UIImage *captureFullScreen(void) {
    UIWindow *keyWindow = getKeyWindow();
    if (!keyWindow) return nil;
    UIGraphicsBeginImageContext(keyWindow.bounds.size);
    [keyWindow drawViewHierarchyInRect:keyWindow.bounds afterScreenUpdates:NO];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

#pragma mark - 识字辨色点击（Vision OCR版，适配Unity游戏）
static int g_scanCount = 0;
static void scanAndClick(void) {
    SFMLog(@"[调试] scanAndClick 被调用，g_isExecuting=%d", g_isExecuting);
    if (!g_isExecuting) return;
    g_scanCount++;
    
    NSString *targetText1 = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText1];
    NSString *targetText2 = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText2];
    SFMLog(@"[调试] 扫描 #%d: 目标文字1='%@', 目标文字2='%@'", g_scanCount, targetText1, targetText2);
    if ((!targetText1 || targetText1.length == 0) && (!targetText2 || targetText2.length == 0)) {
        SFMLog(@"[调试] 目标文字为空，返回");
        return;
    }
    
    // 截取全屏
    UIImage *screenshot = captureFullScreen();
    if (!screenshot) {
        SFMLog(@"扫描 #%d: 截图失败", g_scanCount);
        return;
    }
    SFMLog(@"[调试] 截图成功，尺寸: %.0fx%.0f, CGImage=%p", screenshot.size.width, screenshot.size.height, screenshot.CGImage);
    
    // 用Vision框架OCR识别文字
    VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *request, NSError *error) {
        SFMLog(@"[调试] OCR completion handler 被调用，error=%@", error);
        if (error) {
            SFMLog(@"扫描 #%d: OCR错误: %@", g_scanCount, error.localizedDescription);
            return;
        }
        
        NSArray *results = request.results;
        if (!results || results.count == 0) {
            SFMLog(@"扫描 #%d: 未识别到文字", g_scanCount);
            return;
        }
        
        // 记录所有识别到的文字（方便调试）
        NSMutableString *allText = [NSMutableString string];
        for (VNRecognizedTextObservation *observation in results) {
            NSArray *candidates = [observation valueForKey:@"topCandidates"];
            if (!candidates || candidates.count == 0) continue;
            id firstCandidate = candidates[0];
            NSString *recognizedText = [firstCandidate valueForKey:@"string"];
            if (recognizedText) {
                [allText appendString:recognizedText];
                [allText appendString:@" | "];
            }
        }
        SFMLog(@"扫描 #%d: 识别到 %lu 个文字: %@", g_scanCount, (unsigned long)results.count, allText);
        
        // 遍历识别结果，找目标文字
        for (VNRecognizedTextObservation *observation in results) {
            NSArray *candidates = [observation valueForKey:@"topCandidates"];
            if (!candidates || candidates.count == 0) continue;
            id firstCandidate = candidates[0];
            NSString *recognizedText = [firstCandidate valueForKey:@"string"];
            if (!recognizedText) continue;
            
            // 去除空格和换行后匹配
            NSString *cleanText = [recognizedText stringByReplacingOccurrencesOfString:@" " withString:@""];
            cleanText = [cleanText stringByReplacingOccurrencesOfString:@"\n" withString:@""];
            
            BOOL match = NO;
            if (targetText1 && targetText1.length > 0 && [cleanText containsString:targetText1]) match = YES;
            if (targetText2 && targetText2.length > 0 && [cleanText containsString:targetText2]) match = YES;
            
            if (match) {
                // 获取文字位置（Vision的坐标是归一化的，需要转换）
                CGRect boundingBox = observation.boundingBox;
                CGSize imageSize = screenshot.size;
                CGFloat x = boundingBox.origin.x * imageSize.width;
                CGFloat y = (1 - boundingBox.origin.y - boundingBox.size.height) * imageSize.height;
                CGFloat width = boundingBox.size.width * imageSize.width;
                CGFloat height = boundingBox.size.height * imageSize.height;
                CGRect textFrame = CGRectMake(x, y, width, height);
                
                showDebugRect(CGRectMake(textFrame.origin.x - 5, textFrame.origin.y - 5, textFrame.size.width + 10, textFrame.size.height + 10));
                SFMLog(@"  匹配文字: '%@'，位置: (%.0f, %.0f)，大小: %.0fx%.0f", recognizedText, textFrame.origin.x, textFrame.origin.y, textFrame.size.width, textFrame.size.height);
                
                // 直接点击文字中心（文字本身就在橙色按钮上）
                CGPoint tapPoint = CGPointMake(textFrame.origin.x + textFrame.size.width / 2, textFrame.origin.y + textFrame.size.height / 2);
                showDebugTapDot(tapPoint);
                simulateTapAtPoint(tapPoint);
                SFMLog(@"  执行点击文字中心: (%.0f, %.0f)", tapPoint.x, tapPoint.y);
                return;
            }
        }
    }];
    
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate; // 准确模式
    request.usesLanguageCorrection = YES; // 使用语言校正
    // 设置识别语言为中文和英文
    if ([request respondsToSelector:@selector(setRecognitionLanguages:)]) {
        [request setValue:@[@"zh-Hans", @"en-US"] forKey:@"recognitionLanguages"];
    }
    
    // 执行识别（在后台线程）
    if (!screenshot.CGImage) {
        SFMLog(@"[调试] CGImage 为 nil，跳过 OCR");
        return;
    }
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:screenshot.CGImage options:@{}];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *reqError = nil;
        BOOL success = [handler performRequests:@[request] error:&reqError];
        SFMLog(@"[调试] performRequests 完成，success=%d, error=%@", success, reqError);
    });
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
    SFMLog(@"执行状态切换: %@", g_isExecuting ? @"开启" : @"暂停");
    if (g_isExecuting) {
        [g_floatBtn setTitle:@"▶️" forState:UIControlStateNormal];
        g_floatBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:0.8];
        if (g_scanTimer) dispatch_source_cancel(g_scanTimer);
        g_scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(g_scanTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 0.5 * NSEC_PER_SEC, 0); // 每0.5秒扫描一次
        dispatch_source_set_event_handler(g_scanTimer, ^{
            SFMLog(@"[调试] 定时器触发，调用 scanAndClick");
            scanAndClick();
        });
        dispatch_resume(g_scanTimer);
        SFMLog(@"扫描定时器已启动（每0.5秒一次），g_scanTimer=%p", g_scanTimer);
    } else {
        [g_floatBtn setTitle:@"⏸" forState:UIControlStateNormal];
        g_floatBtn.backgroundColor = [UIColor colorWithRed:0.7 green:0.2 blue:0.2 alpha:0.8];
        if (g_scanTimer) { dispatch_source_cancel(g_scanTimer); g_scanTimer = nil; }
        clearDebugMarks();
        SFMLog(@"扫描定时器已停止");
    }
}

+ (void)floatBtnLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        SFMLog(@"长按触发，显示设置框");
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
    if (!vc) {
        SFMLog(@"topViewController 为 nil，无法显示设置框");
        return;
    }
    SFMLog(@"显示设置框");
    
    NSString *saved1 = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText1] ?: @"";
    NSString *saved2 = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText2] ?: @"";
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"识别文字设置" message:@"OCR识别屏幕文字（适配Unity游戏）\n下方橙色则自动点击" preferredStyle:UIAlertControllerStyleAlert];
    
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
        SFMLog(@"保存设置: text1=%@, text2=%@", text1, text2);
    }];
    
    UIAlertAction *exportLogAction = [UIAlertAction actionWithTitle:@"导出日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        SFMLog(@"用户点击导出日志");
        // 保存日志到文件
        [g_logString writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        // 复制到剪贴板（避免分享面板卡屏）
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = g_logString;
        SFMLog(@"日志已复制到剪贴板，长度: %lu", (unsigned long)g_logString.length);
        // 简单提示
        UIAlertController *tip = [UIAlertController alertControllerWithTitle:@"日志已导出" message:@"已复制到剪贴板\n文件路径: /tmp/SmartFloatMenu_log.txt" preferredStyle:UIAlertControllerStyleAlert];
        [tip addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:tip animated:YES completion:nil];
    }];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil];
    
    [alert addAction:saveAction];
    [alert addAction:exportLogAction];
    [alert addAction:cancelAction];
    
    [vc presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - 安装悬浮按钮
static void installFloatButton(void) {
    SFMLog(@"开始安装悬浮按钮");
    if (g_floatBtn) {
        SFMLog(@"悬浮按钮已存在，跳过");
        return;
    }
    
    UIWindow *keyWindow = getKeyWindow();
    if (!keyWindow) {
        SFMLog(@"keyWindow 为 nil，1秒后重试");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            installFloatButton();
        });
        return;
    }
    
    CGSize screenSize = keyWindow.bounds.size;
    SFMLog(@"keyWindow: %@, 屏幕尺寸: %.0fx%.0f, window数量: %lu", keyWindow, screenSize.width, screenSize.height, (unsigned long)[UIApplication sharedApplication].windows.count);
    
    // 列出所有window
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        SFMLog(@"  window: %@, hidden: %d, level: %.0f, bounds: %.0fx%.0f", w, w.hidden, w.windowLevel, w.bounds.size.width, w.bounds.size.height);
    }
    
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
    SFMLog(@"悬浮按钮创建成功");
    
    // 长按手势
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:[SFMHandler class] action:@selector(floatBtnLongPressed:)];
    longPress.minimumPressDuration = 0.6;
    [g_floatBtn addGestureRecognizer:longPress];
    SFMLog(@"长按手势添加成功");
    
    // 拖动手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[SFMHandler class] action:@selector(handlePan:)];
    [g_floatBtn addGestureRecognizer:pan];
    SFMLog(@"拖动手势添加成功");
    
    [keyWindow addSubview:g_floatBtn];
    [keyWindow bringSubviewToFront:g_floatBtn];
    SFMLog(@"悬浮按钮已添加到keyWindow，位置: (%.0f, %.0f), superview: %@", g_floatBtn.center.x, g_floatBtn.center.y, g_floatBtn.superview);
}

#pragma mark - 监听APP进入前台
static void appDidBecomeActive(NSNotification *note) {
    SFMLog(@"APP进入前台");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        installFloatButton();
    });
}

#pragma mark - 入口
__attribute__((constructor))
static void init_tweak(void) {
    SFMLog(@"SmartFloatMenu 插件已加载（constructor）");
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        appDidBecomeActive(note);
    }];
    SFMLog(@"已注册 UIApplicationDidBecomeActiveNotification 监听");
}
