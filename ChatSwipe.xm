// ChatSwipe + KbDock —— 由 Safari16Enhance 工程统一编译（0.15.0 起并入）
//
//   A. ChatSwipe —— 聊天输入框左滑清空 / 右滑粘贴 + 编辑菜单精简（只留 全选/复制/粘贴）
//   B. KbDock    —— 键盘底部快捷条（全选 / 复制 / 粘贴），自绘双点图标，自适应深浅色
//
// 与独立 chatswipe 仓库（v1.7.0）的差别仅在交付方式：不再由 TrollFools 注入单 dylib，
// 改为 roothide 包内 ChatSwipe.dylib + ChatSwipe.plist（Filter 指定目标 App），
// 由 ElleKit 按 Filter 注入。功能逻辑与阈值全部保持原样，未做改写。
//
// 日志：写目标 App 自身沙盒 Documents/ChatSwipe.log（不是 TMPDIR、不是 /var/tmp），
//       仅 withlog 版输出；nolog 版编译期剥离（-DSPEH_NO_LOG）。

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <math.h>
#import <time.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <sys/stat.h>

// ---- 日志（受 SPEH_NO_LOG 控制） ----
#ifndef SPEH_NO_LOG
static const char *CSLogPath(void)
{
	static char path[512];
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		// 注入的是普通 App 进程，HOME 即其沙盒容器根，Documents 一定可写
		const char *home = getenv("HOME");
		if (!home || !home[0]) { path[0] = '\0'; return; }
		snprintf(path, sizeof(path), "%s/Documents/ChatSwipe.log", home);
	});
	return path;
}

static void CSLog(NSString *fmt, ...)
{
	const char *p = CSLogPath();
	if (!p || !p[0]) return;

	// 超 1MB 直接轮转，避免长期使用撑大沙盒
	struct stat st;
	if (stat(p, &st) == 0 && st.st_size > 1024 * 1024) {
		NSString *old = [NSString stringWithUTF8String:p];
		[[NSFileManager defaultManager] removeItemAtPath:[old stringByAppendingString:@".1"] error:nil];
		[[NSFileManager defaultManager] moveItemAtPath:old
											   toPath:[old stringByAppendingString:@".1"] error:nil];
	}

	va_list ap;
	va_start(ap, fmt);
	NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);

	time_t t = time(NULL);
	struct tm tmv;
	localtime_r(&t, &tmv);
	char ts[32];
	strftime(ts, sizeof(ts), "%m-%d %H:%M:%S", &tmv);

	FILE *f = fopen(p, "a");
	if (f) {
		fprintf(f, "[%s] %s\n", ts, msg.UTF8String ?: "");
		fclose(f);
	}
}
#else
#define CSLog(...) do {} while (0)
#endif

// =====================================================================
//  A. ChatSwipe —— 滑动 + 编辑菜单精简（原作者代码，原样保留）
// =====================================================================

// ---- 配置（可选 /var/mobile/Documents/chatswipe.plist） ----
static BOOL     gEnabled      = YES;   // 总开关
static BOOL     gClearEnabled = YES;   // 左滑清空
static BOOL     gPasteEnabled = YES;   // 右滑粘贴
static CGFloat  gThreshold    = 45.0;  // 触发所需最小水平位移(pt)
static BOOL     gMenuFilterEnabled = YES; // 编辑菜单精简总开关（只留 全选/复制/粘贴）

// ---- 编辑菜单三件套 ----
static BOOL chatmenu_isAllowedAction(SEL action) {
    if (action == @selector(selectAll:)) return YES;
    if (action == @selector(copy:))      return YES;
    if (action == @selector(paste:))     return YES;
    return NO;
}

