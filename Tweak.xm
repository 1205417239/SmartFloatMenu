#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

#pragma mark - 配置key
static NSString *const kConfigText1 = @"SFM_configText1";
static NSString *const kConfigText2 = @"SFM_configText2";
static NSString *const kConfigEnabled = @"SFM_configEnabled";

#pragma mark - 全局状态
static BOOL g_isExecuting = NO;
static BOOL g_isCollapsed = NO;
static UIView *g_floatMenu = nil;
static UIButton *g_execBtn = nil;
static UILabel *g_timeLabel = nil;
static UIView *g_secondaryView = nil;
static UITextField *g_textField1 = nil;
static UITextField *g_textField2 = nil;
static UIButton *g_saveBtn = nil;
static NSTimer *g_timeTimer = nil;
static dispatch_source_t g_scanTimer = nil;
static UILongPressGestureRecognizer *g_longPress = nil;
static BOOL g_isVerticalTime = NO;

// 调试可视化
static UIView *g_debugOverlay = nil;
static UIView *g_debugRect = nil;
static UIView *g_debugTapDot = nil;

#pragma mark - PassthroughWindow（点击穿透，只有菜单接收触摸）
@interface PassthroughWindow : UIWindow
@property (nonatomic, weak) UIView *menuView;
@end
@implementation PassthroughWindow
- (UIView *)hitTest:(CGPoint)pt withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:pt withEvent:event];
    if (hit == self.menuView || [hit isDescendantOfView:self.menuView]) return hit;
    return nil;
}
@end

#pragma mark - 颜色判断
static BOOL isOrangeColor(UIColor *color) {
    if (!color) return NO;
    CGFloat r, g, b, a;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return r > 0.7 && g > 0.28 && g < 0.52 && b < 0.42 && (r - g) > 0.25;
}

#pragma mark - 时间
static NSString *getTimeString(void) {
    NSDate *now = [NSDate date];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    [fmt setDateFormat:@"HH:mm:ss"];
    return [fmt stringFromDate:now];
}
static void updateTimeLabel(void) {
    if (!g_timeLabel) return;
    NSString *timeStr = getTimeString();
    if (g_isVerticalTime) {
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

#pragma mark - 截图取色
static UIColor *getColorAtPoint(CGPoint point) {
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && !w.isHidden) { keyWindow = w; break; }
    }
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.001 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [hitView touchesEnded:[NSSet setWithObject:touch] withEvent:event];
    });
}

#pragma mark - 调试可视化
static void ensureDebugOverlay(void) {
    if (g_debugOverlay) return;
    UIWindow *keyWindow = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && !w.isHidden) { keyWindow = w; break; }
    }
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

#pragma mark - 收纳/展开
static void collapseToSide(void) {
    if (g_isCollapsed || !g_floatMenu) return;
    g_isCollapsed = YES;
    g_isVerticalTime = YES;
    UIWindow *window = g_floatMenu.window;
    if (!window) return;
    CGFloat screenW = window.bounds.size.width;
    CGFloat screenH = window.bounds.size.height;
    
    CGPoint timeCenterInWindow = [g_floatMenu convertPoint:g_timeLabel.center toView:window];
    [g_timeLabel removeFromSuperview];
    [window addSubview:g_timeLabel];
    g_timeLabel.center = timeCenterInWindow;
    
    g_floatMenu.hidden = YES;
    BOOL isLeft = (g_floatMenu.center.x < screenW/2);
    g_timeLabel.hidden = NO;
    g_timeLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
    g_timeLabel.textColor = [UIColor whiteColor];
    g_timeLabel.layer.cornerRadius = 4;
    g_timeLabel.layer.masksToBounds = YES;
    g_timeLabel.bounds = CGRectMake(0, 0, 70, 20);
    g_timeLabel.transform = CGAffineTransformMakeRotation(isLeft ? M_PI_2 : -M_PI_2);
    CGFloat targetY = MIN(MAX(g_floatMenu.center.y, 120), screenH - 120);
    g_timeLabel.center = CGPointMake(isLeft ? 12 : screenW - 12, targetY);
    [window bringSubviewToFront:g_timeLabel];
    updateTimeLabel();
}

