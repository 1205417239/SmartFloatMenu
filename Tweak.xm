#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// 配置存储 key
static NSString *const kConfigText = @"SFM_configText";
static NSString *const kConfigColor = @"SFM_configColor";
static NSString *const kConfigEnabled = @"SFM_configEnabled";

// 全局状态
static BOOL g_isExecuting = NO;
static BOOL g_secondaryExpanded = NO;
static UIView *g_floatMenu = nil;
static UIButton *g_execBtn = nil;
static UILabel *g_timeLabel = nil;
static UIView *g_secondaryView = nil;
static UITextField *g_textField1 = nil;
static UITextField *g_textField2 = nil;
static UIButton *g_saveBtn = nil;
static NSTimer *g_timeTimer = nil;
static NSTimer *g_scanTimer = nil;
static NSTimer *g_hideTimer = nil;
static CGPoint g_lastTouchPoint;
static NSDate *g_lastActivityDate;

#pragma mark - 颜色解析

static UIColor *parseColor(NSString *colorStr) {
    if (!colorStr || colorStr.length == 0) return nil;
    NSString *s = [colorStr lowercaseString];
    if ([s containsString:@"红"]) return [UIColor redColor];
    if ([s containsString:@"蓝"]) return [UIColor blueColor];
    if ([s containsString:@"绿"]) return [UIColor greenColor];
    if ([s containsString:@"黄"]) return [UIColor yellowColor];
    if ([s containsString:@"黑"]) return [UIColor blackColor];
    if ([s containsString:@"白"]) return [UIColor whiteColor];
    if ([s containsString:@"灰"]) return [UIColor grayColor];
    if ([s containsString:@"橙"]) return [UIColor orangeColor];
    if ([s containsString:@"紫"]) return [UIColor purpleColor];
    if ([s containsString:@"棕"]) return [UIColor brownColor];
    if ([s containsString:@"青"]) return [UIColor cyanColor];
    // 十六进制
    if ([s hasPrefix:@"#"] && s.length == 7) {
        unsigned int rgb;
        NSScanner *scanner = [NSScanner scannerWithString:[s substringFromIndex:1]];
        [scanner scanHexInt:&rgb];
        return [UIColor colorWithRed:((rgb>>16)&0xFF)/255.0 green:((rgb>>8)&0xFF)/255.0 blue:(rgb&0xFF)/255.0 alpha:1.0];
    }
    return nil;
}

static BOOL colorMatch(UIColor *c1, UIColor *c2) {
    if (!c1 || !c2) return NO;
    CGFloat r1,g1,b1,a1,r2,g2,b2,a2;
    [c1 getRed:&r1 green:&g1 blue:&b1 alpha:&a1];
    [c2 getRed:&r2 green:&g2 blue:&b2 alpha:&a2];
    CGFloat diff = fabs(r1-r2)+fabs(g1-g2)+fabs(b1-b2);
    return diff < 0.3; // 容差
}

#pragma mark - 网络时间

static NSString *getNetworkTimeString(void) {
    NSDate *now = [NSDate date];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss"];
    [fmt setTimeZone:[NSTimeZone systemTimeZone]];
    return [fmt stringFromDate:now];
}

static void updateTimeLabel(void) {
    if (g_timeLabel) {
        g_timeLabel.text = getNetworkTimeString();
    }
}

#pragma mark - 识字辨颜色点击

static void scanAndClick(void) {
    if (!g_isExecuting) return;
    
    NSString *targetText = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText];
    NSString *targetColorStr = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigColor];
    UIColor *targetColor = parseColor(targetColorStr);
    
    if (!targetText || targetText.length == 0) return;
    
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && !w.isHidden) { keyWindow = w; break; }
    }
    if (!keyWindow) return;
    
    // 遍历所有视图查找匹配的UILabel
    NSMutableArray *queue = [NSMutableArray arrayWithArray:keyWindow.subviews];
    while (queue.count > 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        
        if ([view isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)view;
            if (label.text && [label.text containsString:targetText]) {
                // 检查颜色
                BOOL colorOk = YES;
                if (targetColor) {
                    colorOk = colorMatch(label.textColor, targetColor);
                }
                if (colorOk && !label.hidden && label.alpha > 0.1) {
                    // 点击label中心
                    CGPoint center = [label convertPoint:label.center toView:nil];
                    NSLog(@"[SFM] 匹配到文字:%@ 颜色:%@ 位置:%@", label.text, targetColorStr, NSStringFromCGPoint(center));
                    
                    // 模拟点击
                    UITouch *touch = [[UITouch alloc] init];
                    // 用更直接的方式：发送事件
                    UIEvent *event = [[UIEvent alloc] init];
                    // 实际上，我们用hitTest找到目标view并发送touchesEnded
                    UIView *hitView = [keyWindow hitTest:center withEvent:nil];
                    if (hitView) {
                        // 模拟点击
                        [hitView touchesEnded:[NSSet setWithObject:touch] withEvent:event];
                    }
                    return; // 每次只点第一个匹配
                }
            }
        }
        
        for (UIView *sub in view.subviews) {
            [queue addObject:sub];
        }
    }
}