static void chatswipe_loadConfig() {
    @try {
        NSString *path = @"/var/mobile/Documents/chatswipe.plist";
        NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:path];
        if (cfg) {
            if ([cfg objectForKey:@"Enabled"])          gEnabled          = [[cfg objectForKey:@"Enabled"]          boolValue];
            if ([cfg objectForKey:@"ClearEnabled"])      gClearEnabled     = [[cfg objectForKey:@"ClearEnabled"]      boolValue];
            if ([cfg objectForKey:@"PasteEnabled"])      gPasteEnabled     = [[cfg objectForKey:@"PasteEnabled"]      boolValue];
            if ([cfg objectForKey:@"Threshold"])         gThreshold        = [[cfg objectForKey:@"Threshold"]         floatValue];
            if ([cfg objectForKey:@"MenuFilterEnabled"]) gMenuFilterEnabled = [[cfg objectForKey:@"MenuFilterEnabled"] boolValue];
            CSLog(@"config 已读取 Enabled=%d clear=%d paste=%d menu=%d th=%.0f",
                  gEnabled, gClearEnabled, gPasteEnabled, gMenuFilterEnabled, gThreshold);
        }
    } @catch (id e) {}
}

// ---- 共享 pan delegate ----
@interface ChatSwipePanDelegate : NSObject <UIGestureRecognizerDelegate>
@end
@implementation ChatSwipePanDelegate
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
@end
static ChatSwipePanDelegate *gPanDelegate = nil;

// ---- 给输入框挂 pan 手势（仅挂一次） ----
static void chatswipe_attachIfNeeded(UIView *view) {
    if (!gEnabled || !view) return;
    if ([view isKindOfClass:[UITextView class]]) {
        if (!((UITextView *)view).isEditable) return;
    } else if ([view isKindOfClass:[UITextField class]]) {
        UITextField *tf = (UITextField *)view;
        if (tf.secureTextEntry || !tf.enabled) return;
    } else {
        return;
    }
    static const void *kAttached = &kAttached;
    if (objc_getAssociatedObject(view, kAttached)) return;
    objc_setAssociatedObject(view, kAttached, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:view action:@selector(chatswipe_handlePan:)];
    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan  = NO;
    if (!gPanDelegate) gPanDelegate = [[ChatSwipePanDelegate alloc] init];
    pan.delegate = gPanDelegate;
    [view addGestureRecognizer:pan];
}

// ---- 动作：清空 / 粘贴 ----
static void chatswipe_clear(UIView *view) {
    @try {
        if ([view isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)view;
            UITextRange *all = [tv textRangeFromPosition:tv.beginningOfDocument toPosition:tv.endOfDocument];
            if (all) [tv replaceRange:all withText:@""];
        } else if ([view isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)view;
            UITextRange *all = [tf textRangeFromPosition:tf.beginningOfDocument toPosition:tf.endOfDocument];
            if (all) [tf replaceRange:all withText:@""];
            [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        }
    } @catch (id e) {}
}

static void chatswipe_paste(UIView *view) {
    @try {
        NSString *pb = [UIPasteboard generalPasteboard].string;
        if (!pb || pb.length == 0) return;
        if ([view isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)view;
            UITextRange *r = tv.selectedTextRange
                ?: [tv textRangeFromPosition:tv.endOfDocument toPosition:tv.endOfDocument];
            if (r) [tv replaceRange:r withText:pb];
        } else if ([view isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)view;
            UITextRange *r = tf.selectedTextRange
                ?: [tf textRangeFromPosition:tf.endOfDocument toPosition:tf.endOfDocument];
            if (r) [tf replaceRange:r withText:pb];
            [tf sendActionsForControlEvents:UIControlEventEditingChanged];
        }
    } @catch (id e) {}
}

// ---- pan 回调 ----
@interface UIView (ChatSwipe)
- (void)chatswipe_handlePan:(UIPanGestureRecognizer *)pan;
@end
@implementation UIView (ChatSwipe)
- (void)chatswipe_handlePan:(UIPanGestureRecognizer *)pan {
    if (pan.state != UIGestureRecognizerStateEnded) return;
    CGPoint t = [pan translationInView:self];
    CGFloat dx = t.x, dy = t.y;
    if (fabs(dx) <= fabs(dy)) return;
    if (fabs(dx) < gThreshold) return;
    if (dx < 0) { if (gClearEnabled)  { CSLog(@"左滑清空 dx=%.0f", dx); chatswipe_clear(self); } }
    else        { if (gPasteEnabled)  { CSLog(@"右滑粘贴 dx=%.0f", dx); chatswipe_paste(self); } }
}
@end

// ---- 编辑菜单三件套 Hook ----
%hook UITextView
- (BOOL)becomeFirstResponder {
    BOOL r = %orig;
    if (r) { chatswipe_attachIfNeeded(self); }
    return r;
}
- (BOOL)resignFirstResponder {
    return %orig;
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) { chatswipe_attachIfNeeded(self); }
}
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (!gMenuFilterEnabled) return %orig;
    if (chatmenu_isAllowedAction(action)) return YES;
    return NO;
}
%end

