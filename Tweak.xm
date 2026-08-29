#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 配置存储 key
static NSString *const kConfigText1 = @"SFM_configText1";
static NSString *const kConfigText2 = @"SFM_configText2";
static NSString *const kConfigEnabled = @"SFM_configEnabled";

// 全局状态
static BOOL g_isExecuting = NO;
static BOOL g_isCollapsed = NO;  // 收纳状态
static UIView *g_floatMenu = nil;       // 正方形菜单
static UIButton *g_execBtn = nil;
static UILabel *g_timeLabel = nil;      // 时间标签（菜单下方）
static UIView *g_secondaryView = nil;
static UITextField *g_textField1 = nil;
static UITextField *g_textField2 = nil;
static UIButton *g_saveBtn = nil;
static NSTimer *g_timeTimer = nil;
static dispatch_source_t g_scanTimer = nil;  // 1毫秒扫描定时器
static NSTimer *g_hideTimer = nil;
static UILongPressGestureRecognizer *g_longPress = nil;
static BOOL g_isVerticalTime = NO;  // 时间是否竖排显示

#pragma mark - 网络时间

static NSString *getTimeString(void) {
    NSDate *now = [NSDate date];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss"];
    return [fmt stringFromDate:now];
}

static void updateTimeLabel(void) {
    if (g_timeLabel) {
        NSString *timeStr = getTimeString();
        if (g_isVerticalTime) {
            // 竖排：时分秒从上到下，每行两个数字
            NSArray *parts = [timeStr componentsSeparatedByString:@":"];
            if (parts.count == 3) {
                g_timeLabel.text = [NSString stringWithFormat:@"%@\n%@\n%@", parts[0], parts[1], parts[2]];
            } else {
                g_timeLabel.text = timeStr;
            }
        } else {
            g_timeLabel.text = timeStr;
        }
    }
}

#pragma mark - 颜色判断

static BOOL isOrangeColor(UIColor *color) {
    if (!color) return NO;
    CGFloat r, g, b, a;
    [color getRed:&r green:&g blue:&b alpha:&a];
    // 橙色：R高(>0.7)，G中等(0.3-0.5)，B低(<0.4)，R明显高于G
    return r > 0.7 && g > 0.28 && g < 0.52 && b < 0.42 && (r - g) > 0.25;
}

static BOOL isGrayColor(UIColor *color) {
    if (!color) return NO;
    CGFloat r, g, b, a;
    [color getRed:&r green:&g blue:&b alpha:&a];
    // 灰色：红绿蓝相近(diff<0.12)，亮度中等(0.4-0.8)
    CGFloat diff = fabs(r-g) + fabs(g-b) + fabs(r-b);
    CGFloat brightness = (r + g + b) / 3.0;
    return diff < 0.12 && brightness > 0.35 && brightness < 0.85;
}

// 截图获取指定位置的像素颜色
static UIColor *getColorAtPoint(CGPoint point) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && !w.isHidden) { keyWindow = w; break; }
    }
    if (!keyWindow) return [UIColor clearColor];
    
    // 截取3x3小区域
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
    // 取中心像素 (1,1)
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

// 模拟点击（按下后1毫秒抬起）
static void simulateTapAtPoint(CGPoint point) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && !w.isHidden) { keyWindow = w; break; }
    }
    if (!keyWindow) return;
    
    UIView *hitView = [keyWindow hitTest:point withEvent:nil];
    if (!hitView) return;
    
    UITouch *touch = [[UITouch alloc] init];
    UIEvent *event = [[UIEvent alloc] init];
    [hitView touchesBegan:[NSSet setWithObject:touch] withEvent:event];
    // 1毫秒后抬起
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.001 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [hitView touchesEnded:[NSSet setWithObject:touch] withEvent:event];
    });
}

#pragma mark - 识字辨色点击