static void expandFromSide(void) {
    if (!g_isCollapsed || !g_floatMenu) return;
    g_isCollapsed = NO;
    g_isVerticalTime = NO;
    UIWindow *window = g_floatMenu.window;
    if (!window) return;
    CGFloat screenW = window.bounds.size.width;
    g_timeLabel.transform = CGAffineTransformIdentity;
    g_floatMenu.hidden = NO;
    CGFloat menuX = (g_timeLabel.center.x < screenW/2) ? 35 : screenW - 35;
    CGFloat menuY = g_timeLabel.center.y;
    g_floatMenu.center = CGPointMake(menuX, menuY);
    [g_timeLabel removeFromSuperview];
    [g_floatMenu addSubview:g_timeLabel];
    g_timeLabel.frame = CGRectMake(-5, g_floatMenu.bounds.size.height + 2, 60, 18);
    g_timeLabel.backgroundColor = [UIColor clearColor];
    g_timeLabel.textColor = [UIColor blackColor];
    g_timeLabel.layer.cornerRadius = 0;
    g_timeLabel.layer.masksToBounds = NO;
    updateTimeLabel();
}

static NSTimer *g_hideTimer = nil;
static void resetHideTimer(void) {
    if (g_hideTimer) {
        [g_hideTimer invalidate];
        g_hideTimer = nil;
    }
    g_hideTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:NO block:^(NSTimer *t) {
        collapseToSide();
    }];
}

#pragma mark - 创建菜单
static UIView *createFloatMenu(void) {
    CGFloat menuSize = 50;
    UIView *menu = [[UIView alloc] initWithFrame:CGRectMake(0, 0, menuSize, menuSize)];
    menu.backgroundColor = [UIColor clearColor];
    menu.layer.cornerRadius = 12;
    menu.layer.borderWidth = 1.5;
    menu.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
    
    g_execBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    g_execBtn.frame = CGRectMake(0, 0, menuSize, menuSize);
    g_execBtn.titleLabel.font = [UIFont systemFontOfSize:22];
    [g_execBtn setTitle:@"⏸" forState:UIControlStateNormal];
    g_execBtn.layer.cornerRadius = 12;
    g_execBtn.layer.masksToBounds = YES;
    [menu addSubview:g_execBtn];
    
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
    sec.backgroundColor = [UIColor colorWithRed:1.0 green:0.95 blue:0.2 alpha:0.95];
    sec.layer.cornerRadius = 12;
    sec.layer.borderWidth = 1;
    sec.layer.borderColor = [UIColor orangeColor].CGColor;
    sec.hidden = YES;
    
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
+ (void)execBtnTapped:(UIButton *)sender;
+ (void)saveBtnTapped;
+ (void)handleLongPress:(UILongPressGestureRecognizer *)gesture;
+ (void)handlePan:(UIPanGestureRecognizer *)pan;
+ (void)timeLabelTapped;
+ (void)handleTimePan:(UIPanGestureRecognizer *)pan;
@end

@implementation SFMHandler

+ (void)execBtnTapped:(UIButton *)sender {
    g_isExecuting = !g_isExecuting;
    NSLog(@"[SFM] 执行状态切换: %@", g_isExecuting ? @"开启" : @"暂停");
    if (g_isExecuting) {
        [g_execBtn setTitle:@"▶️" forState:UIControlStateNormal];
        g_execBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:0.5];
        if (g_scanTimer) dispatch_source_cancel(g_scanTimer);
        g_scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(g_scanTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 0.01 * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(g_scanTimer, ^{
            scanAndClick();
        });
        dispatch_resume(g_scanTimer);
    } else {
        [g_execBtn setTitle:@"⏸" forState:UIControlStateNormal];
        g_execBtn.backgroundColor = [UIColor colorWithRed:0.7 green:0.2 blue:0.2 alpha:0.4];
        if (g_scanTimer) { dispatch_source_cancel(g_scanTimer); g_scanTimer = nil; }
        clearDebugMarks();
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
    g_secondaryView.hidden = YES;
    [g_textField1 resignFirstResponder];
    [g_textField2 resignFirstResponder];
    resetHideTimer();
}

+ (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        g_secondaryView.hidden = NO;
        UIWindow *window = g_floatMenu.window;
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
    UIWindow *window = view.window;
    CGPoint translation = [pan translationInView:window];
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        view.center = CGPointMake(view.center.x + translation.x, view.center.y + translation.y);
        [pan setTranslation:CGPointZero inView:window];
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
    expandFromSide();
    resetHideTimer();
}

+ (void)handleTimePan:(UIPanGestureRecognizer *)pan {
    if (!g_isCollapsed) return;
    UIView *view = pan.view;
    UIWindow *window = view.window;
    CGPoint translation = [pan translationInView:window];
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        CGFloat newY = view.center.y + translation.y;
        CGFloat screenH = window.bounds.size.height;
        newY = MAX(80, MIN(screenH - 80, newY));
        view.center = CGPointMake(view.center.x, newY);
        [pan setTranslation:CGPointZero inView:window];
    } else if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        CGFloat screenW = window.bounds.size.width;
        CGFloat targetX = (view.center.x < screenW/2) ? 14 : screenW - 14;
        [UIView animateWithDuration:0.25 animations:^{
            view.center = CGPointMake(targetX, view.center.y);
        }];
    }
}