%hook UITextField
- (BOOL)becomeFirstResponder {
    BOOL r = %orig;
    if (r) { chatswipe_attachIfNeeded(self); }
    return r;
}
- (BOOL)resignFirstResponder {
    return %orig;
}
- (void)didMoveToWindow {
    %orig;
    if (self.window) { chatswipe_attachIfNeeded(self); }
}
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (!gMenuFilterEnabled) return %orig;
    // 密码框不强制复制/全选（防泄密），但粘贴仍允许
    if ((action == @selector(copy:) || action == @selector(selectAll:)) && self.secureTextEntry) return %orig;
    if (chatmenu_isAllowedAction(action)) return YES;
    return NO;
}
%end

// =====================================================================
//  B. KbDock —— 键盘底部快捷条（全选 / 复制 / 粘贴）
//  基于 MyDock(com.ban.mydock) 作者 1.0 源码改造：
//   ① 删除「撤销」「收起键盘」 ② 新增「复制」 ③ 自绘「双点」图标（每图标 2 个极小点，靠摆放方向区分）
//   ④ tintColor=labelColor → 自适应系统深浅色
//  Hook: UIKeyboardDockView -layoutSubviews
// =====================================================================

@interface UIKeyboardDockView : UIView
- (void)kb_haptic;
- (void)kb_selectAll;
- (void)kb_copy;
- (void)kb_paste;
@end

// ---- 自绘点状图标 ----
// 三个图标都只用 2 个点，靠「摆放方向」区分；点径 ≈ 虚线的一个点（1.5pt）
// 画布 26x26，两点居中对称摆放
static CGFloat const kDotD   = 1.5;   // 点直径（极小）
static CGFloat const kDotGap = 5.5;   // 两点中心间距

// kind: 0=一上一下  1=左高右低(左上+右下)  2=左低右高(右上+左下)
static UIImage *KbDotsIcon(NSInteger kind) {
    static UIImage *cache[3] = {nil, nil, nil};   // 性能：三种图标各只渲染一次，键盘复用时不再重绘
    if (kind >= 0 && kind < 3 && cache[kind]) return cache[kind];

    const CGFloat side = 26.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:fmt];

    UIImage *img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[UIColor blackColor] setFill];

        CGFloat c = side / 2.0;
        CGFloat h = kDotGap / 2.0;
        CGPoint p1, p2;
        if (kind == 0) {          // 一上一下
            p1 = CGPointMake(c, c - h);         p2 = CGPointMake(c, c + h);
        } else if (kind == 1) {   // 左高右低：左上 + 右下
            p1 = CGPointMake(c - h, c - h);     p2 = CGPointMake(c + h, c + h);
        } else {                  // 左低右高：右上 + 左下
            p1 = CGPointMake(c + h, c - h);     p2 = CGPointMake(c - h, c + h);
        }

        UIBezierPath *dot1 = [UIBezierPath bezierPathWithOvalInRect:
            CGRectMake(p1.x - kDotD / 2.0, p1.y - kDotD / 2.0, kDotD, kDotD)];
        UIBezierPath *dot2 = [UIBezierPath bezierPathWithOvalInRect:
            CGRectMake(p2.x - kDotD / 2.0, p2.y - kDotD / 2.0, kDotD, kDotD)];
        [dot1 fill];
        [dot2 fill];
    }];

    UIImage *out = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    if (kind >= 0 && kind < 3) cache[kind] = out;   // 存入缓存
    return out;
}