static void scanAndClick(void) {
    if (!g_isExecuting) return;
    
    NSString *targetText1 = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText1];
    NSString *targetText2 = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText2];
    
    if ((!targetText1 || targetText1.length == 0) && (!targetText2 || targetText2.length == 0)) return;
    
    // 遍历所有窗口，确保滚动后也能识别
    NSArray *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *keyWindow in windows) {
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
                        // 获取label在屏幕上的位置
                        CGRect labelFrame = [label convertRect:label.bounds toView:nil];
                        
                        // 检查文字下面一个身位的颜色
                        CGFloat bodyHeight = labelFrame.size.height;
                        CGFloat checkX = labelFrame.origin.x + labelFrame.size.width / 2;
                        CGFloat checkY = labelFrame.origin.y + labelFrame.size.height + bodyHeight;
                        CGPoint checkPoint = CGPointMake(checkX, checkY);
                        
                        UIColor *color = getColorAtPoint(checkPoint);
                        
                        if (isOrangeColor(color)) {
                            // 橙色，点击文字下面一个身位
                            CGPoint tapPoint = checkPoint;
                            NSLog(@"[SFM] 匹配文字:%@ 下方检测到橙色，点击位置:%@", label.text, NSStringFromCGPoint(tapPoint));
                            simulateTapAtPoint(tapPoint);
                            return;  // 每次只点第一个橙色匹配
                        } else if (isGrayColor(color)) {
                            // 灰色，跳过，继续找下一个
                            NSLog(@"[SFM] 匹配文字:%@ 下方检测到灰色，跳过", label.text);
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

#pragma mark - 收纳/展开

static void collapseToSide(void) {
    if (g_isCollapsed || !g_floatMenu) return;
    g_isCollapsed = YES;
    g_isVerticalTime = YES;
    
    UIWindow *window = (UIWindow *)g_floatMenu.superview;
    CGFloat screenW = window.bounds.size.width;
    CGFloat screenH = window.bounds.size.height;
    
    // 把时间标签从菜单移到window上
    CGPoint timeCenterInWindow = [g_floatMenu convertPoint:g_timeLabel.center toView:window];
    [g_timeLabel removeFromSuperview];
    [window addSubview:g_timeLabel];
    g_timeLabel.center = timeCenterInWindow;
    
    // 隐藏正方形菜单
    g_floatMenu.hidden = YES;
    
    // 时间标签竖排显示（时分秒从上到下），不旋转
    BOOL isLeft = (g_floatMenu.center.x < screenW/2);
    
    g_timeLabel.hidden = NO;
    g_timeLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    g_timeLabel.textColor = [UIColor whiteColor];
    g_timeLabel.layer.cornerRadius = 6;
    g_timeLabel.layer.masksToBounds = YES;
    g_timeLabel.transform = CGAffineTransformIdentity;  // 不旋转
    g_timeLabel.numberOfLines = 3;
    g_timeLabel.font = [UIFont systemFontOfSize:12];
    g_timeLabel.textAlignment = NSTextAlignmentCenter;
    g_timeLabel.bounds = CGRectMake(0, 0, 28, 60);  // 窄长型
    
    // 更新竖排文字
    updateTimeLabel();
    
    // 位置：吸附到就近屏幕边缘
    CGFloat targetY = MIN(MAX(g_floatMenu.center.y, 120), screenH - 120);
    if (isLeft) {
        g_timeLabel.center = CGPointMake(14, targetY);
    } else {
        g_timeLabel.center = CGPointMake(screenW - 14, targetY);
    }
    
    [window bringSubviewToFront:g_timeLabel];
    
    NSLog(@"[SFM] 已收纳到侧边，时间竖排显示");
}

static void expandFromSide(void) {
    if (!g_isCollapsed || !g_floatMenu) return;
    g_isCollapsed = NO;
    g_isVerticalTime = NO;
    
    UIWindow *window = (UIWindow *)g_floatMenu.superview;
    CGFloat screenW = window.bounds.size.width;
    
    // 显示正方形菜单
    g_floatMenu.hidden = NO;
    
    // 菜单位置从时间标签位置恢复
    CGFloat menuX = (g_timeLabel.center.x < screenW/2) ? 35 : screenW - 35;
    CGFloat menuY = g_timeLabel.center.y;
    
    g_floatMenu.center = CGPointMake(menuX, menuY);
    
    // 把时间标签从window移回菜单
    [g_timeLabel removeFromSuperview];
    [g_floatMenu addSubview:g_timeLabel];
    
    // 时间标签恢复到菜单下方，黑色字体，横排
    CGFloat timeW = 60;
    CGFloat timeH = 18;
    g_timeLabel.frame = CGRectMake(-5, g_floatMenu.bounds.size.height + 2, timeW, timeH);
    g_timeLabel.backgroundColor = [UIColor clearColor];
    g_timeLabel.textColor = [UIColor blackColor];
    g_timeLabel.layer.cornerRadius = 0;
    g_timeLabel.layer.masksToBounds = NO;
    g_timeLabel.transform = CGAffineTransformIdentity;
    g_timeLabel.numberOfLines = 1;
    g_timeLabel.font = [UIFont systemFontOfSize:11];
    
    // 更新横排文字
    updateTimeLabel();
    
    NSLog(@"[SFM] 已展开");
}

static void resetHideTimer(void) {
    if (g_hideTimer) {
        [g_hideTimer invalidate];
        g_hideTimer = nil;
    }
    g_hideTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:NO block:^(NSTimer *t) {
        collapseToSide();
    }];
}

#pragma mark - 悬浮菜单创建

static UIView *createFloatMenu(void) {
    // 正方形菜单，尺寸50x50
    CGFloat menuSize = 50;
    UIView *menu = [[UIView alloc] initWithFrame:CGRectMake(0, 0, menuSize, menuSize)];
    menu.backgroundColor = [UIColor clearColor];
    menu.layer.cornerRadius = 12;
    menu.layer.borderWidth = 1.5;
    menu.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
    
    // 执行按钮占满整个正方形
    g_execBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    g_execBtn.frame = CGRectMake(0, 0, menuSize, menuSize);
    g_execBtn.titleLabel.font = [UIFont systemFontOfSize:22];
    [g_execBtn setTitle:@"⏸" forState:UIControlStateNormal];
    g_execBtn.layer.cornerRadius = 12;
    g_execBtn.layer.masksToBounds = YES;
    [menu addSubview:g_execBtn];
    
    // 时间标签在正方形下方
    g_timeLabel = [[UILabel alloc] initWithFrame:CGRectMake(-5, menuSize + 2, 60, 18)];
    g_timeLabel.font = [UIFont systemFontOfSize:11];
    g_timeLabel.textColor = [UIColor blackColor];
    g_timeLabel.textAlignment = NSTextAlignmentCenter;
    g_timeLabel.text = getTimeString();
    [menu addSubview:g_timeLabel];
    
    return menu;
}

static UIView *createSecondaryView(void) {
    UIView *sec = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 220, 170)];
    sec.backgroundColor = [UIColor colorWithRed:1.0 green:0.95 blue:0.3 alpha:0.95];
    sec.layer.cornerRadius = 12;
    sec.layer.borderWidth = 1;
    sec.layer.borderColor = [UIColor orangeColor].CGColor;
    sec.hidden = YES;
    
    // 输入框1 - 识别文字1
    UILabel *label1 = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, 100, 20)];
    label1.text = @"识别文字1:";
    label1.font = [UIFont systemFontOfSize:12];
    label1.textColor = [UIColor blackColor];
    [sec addSubview:label1];
    
    g_textField1 = [[UITextField alloc] initWithFrame:CGRectMake(12, 32, 196, 32)];
    g_textField1.borderStyle = UITextBorderStyleRoundedRect;
    g_textField1.font = [UIFont systemFontOfSize:13];
    g_textField1.placeholder = @"输入要识别的文字1";
    g_textField1.backgroundColor = [UIColor whiteColor];
    NSString *saved1 = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText1];
    if (saved1) g_textField1.text = saved1;
    [sec addSubview:g_textField1];
    
    // 输入框2 - 识别文字2
    UILabel *label2 = [[UILabel alloc] initWithFrame:CGRectMake(12, 70, 100, 20)];
    label2.text = @"识别文字2:";
    label2.font = [UIFont systemFontOfSize:12];
    label2.textColor = [UIColor blackColor];
    [sec addSubview:label2];
    
    g_textField2 = [[UITextField alloc] initWithFrame:CGRectMake(12, 92, 196, 32)];
    g_textField2.borderStyle = UITextBorderStyleRoundedRect;
    g_textField2.font = [UIFont systemFontOfSize:13];
    g_textField2.placeholder = @"输入要识别的文字2";
    g_textField2.backgroundColor = [UIColor whiteColor];
    NSString *saved2 = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText2];
    if (saved2) g_textField2.text = saved2;
    [sec addSubview:g_textField2];
    
    // 保存按钮
    g_saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    g_saveBtn.frame = CGRectMake(148, 132, 60, 28);
    [g_saveBtn setTitle:@"保存" forState:UIControlStateNormal];
    g_saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    g_saveBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
    [g_saveBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    g_saveBtn.layer.cornerRadius = 6;
    [sec addSubview:g_saveBtn];
    
    return sec;
}

