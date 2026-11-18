# -*- coding: utf-8 -*-
import io, sys

P = r"d:\woekbude\2026-11-15-11-58-50\Safari16Enhance\Tweak.xm"
src = io.open(P, encoding="utf-8").read()
lines = src.split("\n")

start = None
for i, l in enumerate(lines):
    if l.startswith("// MARK: - 0.13.5 底部地址栏"):
        start = i
        break
if start is None:
    print("START NOT FOUND"); sys.exit(1)

end = None
for i, l in enumerate(lines):
    if l.startswith("static void SPEHInstallURLBarSwipeHooks(void)"):
        end = i
        break
if end is None:
    print("END NOT FOUND"); sys.exit(1)

new = u'''// MARK: - 底部地址栏：精准命中真实控件（0.13.8）
//
// 以下结构全部来自真机运行时视图树 dump（0.13.7 日志），不是猜的：
//   d=0 SFCapsuleView            f=(20,807,390,44)  gr=[]
//   d=1 SFCapsuleCollectionView  f=(0,0,430,932)    gr=[UITapGestureRecognizer,
//                                                      UIPanGestureRecognizer,
//                                                      UIPanGestureRecognizer]
//   d=2 UIView                   f=(0,0,430,932)    gr=[UIPanGestureRecognizer]
//
// 两条路径的真实归属，全部按「类名精确匹配」处理，不用坐标位置兜底：
//   ① 左右滑切页 = SFCapsuleCollectionView 自身的横向滚动（它继承 UIScrollView）
//      ⇒ 直接 scrollEnabled=NO。只禁用户拖动，程序化切页和上拉展开都不受影响。
//   ② 单击切页   = 挂在同一个 SFCapsuleCollectionView 上的 UITapGestureRecognizer
//      ⇒ 识别瞬间判断落点，落在居中胶囊（当前页）之外就置 Failed，action 不执行。
//      （0.13.5 曾 hook UIGestureRecognizer 的 touchesBegan，日志零命中 —— 手势识别器
//        不走 UIResponder 的 touchesBegan，该路线已证伪并删除。）
//
// 宽度保持系统原样：不改 frame、不 hidden，左右照常露出。

static Class gCapsuleCVClass = NULL;    // SFCapsuleCollectionView
static Class gCapsuleViewClass = NULL;  // SFCapsuleView
static IMP gOrigCapCVLayout = NULL;
static IMP gOrigTapSetState = NULL;

// 判定这次 tap 是否落在「非居中的侧边胶囊」上。
// 用真实子视图几何：触点落在哪个 SFCapsuleView 内，就看那个胶囊中心离屏幕中心多远。
static BOOL SPEHTapHitsSideCapsule(UIGestureRecognizer *gr, UIView *cv)
{
	UIWindow *win = [cv window];
	if (!win) return NO;
	CGPoint p = [gr locationInView:win];
	CGFloat winW = [win bounds].size.width;
	if (winW <= 0) return NO;
	BOOL onCenter = NO, onSide = NO;
	for (UIView *s in [cv subviews]) {
		if (gCapsuleViewClass && ![s isKindOfClass:gCapsuleViewClass]) continue;
		CGRect wf = [s convertRect:[s bounds] toView:win];
		if (wf.size.width <= 0 || wf.size.height <= 0) continue;
		if (!CGRectContainsPoint(wf, p)) continue;
		if (fabs(CGRectGetMidX(wf) - winW / 2.0) < winW * 0.15) onCenter = YES;
		else onSide = YES;
	}
	return (onSide && !onCenter);
}

// ② 单击：tap 进入 Began 之前判定，命中侧边胶囊就改置 Failed（action 不执行、不切页）
static void SPEHTapSetStateHook(id self, SEL _cmd, NSInteger state)
{
	if (state == 1 && gCapsuleCVClass && SPEHURLBarSwipeKillEnabled()) {
		@try {
			UIGestureRecognizer *gr = (UIGestureRecognizer *)self;
			if ([gr isKindOfClass:[UITapGestureRecognizer class]]) {
				UIView *host = [gr view];
				if (host && object_getClass(host) == gCapsuleCVClass &&
					SPEHTapHitsSideCapsule(gr, host)) {
					SPEHLog(@"[urlswipe] 精准拦截 侧边胶囊单击 -> tap Failed");
					state = 5;   // UIGestureRecognizerStateFailed
				}
			}
		} @catch (NSException *e) { }
	}
	if (gOrigTapSetState) ((void (*)(id, SEL, NSInteger))gOrigTapSetState)(self, _cmd, state);
}

// ① 滑动：SFCapsuleCollectionView 就是胶囊分页容器，关掉它的用户滚动即可
static void SPEHCapsuleCVLayoutHook(id self, SEL _cmd)
{
	if (gOrigCapCVLayout) ((void (*)(id, SEL))gOrigCapCVLayout)(self, _cmd);

	if (!SPEHURLBarSwipeKillEnabled()) return;
	UIScrollView *cv = (UIScrollView *)self;
	@try {
		if (cv.scrollEnabled) {
			cv.scrollEnabled = NO;
			SPEHLog(@"[urlswipe] 精准禁用胶囊横向滚动 contentW=%.0f boundsW=%.0f",
					cv.contentSize.width, cv.bounds.size.width);
		}
	} @catch (NSException *e) { }
}
'''

out = lines[:start] + new.split("\n") + lines[end:]
io.open(P, "w", encoding="utf-8", newline="\n").write("\n".join(out))
print("replaced lines %d..%d with %d lines" % (start + 1, end, len(new.split('\n'))))