#pragma mark - 自动吸附侧边

static void snapToSide(void) {
    if (!g_floatMenu) return;
    UIWindow *window = (UIWindow *)g_floatMenu.superview;
    if (!window) return;
    
    CGFloat centerX = g_floatMenu.center.x;
    CGFloat screenW = window.bounds.size.width;
    CGFloat targetX = (centerX < screenW/2) ? 35 : screenW - 35;
    
    [UIView animateWithDuration:0.3 animations:^{
        g_floatMenu.center = CGPointMake(targetX, g_floatMenu.center.y);
    }];
}

static void resetHideTimer(void) {
    g_lastActivityDate = [NSDate date];
    if (g_hideTimer) {
        [g_hideTimer invalidate];
        g_hideTimer = nil;
    }
    g_hideTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:NO block:^(NSTimer *t) {
        snapToSide();
    }];
}

#pragma mark - 悬浮菜单创建

static UIView *createFloatMenu(void) {
    UIView *menu = [[UIView alloc] initWithFrame:CGRectMake(0, 100, 70, 100)];
    menu.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:0.85];
    menu.layer.cornerRadius = 12;
    menu.layer.borderWidth = 1;
    menu.layer.borderColor = [UIColor whiteColor].CGColor;
    
    // 执行按钮
    g_execBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    g_execBtn.frame = CGRectMake(15, 10, 40, 40);
    g_execBtn.titleLabel.font = [UIFont systemFontOfSize:20];
    [g_execBtn setTitle:@"⏸" forState:UIControlStateNormal];
    [g_execBtn addTarget:nil action:@selector(execBtnTapped) forControlEvents:UIControlEventTouchUpInside];
    [menu addSubview:g_execBtn];
    
    // 网络时间标签
    g_timeLabel = [[UILabel alloc] initWithFrame:CGRectMake(2, 55, 66, 20)];
    g_timeLabel.font = [UIFont systemFontOfSize:10];
    g_timeLabel.textColor = [UIColor whiteColor];
    g_timeLabel.textAlignment = NSTextAlignmentCenter;
    g_timeLabel.text = getNetworkTimeString();
    [menu addSubview:g_timeLabel];
    
    // 展开/收起提示（底部小箭头）
    UILabel *arrowLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 78, 70, 15)];
    arrowLabel.text = @"▼";
    arrowLabel.font = [UIFont systemFontOfSize:10];
    arrowLabel.textColor = [UIColor whiteColor];
    arrowLabel.textAlignment = NSTextAlignmentCenter;
    [menu addSubview:arrowLabel];
    
    return menu;
}

static UIView *createSecondaryView(void) {
    UIView *sec = [[UIView alloc] initWithFrame:CGRectMake(0, 100, 200, 160)];
    sec.backgroundColor = [UIColor colorWithRed:1.0 green:0.9 blue:0.2 alpha:0.92];
    sec.layer.cornerRadius = 12;
    sec.layer.borderWidth = 1;
    sec.layer.borderColor = [UIColor orangeColor].CGColor;
    sec.hidden = YES;
    
    // 输入框1 - 识别文字
    UILabel *label1 = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, 80, 20)];
    label1.text = @"识别文字:";
    label1.font = [UIFont systemFontOfSize:12];
    label1.textColor = [UIColor blackColor];
    [sec addSubview:label1];
    
    g_textField1 = [[UITextField alloc] initWithFrame:CGRectMake(10, 30, 180, 30)];
    g_textField1.borderStyle = UITextBorderStyleRoundedRect;
    g_textField1.font = [UIFont systemFontOfSize:13];
    g_textField1.placeholder = @"输入要识别的文字";
    g_textField1.backgroundColor = [UIColor whiteColor];
    NSString *savedText = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText];
    if (savedText) g_textField1.text = savedText;
    [sec addSubview:g_textField1];
    
    // 输入框2 - 识别颜色
    UILabel *label2 = [[UILabel alloc] initWithFrame:CGRectMake(10, 65, 80, 20)];
    label2.text = @"识别颜色:";
    label2.font = [UIFont systemFontOfSize:12];
    label2.textColor = [UIColor blackColor];
    [sec addSubview:label2];
    
    g_textField2 = [[UITextField alloc] initWithFrame:CGRectMake(10, 87, 180, 30)];
    g_textField2.borderStyle = UITextBorderStyleRoundedRect;
    g_textField2.font = [UIFont systemFontOfSize:13];
    g_textField2.placeholder = @"如:红色/蓝色/#FF0000";
    g_textField2.backgroundColor = [UIColor whiteColor];
    NSString *savedColor = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigColor];
    if (savedColor) g_textField2.text = savedColor;
    [sec addSubview:g_textField2];
    
    // 保存按钮
    g_saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    g_saveBtn.frame = CGRectMake(130, 125, 60, 28);
    [g_saveBtn setTitle:@"保存" forState:UIControlStateNormal];
    g_saveBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    g_saveBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:1.0];
    [g_saveBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    g_saveBtn.layer.cornerRadius = 6;
    [g_saveBtn addTarget:nil action:@selector(saveBtnTapped) forControlEvents:UIControlEventTouchUpInside];
    [sec addSubview:g_saveBtn];
    
    return sec;
}