#pragma mark - 事件处理

@interface SFMHandler : NSObject
+ (void)execBtnTapped;
+ (void)saveBtnTapped;
+ (void)handleLongPress:(UILongPressGestureRecognizer *)gesture;
+ (void)handlePan:(UIPanGestureRecognizer *)pan;
+ (void)timeLabelTapped;
+ (void)handleTimePan:(UIPanGestureRecognizer *)pan;
@end

@implementation SFMHandler

+ (void)execBtnTapped {
    g_isExecuting = !g_isExecuting;
    if (g_isExecuting) {
        [g_execBtn setTitle:@"▶️" forState:UIControlStateNormal];
        g_execBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:0.5];
        // 1毫秒间隔快速扫描点击
        if (g_scanTimer) dispatch_source_cancel(g_scanTimer);
        g_scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(g_scanTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 0.001 * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(g_scanTimer, ^{
            scanAndClick();
        });
        dispatch_resume(g_scanTimer);
        NSLog(@"[SFM] 执行已开启，1毫秒扫描");
    } else {
        [g_execBtn setTitle:@"⏸" forState:UIControlStateNormal];
        g_execBtn.backgroundColor = [UIColor colorWithRed:0.7 green:0.2 blue:0.2 alpha:0.4];
        if (g_scanTimer) { dispatch_source_cancel(g_scanTimer); g_scanTimer = nil; }
        NSLog(@"[SFM] 执行已暂停");
    }
    [[NSUserDefaults standardUserDefaults] setBool:g_isExecuting forKey:kConfigEnabled];
    [[NSUserDefaults standardUserDefaults] synchronize];
    resetHideTimer();
}