// ---- 按钮 ----
static UIButton *KbMakeButton(UIImage *icon, id target, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setImage:icon forState:UIControlStateNormal];
    b.tintColor = [UIColor labelColor];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b.widthAnchor  constraintEqualToConstant:44].active = YES;  // 热区 44x44（点再小也点得准）
    [b.heightAnchor constraintEqualToConstant:44].active = YES;
    [b addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

%hook UIKeyboardDockView

- (void)layoutSubviews {
    %orig;

    if ([self viewWithTag:9999]) return;  // 只加一次

    UIStackView *stackView = [[UIStackView alloc] initWithFrame:CGRectZero];
    stackView.tag = 9999;
    stackView.axis = UILayoutConstraintAxisHorizontal;
    stackView.distribution = UIStackViewDistributionEqualSpacing;
    stackView.alignment = UIStackViewAlignmentCenter;
    stackView.translatesAutoresizingMaskIntoConstraints = NO;

    // 按钮位置/功能不变（左→右 = 全选 / 复制 / 粘贴）；只调「点」的摆放：
    //   全选 = 左低右高(2) · 复制 = 一上一下(0) · 粘贴 = 左高右低(1) → 视觉呈 / | \ 对称
    [stackView addArrangedSubview:KbMakeButton(KbDotsIcon(2), self, @selector(kb_selectAll))]; // 左低右高
    [stackView addArrangedSubview:KbMakeButton(KbDotsIcon(0), self, @selector(kb_copy))];      // 一上一下
    [stackView addArrangedSubview:KbMakeButton(KbDotsIcon(1), self, @selector(kb_paste))];     // 左高右低

    [self addSubview:stackView];

    [NSLayoutConstraint activateConstraints:@[
        [stackView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [stackView.bottomAnchor   constraintEqualToAnchor:self.bottomAnchor constant:-23],
        [stackView.widthAnchor    constraintEqualToAnchor:self.widthAnchor multiplier:0.55],
    ]];
    CSLog(@"KbDock 键盘条已装配 %@", NSStringFromClass(object_getClass(self)));
}

%new
- (void)kb_haptic {
    // 性能：复用同一个触感发生器，避免每次点击都新建 + prepare 的开销
    static UIImpactFeedbackGenerator *g = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [g prepare];
    });
    [g impactOccurred];
}

%new
- (void)kb_selectAll {
    [self kb_haptic];
    CSLog(@"键盘条 全选并复制");
    UIApplication *app = [UIApplication sharedApplication];
    [app sendAction:@selector(selectAll:) to:nil from:nil forEvent:nil];
    // 全选后自动复制：延后一个 runloop，确保 selection 已提交（部分输入框的 selectAll: 为异步提交）
    dispatch_async(dispatch_get_main_queue(), ^{
        [app sendAction:@selector(copy:) to:nil from:nil forEvent:nil];
    });
}

%new
- (void)kb_copy {
    [self kb_haptic];
    CSLog(@"键盘条 复制");
    [[UIApplication sharedApplication] sendAction:@selector(copy:) to:nil from:nil forEvent:nil];
}

%new
- (void)kb_paste {
    [self kb_haptic];
    CSLog(@"键盘条 粘贴");
    [[UIApplication sharedApplication] sendAction:@selector(paste:) to:nil from:nil forEvent:nil];
}

%end

%ctor {
    chatswipe_loadConfig();
    CSLog(@"ChatSwipe+KbDock 0.15.0 已加载 pid=%d bundle=%@",
          getpid(), [[NSBundle mainBundle] bundleIdentifier]);
}