@end

#pragma mark - OverlayManager
@interface OverlayManager : NSObject
@property (nonatomic, strong) PassthroughWindow *overlayWindow;
@end
@implementation OverlayManager

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(buildOverlay) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

- (UIWindowScene *)activeScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:UIWindowScene.class]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

- (void)buildOverlay {
    if (self.overlayWindow) return;
    UIWindowScene *scene = [self activeScene];
    if (!scene) return;
    CGRect screen = UIScreen.mainScreen.bounds;
    
    self.overlayWindow = [[PassthroughWindow alloc] initWithWindowScene:scene];
    self.overlayWindow.frame = screen;
    self.overlayWindow.backgroundColor = UIColor.clearColor;
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 5;
    self.overlayWindow.hidden = NO;
    UIViewController *root = [UIViewController new];
    self.overlayWindow.rootViewController = root;
    
    g_floatMenu = createFloatMenu();
    g_floatMenu.center = CGPointMake(screen.size.width - 35, 150);
    [root.view addSubview:g_floatMenu];
    self.overlayWindow.menuView = g_floatMenu;
    
    g_secondaryView = createSecondaryView();
    [root.view addSubview:g_secondaryView];
    
    [g_execBtn addTarget:[SFMHandler class] action:@selector(execBtnTapped:) forControlEvents:UIControlEventTouchUpInside];
    [g_saveBtn addTarget:[SFMHandler class] action:@selector(saveBtnTapped) forControlEvents:UIControlEventTouchUpInside];
    
    g_longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:[SFMHandler class] action:@selector(handleLongPress:)];
    g_longPress.minimumPressDuration = 0.6;
    [g_floatMenu addGestureRecognizer:g_longPress];
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[SFMHandler class] action:@selector(handlePan:)];
    [g_floatMenu addGestureRecognizer:pan];
    
    UITapGestureRecognizer *timeTap = [[UITapGestureRecognizer alloc] initWithTarget:[SFMHandler class] action:@selector(timeLabelTapped)];
    [g_timeLabel addGestureRecognizer:timeTap];
    g_timeLabel.userInteractionEnabled = YES;
    
    UIPanGestureRecognizer *timePan = [[UIPanGestureRecognizer alloc] initWithTarget:[SFMHandler class] action:@selector(handleTimePan:)];
    [g_timeLabel addGestureRecognizer:timePan];
    
    g_timeTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        updateTimeLabel();
    }];
    
    BOOL savedEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:kConfigEnabled];
    if (savedEnabled) {
        g_isExecuting = YES;
        [g_execBtn setTitle:@"▶️" forState:UIControlStateNormal];
        g_execBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:0.5];
        g_scanTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(g_scanTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 0.01 * NSEC_PER_SEC, 0);
        dispatch_source_set_event_handler(g_scanTimer, ^{
            scanAndClick();
        });
        dispatch_resume(g_scanTimer);
    } else {
        g_execBtn.backgroundColor = [UIColor colorWithRed:0.7 green:0.2 blue:0.2 alpha:0.4];
    }
    
    resetHideTimer();
    NSLog(@"[SFM] 悬浮菜单已安装（PassthroughWindow方式）");
}

@end

#pragma mark - 入口
static OverlayManager *manager;
__attribute__((constructor))
static void init_tweak() {
    manager = [OverlayManager new];
}