+ (void)saveBtnTapped {
    NSString *text1 = g_textField1.text;
    NSString *text2 = g_textField2.text;
    [[NSUserDefaults standardUserDefaults] setObject:text1 forKey:kConfigText1];
    [[NSUserDefaults standardUserDefaults] setObject:text2 forKey:kConfigText2];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[SFM] 配置已保存: 文字1=%@ 文字2=%@", text1, text2);
    
    g_secondaryView.hidden = YES;
    [g_textField1 resignFirstResponder];
    [g_textField2 resignFirstResponder];
    resetHideTimer();
}

+ (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        NSLog(@"[SFM] 长按呼出二级菜单");
        g_secondaryView.hidden = NO;
        
        UIWindow *window = (UIWindow *)g_floatMenu.superview;
        CGFloat x = g_floatMenu.frame.origin.x;
        CGFloat y = g_floatMenu.frame.origin.y + g_floatMenu.frame.size.height + 25;
        CGFloat screenW = window.bounds.size.width;
        if (x + 220 > screenW) x = screenW - 230;
        if (x < 10) x = 10;
        g_secondaryView.frame = CGRectMake(x, y, 220, 170);
        [window bringSubviewToFront:g_secondaryView];
        resetHideTimer();
    }
}

+ (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *view = pan.view;
    UIWindow *window = (UIWindow *)view.superview;
    CGPoint translation = [pan translationInView:window];
    
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        view.center = CGPointMake(view.center.x + translation.x, view.center.y + translation.y);
        [pan setTranslation:CGPointZero inView:window];
        
        // 二级菜单跟随
        if (!g_secondaryView.hidden) {
            CGFloat x = view.frame.origin.x;
            CGFloat y = view.frame.origin.y + view.frame.size.height + 25;
            CGFloat screenW = window.bounds.size.width;
            if (x + 220 > screenW) x = screenW - 230;
            if (x < 10) x = 10;
            g_secondaryView.frame = CGRectMake(x, y, 220, 170);
        }
        resetHideTimer();
    }
}

+ (void)timeLabelTapped {
    NSLog(@"[SFM] 点击时间标签，展开菜单");
    expandFromSide();
    resetHideTimer();
}