#pragma mark - 按钮事件

@interface SFMHandler : NSObject
+ (void)execBtnTapped;
+ (void)saveBtnTapped;
+ (void)menuTapped;
+ (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

@implementation SFMHandler

+ (void)execBtnTapped {
    g_isExecuting = !g_isExecuting;
    if (g_isExecuting) {
        [g_execBtn setTitle:@"▶️" forState:UIControlStateNormal];
        g_execBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:0.6];
        // 启动扫描定时器
        g_scanTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            scanAndClick();
        }];
        NSLog(@"[SFM] 执行已开启");
    } else {
        [g_execBtn setTitle:@"⏸" forState:UIControlStateNormal];
        g_execBtn.backgroundColor = [UIColor clearColor];
        if (g_scanTimer) { [g_scanTimer invalidate]; g_scanTimer = nil; }
        NSLog(@"[SFM] 执行已暂停");
    }
    [[NSUserDefaults standardUserDefaults] setBool:g_isExecuting forKey:kConfigEnabled];
    [[NSUserDefaults standardUserDefaults] synchronize];
    resetHideTimer();
}

+ (void)saveBtnTapped {
    NSString *text = g_textField1.text;
    NSString *color = g_textField2.text;
    [[NSUserDefaults standardUserDefaults] setObject:text forKey:kConfigText];
    [[NSUserDefaults standardUserDefaults] setObject:color forKey:kConfigColor];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[SFM] 配置已保存: 文字=%@ 颜色=%@", text, color);
    
    // 关闭二级菜单
    g_secondaryExpanded = NO;
    g_secondaryView.hidden = YES;
    
    // 收起键盘
    [g_textField1 resignFirstResponder];
    [g_textField2 resignFirstResponder];
    
    resetHideTimer();
}

+ (void)menuTapped {
    // 展开/收起二级菜单
    g_secondaryExpanded = !g_secondaryExpanded;
    g_secondaryView.hidden = !g_secondaryExpanded;
    if (g_secondaryExpanded) {
        // 定位二级菜单位置
        UIWindow *window = (UIWindow *)g_floatMenu.superview;
        CGFloat x = g_floatMenu.frame.origin.x;
        CGFloat y = g_floatMenu.frame.origin.y + g_floatMenu.frame.size.height + 5;
        CGFloat screenW = window.bounds.size.width;
        if (x + 200 > screenW) x = screenW - 210;
        g_secondaryView.frame = CGRectMake(x, y, 200, 160);
    }
    resetHideTimer();
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
            CGFloat y = view.frame.origin.y + view.frame.size.height + 5;
            CGFloat screenW = window.bounds.size.width;
            if (x + 200 > screenW) x = screenW - 210;
            g_secondaryView.frame = CGRectMake(x, y, 200, 160);
        }
        resetHideTimer();
    }
}

@end

#pragma mark - 安装悬浮菜单

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
    
    // 给执行按钮设置target
    [g_execBtn removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    [g_execBtn addTarget:[SFMHandler class] action:@selector(execBtnTapped) forControlEvents:UIControlEventTouchUpInside];
    
    // 给保存按钮设置target
    [g_saveBtn removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
    [g_saveBtn addTarget:[SFMHandler class] action:@selector(saveBtnTapped) forControlEvents:UIControlEventTouchUpInside];
    
    // 点击一级菜单展开二级菜单（用手势识别，避免和执行按钮冲突）
    UITapGestureRecognizer *menuTap = [[UITapGestureRecognizer alloc] initWithTarget:[SFMHandler class] action:@selector(menuTapped)];
    menuTap.cancelsTouchesInView = NO;
    [g_floatMenu addGestureRecognizer:menuTap];
    
    // 拖动手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[SFMHandler class] action:@selector(handlePan:)];
    pan.cancelsTouchesInView = NO;
    [g_floatMenu addGestureRecognizer:pan];
    
    // 时间更新定时器
    g_timeTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        updateTimeLabel();
    }];
    
    // 恢复执行状态
    BOOL savedEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:kConfigEnabled];
    if (savedEnabled) {
        g_isExecuting = YES;
        [g_execBtn setTitle:@"▶️" forState:UIControlStateNormal];
        g_execBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:0.6];
        g_scanTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            scanAndClick();
        }];
    }
    
    // 启动自动吸附计时
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

%hook UIWindow

- (void)makeKeyAndVisible {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_floatMenu && g_floatMenu.superview != self) {
            [self addSubview:g_floatMenu];
            [self addSubview:g_secondaryView];
            [self bringSubviewToFront:g_floatMenu];
            [self bringSubviewToFront:g_secondaryView];
        }
    });
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
