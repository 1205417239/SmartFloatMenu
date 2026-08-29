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
static NSTimer *g_scanTimer = nil;
static NSTimer *g_hideTimer = nil;
static UILongPressGestureRecognizer *g_longPress = nil;

#pragma mark - 网络时间

static NSString *getTimeString(void) {
    NSDate *now = [NSDate date];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss"];
    return [fmt stringFromDate:now];
}

static void updateTimeLabel(void) {
    if (g_timeLabel) {
        g_timeLabel.text = getTimeString();
    }
}

#pragma mark - 识字点击（两个文字都识别）

static void scanAndClick(void) {
    if (!g_isExecuting) return;
    
    NSString *targetText1 = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText1];
    NSString *targetText2 = [[NSUserDefaults standardUserDefaults] stringForKey:kConfigText2];
    
    if ((!targetText1 || targetText1.length == 0) && (!targetText2 || targetText2.length == 0)) return;
    
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && !w.isHidden) { keyWindow = w; break; }
    }
    if (!keyWindow) return;
    
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
                    CGPoint center = [label convertPoint:label.center toView:nil];
                    NSLog(@"[SFM] 匹配到文字:%@ 位置:%@", label.text, NSStringFromCGPoint(center));
                    UIView *hitView = [keyWindow hitTest:center withEvent:nil];
                    if (hitView) {
                        UITouch *touch = [[UITouch alloc] init];
                        UIEvent *event = [[UIEvent alloc] init];
                        [hitView touchesEnded:[NSSet setWithObject:touch] withEvent:event];
                    }
                    return;
                }
            }
        }
        
        for (UIView *sub in view.subviews) {
            [queue addObject:sub];
        }
    }
}

#pragma mark - 收纳/展开

static void collapseToSide(void) {
    if (g_isCollapsed || !g_floatMenu) return;
    g_isCollapsed = YES;
    
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
    
    // 时间标签竖立显示，吸附到边缘
    BOOL isLeft = (g_floatMenu.center.x < screenW/2);
    
    g_timeLabel.hidden = NO;
    g_timeLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    g_timeLabel.textColor = [UIColor whiteColor];
    g_timeLabel.layer.cornerRadius = 4;
    g_timeLabel.layer.masksToBounds = YES;
    g_timeLabel.bounds = CGRectMake(0, 0, 70, 20);
    
    // 旋转90度竖立显示
    g_timeLabel.transform = CGAffineTransformMakeRotation(isLeft ? M_PI_2 : -M_PI_2);
    
    // 位置：吸附到就近屏幕边缘
    CGFloat targetY = MIN(MAX(g_floatMenu.center.y, 120), screenH - 120);
    if (isLeft) {
        g_timeLabel.center = CGPointMake(12, targetY);
    } else {
        g_timeLabel.center = CGPointMake(screenW - 12, targetY);
    }
    
    [window bringSubviewToFront:g_timeLabel];
    
    NSLog(@"[SFM] 已收纳到侧边，时间竖立显示");
}

static void expandFromSide(void) {
    if (!g_isCollapsed || !g_floatMenu) return;
    g_isCollapsed = NO;
    
    UIWindow *window = (UIWindow *)g_floatMenu.superview;
    CGFloat screenW = window.bounds.size.width;
    
    // 恢复旋转
    g_timeLabel.transform = CGAffineTransformIdentity;
    
    // 显示正方形菜单
    g_floatMenu.hidden = NO;
    
    // 菜单位置从时间标签位置恢复
    CGFloat menuX = (g_timeLabel.center.x < screenW/2) ? 35 : screenW - 35;
    CGFloat menuY = g_timeLabel.center.y;
    
    g_floatMenu.center = CGPointMake(menuX, menuY);
    
    // 把时间标签从window移回菜单
    [g_timeLabel removeFromSuperview];
    [g_floatMenu addSubview:g_timeLabel];
    
    // 时间标签恢复到菜单下方，黑色字体
    CGFloat timeW = 60;
    CGFloat timeH = 18;
    g_timeLabel.frame = CGRectMake(-5, g_floatMenu.bounds.size.height + 2, timeW, timeH);
    g_timeLabel.backgroundColor = [UIColor clearColor];
    g_timeLabel.textColor = [UIColor blackColor];
    g_timeLabel.layer.cornerRadius = 0;
    g_timeLabel.layer.masksToBounds = NO;
    
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
@end

@implementation SFMHandler

+ (void)execBtnTapped {
    g_isExecuting = !g_isExecuting;
    if (g_isExecuting) {
        [g_execBtn setTitle:@"▶️" forState:UIControlStateNormal];
        g_execBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:0.5];
        g_scanTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            scanAndClick();
        }];
        NSLog(@"[SFM] 执行已开启");
    } else {
        [g_execBtn setTitle:@"⏸" forState:UIControlStateNormal];
        g_execBtn.backgroundColor = [UIColor colorWithRed:0.7 green:0.2 blue:0.2 alpha:0.4];
        if (g_scanTimer) { [g_scanTimer invalidate]; g_scanTimer = nil; }
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
        g_scanTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            scanAndClick();
        }];
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