+ (void)handleTimePan:(UIPanGestureRecognizer *)pan {
    if (!g_isCollapsed) return;  // 只有收纳状态下才能拖动时间
    
    UIView *view = pan.view;
    UIWindow *window = (UIWindow *)view.superview;
    CGPoint translation = [pan translationInView:window];
    
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        // 上下拖动
        CGFloat newY = view.center.y + translation.y;
        CGFloat screenH = window.bounds.size.height;
        newY = MAX(80, MIN(screenH - 80, newY));
        view.center = CGPointMake(view.center.x, newY);
        [pan setTranslation:CGPointZero inView:window];
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        // 拖动结束，就近吸附到左或右边缘
        CGFloat screenW = window.bounds.size.width;
        CGFloat targetX = (view.center.x < screenW/2) ? 14 : screenW - 14;
        [UIView animateWithDuration:0.25 animations:^{
            view.center = CGPointMake(targetX, view.center.y);
        }];
        NSLog(@"[SFM] 时间标签拖动结束，就近吸附");
    }
}

@end

#pragma mark - 安装

static void installFloatMenu(void) {
    if (g_floatMenu) return;
    
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && !w.isHidden) { keyWindow = w; break; }
    }
    if (!keyWindow) return;
    
    // 创建一级菜单
    g_floatMenu = createFloatMenu();
    g_floatMenu.center = CGPointMake(keyWindow.bounds.size.width - 35, 150);
    [keyWindow addSubview:g_floatMenu];
    [keyWindow bringSubviewToFront:g_floatMenu];
    
    // 创建二级菜单
    g_secondaryView = createSecondaryView();
    [keyWindow addSubview:g_secondaryView];
    [keyWindow bringSubviewToFront:g_secondaryView];
    
    // 执行按钮点击
    [g_execBtn addTarget:[SFMHandler class] action:@selector(execBtnTapped) forControlEvents:UIControlEventTouchUpInside];
    
    // 保存按钮
    [g_saveBtn addTarget:[SFMHandler class] action:@selector(saveBtnTapped) forControlEvents:UIControlEventTouchUpInside];
    
    // 长按呼出二级菜单
    g_longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:[SFMHandler class] action:@selector(handleLongPress:)];
    g_longPress.minimumPressDuration = 0.6;
    [g_floatMenu addGestureRecognizer:g_longPress];
    
    // 拖动手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[SFMHandler class] action:@selector(handlePan:)];
    pan.cancelsTouchesInView = NO;
    [g_floatMenu addGestureRecognizer:pan];
    
    // 时间标签点击（收纳状态下呼出）
    UITapGestureRecognizer *timeTap = [[UITapGestureRecognizer alloc] initWithTarget:[SFMHandler class] action:@selector(timeLabelTapped)];
    [g_timeLabel addGestureRecognizer:timeTap];
    g_timeLabel.userInteractionEnabled = YES;
    
    // 时间标签拖动手势（收纳状态下上下拖动，结束后就近吸附）
    UIPanGestureRecognizer *timePan = [[UIPanGestureRecognizer alloc] initWithTarget:[SFMHandler class] action:@selector(handleTimePan:)];
    timePan.cancelsTouchesInView = NO;
    [g_timeLabel addGestureRecognizer:timePan];
    
    // 时间更新定时器
    g_timeTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        updateTimeLabel();
    }];
    
    // 恢复执行状态
    BOOL savedEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:kConfigEnabled];
    if (savedEnabled) {
        g_isExecuting = YES;
        [g_execBtn setTitle:@"▶️" forState:UIControlStateNormal];
        g_execBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:0.5];
        // 1毫秒间隔
        g_scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(g_scanTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 0.001 * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(g_scanTimer, ^{
            scanAndClick();
        });
        dispatch_resume(g_scanTimer);
    } else {
        g_execBtn.backgroundColor = [UIColor colorWithRed:0.7 green:0.2 blue:0.2 alpha:0.4];
    }
    
    // 启动自动收纳计时
    resetHideTimer();
    
    NSLog(@"[SFM] 悬浮菜单已安装");
}

#pragma mark - Hook

%hook UIApplication

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL result = %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        installFloatMenu();
    });
    return result;
}

%end

__attribute__((constructor))
static void initialize(void) {
    NSLog(@"[SFM] SmartFloatMenu dylib已加载");
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            installFloatMenu();
        });
    });
}
