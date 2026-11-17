// Safari16Enhance 0.12.8 - iOS 16 Safari 增强
//
// 实测结论链（每条都来自真机日志，不是推测）：
//   阅读器：三个真实方法已确认，白名单精准命中有效
//   弹窗：真身是 Safari 自绘的 SFDialogView（挂在 _SFWebView 上），
//        不是 UIAlertController、不走 presentViewController —— 0.4.0 按文本精准拆除，实测生效
//   返回：iOS 16 WKPreferences 无任何 bfcache 开关（已全量 dump 确认），
//        左滑手势返回有缓存、按钮返回重载 → 差别在调用路径
//
// 0.9.0 变更（教训汇总）：
//   1. 删除自定义搜索引擎全部代码：设置页引擎列表由 Preferences 进程渲染，
//      注入进程改不到它；槽位替换虽能用但元宝页面本身卡，老板决定弃用，回归系统默认引擎。
//   2. 删除「网页唤起 App（自定义 scheme）」全部代码：
//      在 webView:decidePolicyForNavigationAction:preferences:decisionHandler: 上 hook
//      并回调 decisionHandler，导致 CFRetain 在 PAC 失效地址上 SIGSEGV（真机 5 份 IPS 实证）。
//      ⇒ 铁律：**永不 hook WebKit 导航决策类 delegate 并手工回调 decisionHandler**。
//   3. 保留 AppLink 层（WBSAppLink / LSAppLink 返回 nil），这层只读不回调，安全。
//
// 原则：hook 只挂具体类，先查存在性，全部 @try 包裹，绝不让 Safari 崩

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <unistd.h>
#import <math.h>
#import <dlfcn.h>

#define SPEH_VERSION "0.12.8"

// CFSTR 只接受 C 字符串字面量，故偏好域用 C 字符串宏
#define SPEH_PREF_DOMAIN_CSTR "com.huhansibuxin.safari16enhance"
#define SPEH_LOG_NAME    @"Safari16Enhance.log"

// MARK: - 日志（写入 Safari 容器 Documents）
// SPEH_NO_LOG：编译期彻底剥离日志变体（无队列、无文件、无日志字符串进二进制）
#ifndef SPEH_NO_LOG

static BOOL SPEHPrepareDirectory(NSString *dir)
{
	if (dir.length == 0) return NO;

	NSFileManager *fm = [NSFileManager defaultManager];
	BOOL isDir = NO;
	if (![fm fileExistsAtPath:dir isDirectory:&isDir]) {
		NSDictionary *attrs = @{ NSFileProtectionKey : NSFileProtectionCompleteUntilFirstUserAuthentication };
		if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:attrs error:nil]) return NO;
	} else if (!isDir) {
		return NO;
	}

	[fm setAttributes:@{ NSFileProtectionKey : NSFileProtectionCompleteUntilFirstUserAuthentication }
		   ofItemAtPath:dir error:nil];
	[[NSURL fileURLWithPath:dir] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];

	NSString *probe = [dir stringByAppendingPathComponent:@".speh_write_test"];
	BOOL ok = [[@"1" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:probe atomically:NO];
	if (ok) [fm removeItemAtPath:probe error:nil];
	return ok;
}

static NSString *SPEHLogDirectory(void)
{
	static NSString *dir = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableArray *candidates = [NSMutableArray array];
		NSString *home = NSHomeDirectory();
		if (home.length) [candidates addObject:[home stringByAppendingPathComponent:@"Documents"]];
		NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		if (docs.count) [candidates addObject:docs.firstObject];
		if (home.length) [candidates addObject:[home stringByAppendingPathComponent:@"Library/Caches"]];
		if (home.length) [candidates addObject:[home stringByAppendingPathComponent:@"tmp"]];

		for (NSString *cand in candidates) {
			if (SPEHPrepareDirectory(cand)) { dir = [cand copy]; break; }
		}
		if (!dir) dir = [NSTemporaryDirectory() copy];
	});
	return dir;
}

static NSString *SPEHLogPath(void)
{
	static NSString *path = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		path = [SPEHLogDirectory() stringByAppendingPathComponent:SPEH_LOG_NAME];
	});
	return path;
}

static dispatch_queue_t SPEHLogQueue(void)
{
	static dispatch_queue_t q = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		q = dispatch_queue_create("com.huhansibuxin.speh.log", DISPATCH_QUEUE_SERIAL);
	});
	return q;
}

static void SPEHLog(NSString *fmt, ...)
{
	va_list args;
	va_start(args, fmt);
	NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
	va_end(args);

	dispatch_async(SPEHLogQueue(), ^{
		// 0.9.8 优化：NSDateFormatter 创建昂贵，缓存复用；且全部在串行队列内访问，天然线程安全
		static NSDateFormatter *df = nil;
		static dispatch_once_t onceFmt;
		dispatch_once(&onceFmt, ^{
			df = [[NSDateFormatter alloc] init];
			df.dateFormat = @"MM-dd HH:mm:ss.SSS";
		});
		NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];

		static NSUInteger writeCount = 0;
		NSString *path = SPEHLogPath();
		NSFileManager *fm = [NSFileManager defaultManager];

		writeCount++;
		if (writeCount % 200 == 0) {
			NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
			if ([attrs fileSize] > 2 * 1024 * 1024) {
				NSString *old = [path stringByAppendingString:@".1"];
				[fm removeItemAtPath:old error:nil];
				[fm moveItemAtPath:path toPath:old error:nil];
			}
		}

		NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
		if (!fh) {
			[line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
		} else {
			@try {
				[fh seekToEndOfFile];
				[fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
				[fh closeFile];
			} @catch (NSException *e) { }
		}
	});
}

#else   // SPEH_NO_LOG —— 日志调用整体编译掉，路径函数也不存在
#define SPEHLog(...) do { } while (0)
#endif  // SPEH_NO_LOG

// MARK: - 配置

static BOOL SPEHBoolPref(NSString *key, BOOL def)
{
	CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(SPEH_PREF_DOMAIN_CSTR));
	if (!v) return def;
	BOOL r = def;
	if (CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue((CFBooleanRef)v);
	else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
		int i = 0; CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &i); r = (i != 0);
	}
	CFRelease(v);
	return r;
}

static BOOL SPEHEnabled(void)              { return SPEHBoolPref(@"enabled", YES); }
static BOOL SPEHDialogKillEnabled(void)    { return SPEHBoolPref(@"suppressErrorAlert", YES); }
static BOOL SPEHReaderKillEnabled(void)    { return SPEHBoolPref(@"killReader", YES); }
static BOOL SPEHOpenInAppKillEnabled(void) { return SPEHBoolPref(@"killOpenInApp", YES); }
static BOOL SPEHSmartBannerKillEnabled(void) { return SPEHBoolPref(@"killSmartBanner", YES); }
static BOOL SPEHProbeEnabled(void)         { return SPEHBoolPref(@"probeEnabled", NO); }

// MARK: - 通用工具

static UIWindow *SPEHKeyWindow(void)
{
	for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
		if (![scene isKindOfClass:[UIWindowScene class]]) continue;
		if (scene.activationState != UISceneActivationStateForegroundActive) continue;
		for (UIWindow *w in ((UIWindowScene *)scene).windows) {
			if (w.isKeyWindow) return w;
		}
	}
	return [UIApplication sharedApplication].keyWindow;
}

static void SPEHShowToast(NSString *text)
{
	if (text.length == 0) return;
	dispatch_async(dispatch_get_main_queue(), ^{
		UIWindow *win = SPEHKeyWindow();
		if (!win) return;

		UILabel *label = [[UILabel alloc] init];
		label.text = text;
		label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
		label.textColor = [UIColor whiteColor];
		label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
		label.textAlignment = NSTextAlignmentCenter;
		label.numberOfLines = 0;
		label.layer.cornerRadius = 10;
		label.layer.masksToBounds = YES;
		label.userInteractionEnabled = NO;

		CGFloat maxW = win.bounds.size.width - 80;
		CGSize size = [label sizeThatFits:CGSizeMake(maxW, CGFLOAT_MAX)];
		label.frame = CGRectMake(0, 0, MIN(size.width + 28, maxW), size.height + 18);
		label.center = CGPointMake(win.bounds.size.width / 2.0, win.bounds.size.height - 150);
		label.alpha = 0.0;
		label.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin;
		[win addSubview:label];

		[UIView animateWithDuration:0.18 animations:^{
			label.alpha = 1.0;
		} completion:^(BOOL finished) {
			[UIView animateWithDuration:0.35 delay:1.6 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
				label.alpha = 0.0;
			} completion:^(BOOL done) {
				[label removeFromSuperview];
			}];
		}];
	});
}

static BOOL SPEHMethodReturnsBool(Method m)
{
	if (!m) return NO;
	const char *t = method_getTypeEncoding(m);
	if (!t) return NO;
	return (t[0] == 'B' || t[0] == 'c');
}

static void SPEHPatchInstanceMethod(Class cls, SEL sel, IMP newImp, IMP *outOld)
{
	if (!cls) return;
	Method m = class_getInstanceMethod(cls, sel);
	if (!m) return;
	MSHookMessageEx(cls, sel, newImp, outOld);
}

// MARK: - SFDialogView 精准命中（唯一保留的弹窗拦截链路）
//
// 真机日志实证：
//   class=SFDialogView frame={{0,0},{430,932}}
//   chain = _SFWebView <- TabDocumentView <- UIScrollView <- SFOrderedContainerView
// 它是 Safari 自绘的对话框（内含 SFDialogContentView / SFDialogTextView），
// 直接 addSubview 到 _SFWebView，不经 presentViewController。

static NSString *SPEHCollectDialogText(UIView *v, int depth)
{
	if (!v || depth > 8) return @"";
	NSMutableString *out = [NSMutableString string];

	if ([v isKindOfClass:[UILabel class]]) {
		NSString *t = ((UILabel *)v).text;
		if (t.length) [out appendString:t];
	} else if ([v isKindOfClass:[UITextView class]]) {
		NSString *t = ((UITextView *)v).text;
		if (t.length) [out appendString:t];
	} else if ([v isKindOfClass:[UITextField class]]) {
		NSString *t = ((UITextField *)v).text;
		if (t.length) [out appendString:t];
	}

	for (UIView *sub in v.subviews) {
		NSString *s = SPEHCollectDialogText(sub, depth + 1);
		if (s.length) [out appendString:s];
	}
	return out;
}

static BOOL SPEHTextMatchesError(NSString *text)
{
	if (text.length == 0) return NO;

	static NSArray *keywords = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		keywords = @[
			@"打不开该网页", @"打不开这个网页", @"无法打开该网页", @"无法打开这个网页",
			@"打不开网页", @"网址无效", @"地址无效", @"无法显示网页", @"找不到服务器",
			@"cannot open the page", @"can't open the page", @"cannot be opened",
			@"address is invalid", @"the URL is invalid", @"cannot connect"
		];
	});
	for (NSString *kw in keywords) {
		if ([text rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
	}
	return NO;
}

static char kSFDialogHandledKey;
static char kSFDialogLastCheckKey;

static void SPEHInspectSFDialog(UIView *dialog)
{
	if (!dialog) return;
	if (!SPEHDialogKillEnabled()) return;
	if (objc_getAssociatedObject(dialog, &kSFDialogHandledKey)) return;

	NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
	NSNumber *last = objc_getAssociatedObject(dialog, &kSFDialogLastCheckKey);
	if (last && (now - last.doubleValue) < 0.25) return;
	objc_setAssociatedObject(dialog, &kSFDialogLastCheckKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	NSString *text = SPEHCollectDialogText(dialog, 0);
	if (text.length == 0) return;
	if (!SPEHTextMatchesError(text)) return;      // 只处理目标对话框，其余一律放行

	objc_setAssociatedObject(dialog, &kSFDialogHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	SPEHLog(@"[sfdialog] 精准命中并拆除 text=%@", text);
	@try { [dialog removeFromSuperview]; } @catch (NSException *e) { }
	SPEHShowToast(@"网页无法打开");
}

static IMP gOrigSFDialogDidMoveToWindow = NULL;
static IMP gOrigSFDialogLayoutSubviews = NULL;

static void SPEHSFDialogDidMoveToWindowHook(UIView *self, SEL _cmd)
{
	if (gOrigSFDialogDidMoveToWindow) ((void (*)(id, SEL))gOrigSFDialogDidMoveToWindow)(self, _cmd);
	if (!self.window) return;
	__weak UIView *weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		SPEHInspectSFDialog(weakSelf);
	});
}

static void SPEHSFDialogLayoutSubviewsHook(UIView *self, SEL _cmd)
{
	if (gOrigSFDialogLayoutSubviews) ((void (*)(id, SEL))gOrigSFDialogLayoutSubviews)(self, _cmd);
	if (!self.window) return;
	SPEHInspectSFDialog(self);
}

static void SPEHInstallSFDialogHooks(void)
{
	if (!SPEHDialogKillEnabled()) { SPEHLog(@"[sfdialog] disabled by prefs"); return; }

	Class cls = NSClassFromString(@"SFDialogView");
	if (!cls) { SPEHLog(@"[sfdialog] SFDialogView 未找到"); return; }

	SPEHPatchInstanceMethod(cls, @selector(didMoveToWindow), (IMP)SPEHSFDialogDidMoveToWindowHook, &gOrigSFDialogDidMoveToWindow);
	SPEHPatchInstanceMethod(cls, @selector(layoutSubviews), (IMP)SPEHSFDialogLayoutSubviewsHook, &gOrigSFDialogLayoutSubviews);

	SPEHLog(@"[sfdialog] hooks didMoveToWindow=%s layoutSubviews=%s",
			gOrigSFDialogDidMoveToWindow ? "ok" : "FAILED",
			gOrigSFDialogLayoutSubviews ? "ok" : "FAILED");
}

// MARK: - 「在 App 中打开」确认框（iOS 16 真类，反编译实证）
//
// iOS 16.6 (22.6.0) 同型号设备运行时 class-dump（MobileSafari.framework）确认：
//   SFDialog / SFBasicDialog / SFDialogController / SFDialogView / SFDialogAction 全部存在
//   -[SFDialogController presentDialog:]                 ← 所有对话框的必经之路
//   -[SFDialogController cancelPresentedDialogIfNeeded]
//   -[SFBasicDialog title/message/actions/completionHandler]
//   +[SFDialog _appLinkRedirectDialogWithMessage:completionHandler:]  ← App 跳转对话框工厂
//   -[SFWebViewController dialogController:willPresentDialog:]
// 旧版 SafariPlus 的 _SFDialog / _SFDialogController / finishWithPrimaryAction:text:
// 在 iOS 16 上【不存在】，照抄旧代码只会毫无效果。
//
// 落点：hook presentDialog:，命中「中打开 / Open in」就不调 orig —— dialog 根本不进呈现队列。
// 另两处只打诊断，不改行为，避免多点拦截互相打架。
static int gAppDlgDiagCount = 0;

static NSString *SPEHObjString(id obj, SEL sel)
{
	if (!obj || ![obj respondsToSelector:sel]) return nil;
	@try {
		id v = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
		return [v isKindOfClass:[NSString class]] ? (NSString *)v : nil;
	} @catch (NSException *e) { return nil; }
}

static NSString *SPEHDialogDescribe(id dialog)
{
	NSMutableString *s = [NSMutableString stringWithString:@"{"];
	[s appendFormat:@"class=%@", dialog ? NSStringFromClass([dialog class]) : @"nil"];
	NSString *t = SPEHObjString(dialog, @selector(title));
	NSString *m = SPEHObjString(dialog, @selector(message));
	if (t.length) [s appendFormat:@" title=%@", t.length > 120 ? [t substringToIndex:120] : t];
	if (m.length) [s appendFormat:@" message=%@", m.length > 180 ? [m substringToIndex:180] : m];
	@try {
		if ([dialog respondsToSelector:@selector(actions)]) {
			id acts = ((id (*)(id, SEL))objc_msgSend)(dialog, @selector(actions));
			if ([acts isKindOfClass:[NSArray class]]) {
				NSMutableArray *names = [NSMutableArray array];
				for (id a in (NSArray *)acts) {
					NSString *n = SPEHObjString(a, @selector(title));
					if (n.length) [names addObject:n];
				}
				if (names.count) [s appendFormat:@" actions=[%@]", [names componentsJoinedByString:@","]];
			}
		}
	} @catch (NSException *e) { }
	[s appendString:@"}"];
	return s;
}

static BOOL SPEHTextWantsOpenApp(NSString *text)
{
	if (!text.length) return NO;

	// 0.9.8：先排除 Safari 自身的「错误提示框」。这类框必须放行给 sfdialog 精准拆除，
	// 绝不能被下面的通用规则误伤（它们含「浏览器」字样但不是「选择打开方式」）。
	static NSArray *exclude = nil;
	static dispatch_once_t onceEx;
	dispatch_once(&onceEx, ^{
		exclude = @[@"打不开", @"网址无效", @"无法打开", @"无法连接到", @"can't open", @"cannot open", @"could not open"];
	});
	for (NSString *k in exclude) {
		if ([text rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return NO;
	}

	static NSArray *kw = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		kw = @[@"中打开", @"里打开", @"应用中打开", @"App中打开", @"APP中打开", @"用抖音打开", @"使用抖音打开",
		       @"Open in", @"open in", @"Open with", @"Continue in",
		       // 0.9.8 通用化：各类「选择用哪个 App / 浏览器打开」的措辞
		       @"中打开此页", @"里打开此页", @"中继续", @"里继续", @"打开方式", @"选择打开", @"选取打开",
		       @"在浏览器", @"浏览器中打开", @"浏览器打开", @"用浏览器", @"网页打开", @"用网页",
		       @"打开App", @"打开APP", @"打开应用", @"App打开", @"APP打开", @"应用打开",
		       @"用App打开", @"使用App打开", @"用应用打开", @"此App打开", @"该App打开",
		       @"Open in Safari", @"Continue with", @"Open using", @"Open with Safari"];
	});
	for (NSString *k in kw) {
		if ([text rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
	}
	return NO;
}

// 0.9.8：按对话框按钮判定「选择打开方式」确认框。
// AppLink 确认框至少 2 个按钮且含「打开」类按钮（如 抖音:[打开,取消]、起点:[在起点读书中打开,在浏览器中打开]）；
// Safari 错误框只有单个「好」按钮，不会命中 —— 放行给 sfdialog 精准拆除。
static BOOL SPEHActionWantsOpenApp(id dialog)
{
	if (!dialog || ![dialog respondsToSelector:@selector(actions)]) return NO;
	@try {
		id acts = ((id (*)(id, SEL))objc_msgSend)(dialog, @selector(actions));
		if (![acts isKindOfClass:[NSArray class]] || [(NSArray *)acts count] < 2) return NO;
		for (id a in (NSArray *)acts) {
			NSString *n = SPEHObjString(a, @selector(title));
			if (!n.length) continue;
			// 「打不开」这类否定式不算
			if ([n rangeOfString:@"打不开"].location != NSNotFound) continue;
			if ([n rangeOfString:@"打开" options:NSCaseInsensitiveSearch].location != NSNotFound ||
			    [n rangeOfString:@"open" options:NSCaseInsensitiveSearch].location != NSNotFound) {
				return YES;
			}
		}
	} @catch (NSException *e) { return NO; }
	return NO;
}

// 0.12.6：BrowserController 没有公开的 shared 入口（实测 sharedController / mainBrowserController
// 都不存在，扫描时拿到的是 -2），只能 hook 它的 init 把实例存下来，之后才能枚举标签页。
static __weak id gBrowserController = nil;
static IMP gOrigBrowserControllerInit = NULL;

static id SPEHBrowserControllerInitHook(id self, SEL _cmd)
{
	id r = nil;
	if (gOrigBrowserControllerInit) r = ((id (*)(id, SEL))gOrigBrowserControllerInit)(self, _cmd);
	gBrowserController = self;
	return r;
}

// 兜底：hook init 可能来不及（Safari 可能先建好控制器再加载 dylib），
// 再从当前窗口的视图控制器树里把 BrowserController 捞出来。
static id SPEHFindBrowserController(void)
{
	if (gBrowserController) return gBrowserController;

	Class target = NSClassFromString(@"BrowserController");
	UIWindow *win = nil;
	@try { win = [UIApplication sharedApplication].keyWindow; } @catch (NSException *e) { win = nil; }
	id rootVC = nil;
	@try { rootVC = win.rootViewController; } @catch (NSException *e) { rootVC = nil; }
	if (!rootVC) return nil;

	NSMutableArray *stack = [NSMutableArray arrayWithObject:rootVC];
	int guard = 0;
	while (stack.count && guard++ < 500) {
		id vc = stack.firstObject;
		[stack removeObjectAtIndex:0];
		if (target && [vc isKindOfClass:target]) return vc;
		@try {
			if ([vc respondsToSelector:@selector(childViewControllers)]) {
				NSArray *kids = ((id (*)(id, SEL))objc_msgSend)(vc, @selector(childViewControllers));
				if ([kids isKindOfClass:[NSArray class]]) [stack addObjectsFromArray:kids];
			}
			if ([vc respondsToSelector:@selector(presentedViewController)]) {
				id p = ((id (*)(id, SEL))objc_msgSend)(vc, @selector(presentedViewController));
				if (p) [stack addObject:p];
			}
		} @catch (NSException *e) { }
	}
	return nil;
}

static IMP gOrigPresentDialog = NULL;
// 0.12.1：畸形 origin 的扩展权限请求 —— 只做诊断记录，不做拦截（老板要求先查清来源）。
//
// 真机日志实证：Dark Night / Aurora 这类深色扩展会反复弹
//   「“X”想要访问 huayuarc.xn--cn -928dokq99f6ub31h。」
// 把这个 host 做 punycode 解码，得到的是 **「cn 怎么打不开」** —— 也就是说这个
// 「域名」其实是一句中文被当成 URL 解析了（原串形如 huayuarc.cn 怎么打不开）。
// 空格让 origin 非法 ⇒ Safari 拿它匹配授权表永远失败（连全站通配都套不住非法 host），
// 于是每加载一次就重新询问；用户点「始终允许」写回去的还是同一条非法 origin，
// 下一次照样弹 —— 这就是「全部允许 / 全部拒绝都没用」的死循环。
//
// 当前只在命中时把「当时页面真实 URL」打进日志，用于定位是谁在加载这个坏串。
// ⚠️ 注释里绝对不要写 `星号斜杠星号` 那种通配写法：Logos 预处理器会把其中的
// `斜杠星号` 当成块注释开头，直接把后面整段（包括 %ctor）吃掉，编译表现为
// 一堆 unused function。这个坑已经踩过一次。
// 这个判定两个变体都要用（no-log 下也要吞弹窗），所以放在条件编译外面。
static BOOL SPEHIsBadHostExtensionPermission(NSString *desc)
{
	if (!desc.length) return NO;

	static NSArray *extKW = nil;
	static dispatch_once_t onceEP;
	dispatch_once(&onceEP, ^{
		extKW = @[@"想要访问", @"wants to access", @"would like to access", @"想要读取"];
	});
	BOOL isExtPermission = NO;
	for (NSString *k in extKW) {
		if ([desc rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) { isExtPermission = YES; break; }
	}
	if (!isExtPermission) return NO;

	// 取「访问 / access」之后的片段，作为疑似 host
	NSString *tail = nil;
	NSRange r = [desc rangeOfString:@"想要访问"];
	if (r.location != NSNotFound) {
		tail = [desc substringFromIndex:NSMaxRange(r)];
	} else {
		NSRange r2 = [desc rangeOfString:@"access" options:NSCaseInsensitiveSearch];
		if (r2.location == NSNotFound) return NO;
		tail = [desc substringFromIndex:NSMaxRange(r2)];
	}

	NSRange stop = [tail rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"。\n"]];
	if (stop.location != NSNotFound) tail = [tail substringToIndex:stop.location];
	NSRange msg = [tail rangeOfString:@"message="];
	if (msg.location != NSNotFound) tail = [tail substringToIndex:msg.location];
	if (!tail.length) return NO;

	// 域名不可能含空白字符 ⇒ 含空白即畸形 origin，永远匹配不上授权表
	return [tail rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]].location != NSNotFound;
}

// MARK: - 扩展权限表净化（0.12.5 根治）
//
// 病灶：Extensions.plist 里各扩展的 xxxPermissionOrigins 字典中有一条 key，
//   形如 星号 冒号 斜杠 斜杠 星号 点 huayuarc.xn--cn -928dokq99f6ub31h 斜杠 星号
//   （host 中间带空格，真实含义是「huayuarc.cn 怎么打不开」这整句中文被当成域名）。
// 这种 key 不是合法的 WebKit match pattern，解析必然失败，后果是双向的：
//   1) 每次往该 origin 注入都判「未授权」→ 反复弹「想要访问」；
//   2) 连同一条字典里的全站通配授权也一起失效 → 部分网站扩展压根不注入，
//      表现就是「这些网站点了 DARK 按钮也不变黑，工具栏还挂个三角感叹号」。
// 用户在弹窗上点允许/不允许，Safari 都只会把同一串坏 key 写回去（实测 Granted 变 Revoked），
// 所以这个循环永远出不来。唯一根治点：在 Safari 读取这份 plist 之前把它清掉 —— 因此放在 ctor 最前面。
static int SPEHSanitizeExtensionPlist(void)
{
	NSString *home = NSHomeDirectory();
	if (!home.length) return -1;
	NSString *path = [home stringByAppendingPathComponent:@"Library/Safari/WebExtensions/Extensions.plist"];


	NSFileManager *fm = [NSFileManager defaultManager];
	if (![fm fileExistsAtPath:path]) return -2;

	NSData *data = [NSData dataWithContentsOfFile:path];
	if (!data.length) return -3;

	id root = nil;
	@try {
		root = [NSPropertyListSerialization propertyListWithData:data
														options:NSPropertyListMutableContainersAndLeaves
														 format:NULL
														  error:nil];
	} @catch (NSException *e) { root = nil; }
	if (![root isKindOfClass:[NSDictionary class]]) return -4;

	NSMutableDictionary *rootDict = (NSMutableDictionary *)root;
	int removed = 0;

	for (NSString *extKey in [[rootDict allKeys] copy]) {
		id ext = [rootDict objectForKey:extKey];
		if (![ext isKindOfClass:[NSDictionary class]]) continue;
		NSMutableDictionary *extDict = (NSMutableDictionary *)ext;

		for (NSString *field in [[extDict allKeys] copy]) {
			if (![field hasSuffix:@"Origins"]) continue;   // Granted/Revoked/Accessible PermissionOrigins
			id val = [extDict objectForKey:field];
			if (![val isKindOfClass:[NSDictionary class]]) continue;

			NSMutableDictionary *origins = [NSMutableDictionary dictionaryWithDictionary:(NSDictionary *)val];
			for (id k in [[origins allKeys] copy]) {
				if (![k isKindOfClass:[NSString class]]) { [origins removeObjectForKey:k]; removed++; continue; }
				NSString *ks = (NSString *)k;
				BOOL bad = NO;
				for (NSUInteger i = 0; i < ks.length; i++) {
					unichar c = [ks characterAtIndex:i];
					if (c <= 0x20 || c > 0x7e) { bad = YES; break; }   // 空白 + 非 ASCII 一律判非法
				}
				if (bad) { [origins removeObjectForKey:k]; removed++; }
			}
			[extDict setObject:origins forKey:field];
		}
	}

	if (removed <= 0) return 0;

	NSData *out = [NSPropertyListSerialization dataWithPropertyList:root
															format:NSPropertyListXMLFormat_v1_0
														   options:0
															 error:nil];
	if (!out.length) return -5;
	if (![out writeToFile:path atomically:YES]) return -6;
	return removed;
}

// 判断一个 URL 字符串的 host 段是否非法（含空白 / 含非 ASCII）。
static BOOL SPEHStringIsMalformedHost(NSString *s)
{
	if (![s isKindOfClass:[NSString class]] || !s.length) return NO;
	for (NSUInteger i = 0; i < s.length; i++) {
		if ([s characterAtIndex:i] > 0x7e) return YES;
	}
	NSRange r = [s rangeOfString:@"://"];
	if (r.location == NSNotFound) return NO;
	NSUInteger start = NSMaxRange(r);
	if (start >= s.length) return NO;
	NSRange stop = [s rangeOfString:@"/" options:0 range:NSMakeRange(start, s.length - start)];
	NSString *host = (stop.location == NSNotFound)
		? [s substringFromIndex:start]
		: [s substringWithRange:NSMakeRange(start, stop.location - start)];
	return [host rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]].location != NSNotFound;
}

// 0.12.5：找出持有畸形 URL 的「幽灵标签页」并关掉。
// 证据：权限弹窗的对象永远不是当前页面（页面是知乎 / bing / zol，弹窗却固定是那串
// 「huayuarc.cn 怎么打不开」），而「网址无效」弹窗和它成对出现 —— 说明浏览器里还挂着一个
// URL 就是这串东西的标签页，它每次被恢复 / 重载，就会走一遍：
//   报「网址无效」→ 扩展拿它的 origin 请求授权 → 用户点允许/不允许都写回同一条坏 key。
// 会话状态存在 datavault 保护区（SSH 读不到），只能在进程内把这页关掉。
static int SPEHCloseBadTabs(void)
{
	id bc = SPEHFindBrowserController();
	if (!bc) {
		Class bcCls = NSClassFromString(@"BrowserController");
		if (!bcCls) return -1;
		for (NSString *selName in @[@"sharedController", @"mainBrowserController", @"sharedInstance"]) {
			SEL s = NSSelectorFromString(selName);
			if (![bcCls respondsToSelector:s]) continue;
			@try { bc = ((id (*)(id, SEL))objc_msgSend)(bcCls, s); } @catch (NSException *e) { bc = nil; }
			if (bc) break;
		}
	}
	if (!bc) return -2;

	id tabs = nil;
	for (NSString *selName in @[@"tabDocuments", @"tabs"]) {
		SEL s = NSSelectorFromString(selName);
		if (![bc respondsToSelector:s]) continue;
		@try { tabs = ((id (*)(id, SEL))objc_msgSend)(bc, s); } @catch (NSException *e) { tabs = nil; }
		if (tabs) break;
	}
	if (!tabs) {
		for (NSString *ivName in @[@"_tabDocuments", @"_tabs", @"_tabDocumentsOrderedSet"]) {
			Ivar iv = class_getInstanceVariable(object_getClass(bc), ivName.UTF8String);
			if (!iv) continue;
			@try { tabs = object_getIvar(bc, iv); } @catch (NSException *e) { tabs = nil; }
			if (tabs) break;
		}
	}
	if (!tabs) {
		// 再退一层：BrowserController 通常把标签页托管给 TabController
		id tc = nil;
		for (NSString *selName in @[@"tabController"]) {
			SEL s = NSSelectorFromString(selName);
			if (![bc respondsToSelector:s]) continue;
			@try { tc = ((id (*)(id, SEL))objc_msgSend)(bc, s); } @catch (NSException *e) { tc = nil; }
		}
		if (!tc) {
			Ivar iv = class_getInstanceVariable(object_getClass(bc), "_tabController");
			if (iv) { @try { tc = object_getIvar(bc, iv); } @catch (NSException *e) { tc = nil; } }
		}
		if (tc) {
			SEL s = NSSelectorFromString(@"tabDocuments");
			if ([tc respondsToSelector:s]) {
				@try { tabs = ((id (*)(id, SEL))objc_msgSend)(tc, s); } @catch (NSException *e) { tabs = nil; }
			}
		}
	}
	if (!tabs) {
#ifndef SPEH_NO_LOG
		static BOOL dumpedIvars = NO;
		if (!dumpedIvars) {
			dumpedIvars = YES;
			NSMutableArray *names = [NSMutableArray array];
			unsigned int c = 0;
			Ivar *ivs = class_copyIvarList(object_getClass(bc), &c);
			for (unsigned int i = 0; i < c; i++) {
				const char *n = ivar_getName(ivs[i]);
				if (n) [names addObject:[NSString stringWithUTF8String:n]];
			}
			if (ivs) free(ivs);
			SPEHLog(@"[extperm] BrowserController 无 tabDocuments，ivar=%@", [names componentsJoinedByString:@","]);
		}
#endif
		return -3;
	}

	NSArray *list = nil;
	@try {
		if ([tabs respondsToSelector:@selector(allObjects)]) list = [tabs allObjects];
		else if ([tabs isKindOfClass:[NSArray class]]) list = (NSArray *)tabs;
	} @catch (NSException *e) { list = nil; }
	if (![list isKindOfClass:[NSArray class]] || !list.count) return -4;

	int closed = 0;
	for (id tab in list) {
		NSString *u = nil;
		for (NSString *selName in @[@"url", @"URL", @"currentURL", @"uncommittedURL"]) {
			SEL s = NSSelectorFromString(selName);
			if (![tab respondsToSelector:s]) continue;
			@try {
				id v = ((id (*)(id, SEL))objc_msgSend)(tab, s);
				if ([v isKindOfClass:[NSURL class]]) { u = [(NSURL *)v absoluteString]; break; }
			} @catch (NSException *e) { }
		}
		if (!SPEHStringIsMalformedHost(u)) continue;
		SPEHLog(@"[extperm] 关闭畸形 URL 标签页: %@", u);
		SEL closeSel = NSSelectorFromString(@"close");
		if (![tab respondsToSelector:closeSel]) closeSel = NSSelectorFromString(@"closeTab");
		if ([tab respondsToSelector:closeSel]) {
			@try { ((void (*)(id, SEL))objc_msgSend)(tab, closeSel); closed++; } @catch (NSException *e) { }
		}
	}
	return closed;
}

// MARK: - 标签页库净化（0.12.7 真正根治）
//
// 0.12.6 在进程内扫到了落点：/var/mobile/Library/Safari 下只有
//   SafariTabs.db / SafariTabs.db-wal 含畸形串（bad=1），
//   History.db / BrowserState.db / CloudTabs.db 里只有正常的 huayuarc 域名（yourepo）。
// 也就是说浏览器里确实存着一个 URL 就是「huayuarc.cn 怎么打不开」的标签页。
// 它每次被恢复/重载都会：先报「网址无效」→ 扩展再拿这个 origin 去请求授权 →
// 权限弹窗反复出现；而这条 origin 天生无法解析成合法 match pattern，永远匹配不上。
// 该目录受 datavault 保护（SSH 连 ls 都 Operation not permitted），只能在 Safari 进程内改。
// 做法：sqlite3 打开 SafariTabs.db，把含 928dokq 的文本列改写为 about:blank。
// 行本身保留不删 —— 避免破坏 tab group / 会话的外键关系，只是让那页不再是坏 URL。
typedef struct {
	int (*open_v2)(const char *, void **, int, const char *);
	int (*prepare_v2)(void *, const char *, int, void **, const char *);
	int (*step)(void *);
	const unsigned char *(*column_text)(void *, int);
	int (*column_int)(void *, int);
	int (*finalize)(void *);
	int (*exec)(void *, const char *, void *, void *, char **);
	int (*close)(void *);
} SPEHSqliteApi;

static int SPEHPurgeBadInSqlitePath(NSString *path, BOOL mergeWal);

// 0.12.8：参数化 —— 任意 sqlite 库都能洗；mergeWal=YES 时 checkpoint + VACUUM，
// 把 -wal 里的旧页合并回主库并清零空闲页，避免遗留字节被下次 grep 误判成「还在」。
static int SPEHPurgeBadInSqlitePath(NSString *path, BOOL mergeWal)
{
	static SPEHSqliteApi api;
	static BOOL apiReady = NO;
	if (!apiReady) {
		void *h = dlopen("/usr/lib/libsqlite3.dylib", RTLD_LAZY);
		if (!h) h = dlopen("/usr/lib/libsqlite3.0.dylib", RTLD_LAZY);
		if (!h) return -1;
		api.open_v2    = (int (*)(const char *, void **, int, const char *))dlsym(h, "sqlite3_open_v2");
		api.prepare_v2 = (int (*)(void *, const char *, int, void **, const char *))dlsym(h, "sqlite3_prepare_v2");
		api.step       = (int (*)(void *))dlsym(h, "sqlite3_step");
		api.column_text = (const unsigned char *(*)(void *, int))dlsym(h, "sqlite3_column_text");
		api.column_int = (int (*)(void *, int))dlsym(h, "sqlite3_column_int");
		api.finalize   = (int (*)(void *))dlsym(h, "sqlite3_finalize");
		api.exec       = (int (*)(void *, const char *, void *, void *, char **))dlsym(h, "sqlite3_exec");
		api.close      = (int (*)(void *))dlsym(h, "sqlite3_close");
		apiReady = YES;
		if (!api.open_v2 || !api.prepare_v2 || !api.step || !api.exec || !api.close || !api.finalize) return -2;
	}

	if (!path.length) return -3;
	if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return -3;

	void *db = NULL;
	// 2 = SQLITE_OPEN_READWRITE, 0x10000 = SQLITE_OPEN_FULLMUTEX
	if (api.open_v2([path UTF8String], &db, 2 | 0x10000, NULL) != 0) {
		if (db) api.close(db);
		return -4;
	}
	// 覆盖删除：UPDATE 之后旧值所在页会被清零，不然字节残留会一直被 grep 到。
	api.exec(db, "PRAGMA secure_delete=ON", NULL, NULL, NULL);

	NSMutableArray *tables = [NSMutableArray array];
	void *st = NULL;
	if (api.prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &st, NULL) == 0 && st) {
		while (api.step(st) == 100) {
			const unsigned char *n = api.column_text(st, 0);
			if (n) [tables addObject:[NSString stringWithUTF8String:(const char *)n]];
		}
	}
	if (st) api.finalize(st);

	int fixed = 0;
	for (NSString *t in tables) {
		NSMutableArray *textCols = [NSMutableArray array];
		NSString *colsSql = [NSString stringWithFormat:@"PRAGMA table_info(\"%@\")", t];
		void *cs = NULL;
		if (api.prepare_v2(db, [colsSql UTF8String], -1, &cs, NULL) == 0 && cs) {
			while (api.step(cs) == 100) {
				const unsigned char *cn = api.column_text(cs, 1);
				const unsigned char *ct = api.column_text(cs, 2);
				if (!cn) continue;
				NSString *colName = [NSString stringWithUTF8String:(const char *)cn];
				NSString *colType = ct ? [[NSString stringWithUTF8String:(const char *)ct] uppercaseString] : @"";
				BOOL isText = (colType.length == 0)
					|| [colType rangeOfString:@"TEXT"].location != NSNotFound
					|| [colType rangeOfString:@"CHAR"].location != NSNotFound
					|| [colType rangeOfString:@"CLOB"].location != NSNotFound;
				if (isText) [textCols addObject:colName];
			}
		}
		if (cs) api.finalize(cs);

		for (NSString *col in textCols) {
			NSMutableArray *ids = [NSMutableArray array];
			NSString *sel = [NSString stringWithFormat:
							 @"SELECT rowid, \"%@\" FROM \"%@\" WHERE \"%@\" LIKE '%%928dokq%%'", col, t, col];
			void *ss = NULL;
			if (api.prepare_v2(db, [sel UTF8String], -1, &ss, NULL) == 0 && ss) {
				while (api.step(ss) == 100) {
					int rid = api.column_int(ss, 0);
					const unsigned char *v = api.column_text(ss, 1);
					[ids addObject:[NSString stringWithFormat:@"%d", rid]];
					SPEHLog(@"[tabdb] 命中 %@.%@ rowid=%d 原值=%@", t, col, rid,
							v ? [NSString stringWithUTF8String:(const char *)v] : @"(null)");
				}
			}
			if (ss) api.finalize(ss);

			if (ids.count) {
				NSString *upd = [NSString stringWithFormat:
								 @"UPDATE \"%@\" SET \"%@\"='about:blank' WHERE rowid IN (%@)",
								 t, col, [ids componentsJoinedByString:@","]];
				if (api.exec(db, [upd UTF8String], NULL, NULL, NULL) == 0) {
					fixed += (int)ids.count;
				} else {
					SPEHLog(@"[tabdb] 改写失败 %@.%@（可能被占用）", t, col);
				}
			}
		}
	}

	if (fixed > 0 && mergeWal) {
		// 把 -wal 合并回主库再截断：否则旧版本页还躺在 wal 里，Safari 下次重开可能回滚回去。
		api.exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", NULL, NULL, NULL);
		// 重建库，把 secure_delete 清掉的残留页彻底交付给文件系统（字节层面也搜不到）。
		api.exec(db, "VACUUM", NULL, NULL, NULL);
		// VACUUM 之后本身会产生新 wal，再截断一次。
		api.exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", NULL, NULL, NULL);
	}

	api.close(db);
	return fixed;
}

// MARK: - 0.12.8 全盘定位与净化
//
// 0.12.7 已经把 SafariTabs.db 的 bookmarks rowid=278 改成 about:blank，复清也是 fixed=0，
// 但弹窗标题依然是「想要访问 huayuarc.xn--cn -928dokq99f6ub31h」⇒ 这个 origin 另有副本。
// 关键认知：Safari 的「待授权 origin」是一份持久化队列，不只在
//   <容器>/Library/Safari/WebExtensions/Extensions.plist
// 里，WebKit 侧另有站点数据与 AppGroup 副本。所以这次不再猜目录，直接把
//   /var/mobile/Library/Safari、/var/mobile/Library/WebKit、/var/mobile/Library/Preferences、
//   Containers/Shared/AppGroup、以及 Safari 自己的容器
// 全部递归扫一遍，凡含 928dokq 的文件：
//   - SQLite（文件头 "SQLite format 3"）→ 逐表逐 TEXT 列 UPDATE 成 about:blank + checkpoint + VACUUM
//   - plist → 递归删掉含该串的 key/value，再序列化写回
//   - 其他（会话二进制等）→ 只记录，不动（避免写坏 Safari 私有格式）

// 进程内读文件找坏串；命中返回 YES。
static BOOL SPEHFileContainsBadToken(NSString *path, unsigned long long *outSize)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
	unsigned long long sz = [attr fileSize];
	if (outSize) *outSize = sz;
	if (sz == 0 || sz > (32ULL * 1024 * 1024)) return NO;
	NSData *d = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
	if (!d.length) return NO;
	static NSData *needle = nil;
	if (!needle) needle = [@"928dokq" dataUsingEncoding:NSUTF8StringEncoding];
	return [d rangeOfData:needle options:0 range:NSMakeRange(0, d.length)].location != NSNotFound;
}

static void SPEHScanBadTokenDir(NSString *dir, int depth, NSMutableArray *out)
{
	if (depth > 3 || out.count >= 40 || !dir.length) return;
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray *names = [fm contentsOfDirectoryAtPath:dir error:nil];
	if (![names isKindOfClass:[NSArray class]]) return;

	for (NSString *n in names) {
		if (out.count >= 40) return;
		NSString *p = [dir stringByAppendingPathComponent:n];
		BOOL isDir = NO;
		if (![fm fileExistsAtPath:p isDirectory:&isDir]) continue;
		if (isDir) {
			// 跳过明显无关的大目录，控制耗时
			if ([n isEqualToString:@"Media"] || [n isEqualToString:@"Caches"]
				|| [n isEqualToString:@"tmp"] || [n isEqualToString:@"Downloads"]) continue;
			SPEHScanBadTokenDir(p, depth + 1, out);
			continue;
		}
		unsigned long long sz = 0;
		if (SPEHFileContainsBadToken(p, &sz)) {
			[out addObject:[NSString stringWithFormat:@"%@(%lluK)", p, sz / 1024]];
		}
	}
}

// plist 递归删：key 或 string value 含坏串就删/置空
static BOOL SPEHPurgeBadTokenInObject(id *obj)
{
	if (!obj || !*obj) return NO;
	BOOL changed = NO;
	if ([*obj isKindOfClass:[NSMutableDictionary class]]) {
		NSMutableDictionary *d = (NSMutableDictionary *)*obj;
		for (id k in [d allKeys]) {
			NSString *ks = [k isKindOfClass:[NSString class]] ? k : nil;
			if (ks && ks.length && [ks rangeOfString:@"928dokq"].location != NSNotFound) {
				[d removeObjectForKey:k];
				changed = YES;
				continue;
			}
			id v = d[k];
			if ([v isKindOfClass:[NSString class]] && [v rangeOfString:@"928dokq"].location != NSNotFound) {
				d[k] = @"about:blank";
				changed = YES;
				continue;
			}
			NSMutableArray *holder = [NSMutableArray arrayWithObject:v ?: [NSNull null]];
			if (SPEHPurgeBadTokenInObject(&holder[0])) {
				d[k] = holder[0];
				changed = YES;
			}
		}
		return changed;
	}
	if ([*obj isKindOfClass:[NSMutableArray class]]) {
		NSMutableArray *a = (NSMutableArray *)*obj;
		for (NSUInteger i = 0; i < a.count; i++) {
			id v = a[i];
			if ([v isKindOfClass:[NSString class]] && [v rangeOfString:@"928dokq"].location != NSNotFound) {
				a[i] = @"about:blank";
				changed = YES;
				continue;
			}
			NSMutableArray *holder = [NSMutableArray arrayWithObject:v ?: [NSNull null]];
			if (SPEHPurgeBadTokenInObject(&holder[0])) {
				a[i] = holder[0];
				changed = YES;
			}
		}
		return changed;
	}
	return NO;
}

static int SPEHPurgeBadTokenInPlist(NSString *path)
{
	NSData *raw = [NSData dataWithContentsOfFile:path options:0 error:nil];
	if (!raw.length) return -1;
	id pl = nil;
	@try {
		pl = [NSPropertyListSerialization propertyListWithData:raw options:NSPropertyListMutableContainersAndLeaves
													   format:NULL error:nil];
	} @catch (NSException *e) { pl = nil; }
	if (!pl || ![pl isKindOfClass:[NSMutableDictionary class]]) return -2;

	BOOL changed = SPEHPurgeBadTokenInObject(&pl);
	if (!changed) return 0;

	NSData *out = [NSPropertyListSerialization dataWithPropertyList:pl format:NSPropertyListBinaryFormat_v1_0
															 options:0 error:nil];
	if (!out.length) return -3;
	if (![out writeToFile:path atomically:YES]) return -4;
	return 1;
}

static NSString *SPEHScanAndPurgeBadTokenInRoots(NSArray *roots, int *outFixed)
{
	NSMutableArray *hits = [NSMutableArray array];
	for (NSString *r in roots) SPEHScanBadTokenDir(r, 0, hits);

	int fixedFiles = 0;
	NSMutableArray *report = [NSMutableArray array];
	for (NSString *one in hits) {
		// one 形如 "/path/file(123K)"，拆出路径
		NSRange pr = [one rangeOfString:@"(" options:NSBackwardsSearch];
		NSString *path = pr.location == NSNotFound ? one : [one substringToIndex:pr.location];

		NSData *head = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
		BOOL isSqlite = NO;
		if (head.length >= 16) {
			NSString *magic = [[NSString alloc] initWithData:[head subdataWithRange:NSMakeRange(0, 15)]
													encoding:NSUTF8StringEncoding];
			isSqlite = [magic isEqualToString:@"SQLite format 3"];
		}
		[report addObject:[NSString stringWithFormat:@"%@[%@]", path, isSqlite ? @"sqlite" : @"bin"]];

		int rc = 0;
		if (isSqlite) {
			rc = SPEHPurgeBadInSqlitePath(path, YES);
		} else if ([path.pathExtension.lowercaseString isEqualToString:@"plist"]) {
			rc = SPEHPurgeBadTokenInPlist(path);
		}
		if (rc != 0) {
			// 只在真的改了东西时计数；sqlite 返回命中行数，plist 返回 1
			fixedFiles++;
		}
	}

	if (outFixed) *outFixed = fixedFiles;
	return report.count ? [report componentsJoinedByString:@", "] : @"(无命中)";
}

// 全盘扫 + 修。返回可读报告（日志用），实际修复数通过 outFixed 带回。
static NSString *SPEHScanAndPurgeBadToken(int *outFixed)
{
	NSArray *roots = @[
		@"/var/mobile/Library/Safari",
		@"/var/mobile/Library/WebKit",
		@"/var/mobile/Library/Preferences",
		@"/var/mobile/Library/Caches/com.apple.mobilesafari",
	];
	return SPEHScanAndPurgeBadTokenInRoots(roots, outFixed);
}

#ifndef SPEH_NO_LOG
// 0.12.6 诊断：Safari 进程自己有权读 /var/mobile/Library/Safari（datavault 保护，SSH 读不到），
// 所以在进程内扫一遍，找出那个坏串到底还存在哪个文件里 —— 会话恢复 / 书签 / 最近关闭 / 自动填充。
static NSString *SPEHScanSafariSharedDir(void)
{
	NSString *dir = @"/var/mobile/Library/Safari";
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray *names = [fm contentsOfDirectoryAtPath:dir error:nil];
	if (![names isKindOfClass:[NSArray class]]) return @"(无法列出目录)";

	NSData *needle = [@"928dokq" dataUsingEncoding:NSUTF8StringEncoding];
	NSData *needle2 = [@"huayuarc" dataUsingEncoding:NSUTF8StringEncoding];
	NSMutableArray *hits = [NSMutableArray array];

	for (NSString *n in names) {
		if (hits.count >= 20) break;
		NSString *p = [dir stringByAppendingPathComponent:n];
		BOOL isDir = NO;
		if (![fm fileExistsAtPath:p isDirectory:&isDir] || isDir) continue;
		NSDictionary *attr = [fm attributesOfItemAtPath:p error:nil];
		unsigned long long sz = [attr fileSize];
		if (sz == 0 || sz > (20ULL * 1024 * 1024)) continue;
		NSData *d = [NSData dataWithContentsOfFile:p];
		if (!d.length) continue;
		NSRange full = NSMakeRange(0, d.length);
		BOOL h1 = (needle.length && [d rangeOfData:needle options:0 range:full].location != NSNotFound);
		BOOL h2 = (needle2.length && [d rangeOfData:needle2 options:0 range:full].location != NSNotFound);
		if (h1 || h2) {
			[hits addObject:[NSString stringWithFormat:@"%@(%lluK,bad=%d,host=%d)",
							 n, sz / 1024, h1 ? 1 : 0, h2 ? 1 : 0]];
		}
	}
	return hits.count ? [hits componentsJoinedByString:@", "] : @"(共享目录无命中)";
}

// 0.12.5 诊断：畸形 host 权限请求被触发时打一份调用栈，直接指认是哪个类/方法在请求。
static NSString *SPEHBacktraceText(NSUInteger limit)
{
	NSArray *sym = [NSThread callStackSymbols];
	if (!sym.count) return @"(no symbols)";
	NSUInteger n = sym.count < limit ? sym.count : limit;
	NSMutableArray *keep = [NSMutableArray arrayWithCapacity:n];
	for (NSUInteger i = 0; i < n; i++) [keep addObject:sym[i]];
	return [keep componentsJoinedByString:@" <- "];
}

// 0.12.5 诊断：把某个类的全部方法名列出来（含继承链），用于找可 hook 的入口。
static NSString *SPEHMethodNamesOfClass(NSString *clsName)
{
	Class cls = NSClassFromString(clsName);
	if (!cls) return @"(class not found)";
	NSMutableArray *out = [NSMutableArray array];
	Class cur = cls;
	int depth = 0;
	while (cur && cur != [NSObject class] && depth < 4) {
		unsigned int mc = 0;
		Method *ms = class_copyMethodList(cur, &mc);
		for (unsigned int i = 0; i < mc; i++) {
			NSString *s = NSStringFromSelector(method_getName(ms[i]));
			if (s.length) [out addObject:[NSString stringWithFormat:@"%@-%@", depth ? @"^" : @"", s]];
		}
		if (ms) free(ms);
		cur = class_getSuperclass(cur);
		depth++;
	}
	if (!out.count) return @"(no methods)";
	return [out componentsJoinedByString:@" "];
}
#endif

// 以下诊断只在 withlog 变体里编译：no-log 下 SPEHLog 是空宏，这些函数会变成未引用（-Werror）。
#ifndef SPEH_NO_LOG
// 诊断用：取当前窗口里第一个 WKWebView 的 URL（不 import WebKit，纯运行时类型判断）
static NSString *SPEHFindWebViewURL(UIView *v, int depth)
{
	if (!v || depth > 24) return nil;
	static Class wkCls = Nil;
	static dispatch_once_t onceWK;
	dispatch_once(&onceWK, ^{ wkCls = NSClassFromString(@"WKWebView"); });
	if (wkCls && [v isKindOfClass:wkCls]) {
		@try {
			id u = ((id (*)(id, SEL))objc_msgSend)(v, @selector(URL));
			if ([u isKindOfClass:[NSURL class]]) {
				NSString *s = [(NSURL *)u absoluteString];
				if (s.length) return s;
			}
		} @catch (NSException *e) { }
	}
	for (UIView *sub in v.subviews) {
		NSString *r = SPEHFindWebViewURL(sub, depth + 1);
		if (r.length) return r;
	}
	return nil;
}

static NSString *SPEHCurrentPageURL(void)
{
	@try {
		for (UIWindow *w in [UIApplication sharedApplication].windows) {
			NSString *r = SPEHFindWebViewURL(w, 0);
			if (r.length) return r;
		}
	} @catch (NSException *e) { }
	return @"(unknown)";
}

// 0.12.2 诊断：把所有「名字里同时带 Permission + Extension/WebExt」的类扫出来，
// 用于下一版精准 hook 权限判定入口（iOS 16 上没有公开头文件，只能运行时枚举）。
static NSString *SPEHScanPermissionClasses(void)
{
	NSMutableArray *hits = [NSMutableArray array];
	int count = objc_getClassList(NULL, 0);
	if (count <= 0) return @"(none)";
	Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
	if (!classes) return @"(alloc fail)";
	count = objc_getClassList(classes, count);
	for (int i = 0; i < count; i++) {
		const char *n = class_getName(classes[i]);
		if (!n) continue;
		NSString *name = [NSString stringWithUTF8String:n];
		if (!name.length) continue;
		BOOL hasPerm = [name rangeOfString:@"Permission" options:NSCaseInsensitiveSearch].location != NSNotFound;
		BOOL hasExt = ([name rangeOfString:@"Extension" options:NSCaseInsensitiveSearch].location != NSNotFound)
				   || ([name rangeOfString:@"WebExt" options:NSCaseInsensitiveSearch].location != NSNotFound);
		if (hasPerm && hasExt) [hits addObject:name];
	}
	free(classes);
	if (!hits.count) return @"(none)";
	[hits sortUsingSelector:@selector(compare:)];
	return [hits componentsJoinedByString:@", "];
}

// 0.12.2 诊断：优先用私有 _ivarDescription 全量 dump，退化为只列 ivar 名字。
static NSString *SPEHObjectDump(id obj)
{
	if (!obj) return @"(nil)";
	NSMutableString *s = [NSMutableString string];
	SEL sel = NSSelectorFromString(@"_ivarDescription");
	if ([obj respondsToSelector:sel]) {
		@try {
			id r = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
			if ([r isKindOfClass:[NSString class]]) [s appendString:(NSString *)r];
		} @catch (NSException *e) { }
	}
	if (!s.length) {
		unsigned int c = 0;
		Ivar *ivars = class_copyIvarList([obj class], &c);
		for (unsigned int i = 0; i < c; i++) {
			const char *nm = ivar_getName(ivars[i]);
			if (nm) [s appendFormat:@"%s; ", nm];
		}
		if (ivars) free(ivars);
	}
	if (!s.length) return @"(empty)";
	if (s.length > 900) return [[s substringToIndex:900] stringByAppendingString:@"...(truncated)"];
	return s;
}
#endif

// 0.12.2：把「已挂进状态机但又不该显示」的 dialog 走完取消流程。
// 必须走 orig 再取消，不能直接 return —— 否则背后的 completionHandler 不回调，
// 扩展侧/导航侧会一直 pending（0.9.7 踩过：弹窗没了但返回按钮失灵）。
static void SPEHSuppressDialogNow(id self, SEL _cmd, id dialog)
{
	if (gOrigPresentDialog) ((void (*)(id, SEL, id))gOrigPresentDialog)(self, _cmd, dialog);

	BOOL canceled = NO;
	@try {
		if ([self respondsToSelector:@selector(cancelPresentedDialogIfNeeded)]) {
			((void (*)(id, SEL))objc_msgSend)(self, @selector(cancelPresentedDialogIfNeeded));
			canceled = YES;
		}
	} @catch (NSException *e) { canceled = NO; }

	if (!canceled) {
		@try {
			if ([self respondsToSelector:@selector(_dismissCurrentDialogWithResponse:)]) {
				((void (*)(id, SEL, id))objc_msgSend)(self, @selector(_dismissCurrentDialogWithResponse:),
						@{@"password": @"", @"selectedActionIndex": @1, @"text": @""});
				canceled = YES;
			}
		} @catch (NSException *e) { canceled = NO; }
	}

	__weak id weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
				   dispatch_get_main_queue(), ^{
		id s = weakSelf;
		if (!s) return;
		@try {
			if ([s respondsToSelector:@selector(presentedDialog)]) {
				id cur = ((id (*)(id, SEL))objc_msgSend)(s, @selector(presentedDialog));
				if (cur == dialog && [s respondsToSelector:@selector(cancelPresentedDialogIfNeeded)]) {
					((void (*)(id, SEL))objc_msgSend)(s, @selector(cancelPresentedDialogIfNeeded));
				}
			}
		} @catch (NSException *e) { }
	});
}

static void SPEHPresentDialogHook(id self, SEL _cmd, id dialog)
{
	NSString *desc = SPEHDialogDescribe(dialog);

#ifndef SPEH_NO_LOG
	// 0.12.6：这个「网址无效」就是坏 URL 被真正加载时抛出来的，是整条链的源头节点。
	// 在这里打调用栈，就能直接指认是哪个类/方法在发起加载。
	if ([desc rangeOfString:@"网址无效"].location != NSNotFound) {
		static int invalidCount = 0;
		invalidCount++;
		if (invalidCount <= 5) {
			SPEHLog(@"[badurl] 无效URL弹窗 #%d page=%@", invalidCount, SPEHCurrentPageURL());
			SPEHLog(@"[badurl] #%d 调用栈=%@", invalidCount, SPEHBacktraceText(30));
		}
	}
#endif

	// 只记录，不拦截：畸形 host 的扩展权限请求，把「页面真实 URL」一并打出来，
	// 用于定位到底是谁在加载这个坏串（是恢复的标签、书签，还是地址栏输入）。
	if (SPEHIsBadHostExtensionPermission(desc)) {
#ifndef SPEH_NO_LOG
		static int badCount = 0;
		badCount++;
		if (badCount <= 15) {
			SPEHLog(@"[extperm] #%d page=%@", badCount, SPEHCurrentPageURL());
			SPEHLog(@"[extperm] #%d dialog=%@", badCount, SPEHObjectDump(dialog));
			if (badCount <= 3) {
				SPEHLog(@"[extperm] #%d 调用栈=%@", badCount, SPEHBacktraceText(28));
				SPEHLog(@"[extperm] #%d banner方法=%@", badCount, SPEHMethodNamesOfClass(@"SFWebExtensionPermissionBanner"));
				SPEHLog(@"[extperm] #%d 权限API方法=%@", badCount, SPEHMethodNamesOfClass(@"WBSWebExtensionAPIPermissionsObjC"));
			}
		} else if (badCount == 16) {
			SPEHLog(@"[extperm] 后续同类弹窗不再记录（累计已超 15 次）");
		}
#endif
		// 0.12.2：这条 origin 天生非法（host 带空格/中文），Safari 拿它匹配授权表永远失败，
		// 无论用户点「允许1天 / 始终允许 / 不允许」都只会在 plist 里反复写回同一条坏 key，
		// 下一次照样弹 —— 实测知乎/wap.zol 每次翻页都弹。这里直接吞掉，不再打扰用户。
		SPEHSuppressDialogNow(self, _cmd, dialog);
		return;
	}

	BOOL wantsOpen = SPEHTextWantsOpenApp(desc) || SPEHActionWantsOpenApp(dialog);
	if (wantsOpen) {
		// 0.9.7 修复：不能直接 return。
		// 这个 dialog 背后挂着一个 WebKit 导航决策，completionHandler 不回调，
		// 导航就永远 pending —— 表现就是「弹窗没了，但返回按钮也失效了」。
		// 正确做法：让 orig 把 dialog 正常挂进状态机（handler 已备好），
		// 再用 SFDialogController 自己的取消方法走完流程，导航随即解锁。
		if (gOrigPresentDialog) ((void (*)(id, SEL, id))gOrigPresentDialog)(self, _cmd, dialog);

		BOOL canceled = NO;
		@try {
			if ([self respondsToSelector:@selector(cancelPresentedDialogIfNeeded)]) {
				((void (*)(id, SEL))objc_msgSend)(self, @selector(cancelPresentedDialogIfNeeded));
				canceled = YES;
			}
		} @catch (NSException *e) { canceled = NO; }

		// 兜底 1：老方法 _dismissCurrentDialogWithResponse: 仍在 iOS 16 上
		if (!canceled) {
			@try {
				if ([self respondsToSelector:@selector(_dismissCurrentDialogWithResponse:)]) {
					((void (*)(id, SEL, id))objc_msgSend)(self, @selector(_dismissCurrentDialogWithResponse:),
							@{@"password": @"", @"selectedActionIndex": @1, @"text": @""});
					canceled = YES;
				}
			} @catch (NSException *e) { canceled = NO; }
		}

		// 兜底 2：presentDialog: 同步阶段 presentedDialog 可能还没设置，
		// 0.1s 后再确认一次，仍在才取消（避免误伤下一个 dialog）
		__weak id weakSelf = self;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
					   dispatch_get_main_queue(), ^{
			id s = weakSelf;
			if (!s) return;
			@try {
				if ([s respondsToSelector:@selector(presentedDialog)]) {
					id cur = ((id (*)(id, SEL))objc_msgSend)(s, @selector(presentedDialog));
					if (cur == dialog && [s respondsToSelector:@selector(cancelPresentedDialogIfNeeded)]) {
						((void (*)(id, SEL))objc_msgSend)(s, @selector(cancelPresentedDialogIfNeeded));
						SPEHLog(@"[appdlg] 0.1s 兜底取消生效");
					}
				}
			} @catch (NSException *e) { }
		});

		SPEHLog(@"[appdlg] 命中并取消(同步=%d) %@", canceled, desc);
		return;
	}
	if (gAppDlgDiagCount < 30) {
		gAppDlgDiagCount++;
		SPEHLog(@"[appdlg] 放行 #%d %@", gAppDlgDiagCount, desc);
	}
	if (gOrigPresentDialog) ((void (*)(id, SEL, id))gOrigPresentDialog)(self, _cmd, dialog);
}

static IMP gOrigAppLinkRedirectDialog = NULL;
static id SPEHAppLinkRedirectDialogHook(id self, SEL _cmd, NSString *message, id completion)
{
	if (gAppDlgDiagCount < 30) {
		gAppDlgDiagCount++;
		SPEHLog(@"[appdlg] 工厂 #%d appLinkRedirect message=%@", gAppDlgDiagCount,
				(message.length > 180) ? [message substringToIndex:180] : (message ?: @""));
	}
	if (gOrigAppLinkRedirectDialog) {
		return ((id (*)(id, SEL, id, id))gOrigAppLinkRedirectDialog)(self, _cmd, message, completion);
	}
	return nil;
}

static IMP gOrigWillPresentDialog = NULL;
static void SPEHWillPresentDialogHook(id self, SEL _cmd, id controller, id dialog)
{
	if (gAppDlgDiagCount < 30) {
		gAppDlgDiagCount++;
		SPEHLog(@"[appdlg] 代理 #%d willPresent %@", gAppDlgDiagCount, SPEHDialogDescribe(dialog));
	}
	if (gOrigWillPresentDialog) ((void (*)(id, SEL, id, id))gOrigWillPresentDialog)(self, _cmd, controller, dialog);
}

static void SPEHInstallAppOpenDialogHooks(void)
{
	Class dc = NSClassFromString(@"SFDialogController");
	Class dcls = NSClassFromString(@"SFDialog");
	Class wc = NSClassFromString(@"SFWebViewController");

	BOOL hasPresent  = (dc && class_getInstanceMethod(dc, @selector(presentDialog:))) ? YES : NO;
	BOOL hasCancel   = (dc && class_getInstanceMethod(dc, @selector(cancelPresentedDialogIfNeeded))) ? YES : NO;
	BOOL hasFactory  = (dcls && class_getClassMethod(dcls, @selector(_appLinkRedirectDialogWithMessage:completionHandler:))) ? YES : NO;
	BOOL hasDelegate = (wc && class_getInstanceMethod(wc, @selector(dialogController:willPresentDialog:))) ? YES : NO;

	SPEHLog(@"[appdlg] iOS16 探测 SFDialogController=%d presentDialog:=%d cancel=%d SFDialog=%d appLinkFactory=%d SFWebViewController=%d willPresentDialog:=%d",
			dc ? 1 : 0, hasPresent, hasCancel, dcls ? 1 : 0, hasFactory, wc ? 1 : 0, hasDelegate);

	if (hasPresent) {
		SPEHPatchInstanceMethod(dc, @selector(presentDialog:), (IMP)SPEHPresentDialogHook, &gOrigPresentDialog);
		SPEHLog(@"[appdlg] hook presentDialog: %s", gOrigPresentDialog ? "ok" : "FAILED");
	}
	if (hasFactory) {
		MSHookMessageEx(object_getClass(dcls), @selector(_appLinkRedirectDialogWithMessage:completionHandler:),
						(IMP)SPEHAppLinkRedirectDialogHook, &gOrigAppLinkRedirectDialog);
		SPEHLog(@"[appdlg] hook appLinkFactory %s", gOrigAppLinkRedirectDialog ? "ok" : "FAILED");
	}
	if (hasDelegate) {
		SPEHPatchInstanceMethod(wc, @selector(dialogController:willPresentDialog:),
								(IMP)SPEHWillPresentDialogHook, &gOrigWillPresentDialog);
		SPEHLog(@"[appdlg] hook willPresentDialog: %s", gOrigWillPresentDialog ? "ok" : "FAILED");
	}

	// 0.12.6：抓 BrowserController 实例，供启动后的标签页清扫使用
	Class bcC = NSClassFromString(@"BrowserController");
	BOOL hasBCInit = (bcC && class_getInstanceMethod(bcC, @selector(init))) ? YES : NO;
	if (hasBCInit) {
		SPEHPatchInstanceMethod(bcC, @selector(init), (IMP)SPEHBrowserControllerInitHook, &gOrigBrowserControllerInit);
		SPEHLog(@"[extperm] hook BrowserController init %s", gOrigBrowserControllerInit ? "ok" : "FAILED");
	} else {
		SPEHLog(@"[extperm] BrowserController init 不可 hook（存在=%d）", bcC ? 1 : 0);
	}
}

// MARK: - 0.12.4 畸形 URL 导航拦截（根治扩展权限弹窗）
//
// 真机日志铁证：每一次「“Dark Night”想要访问 <畸形 host>」前面几十毫秒，必然紧跟一次
// 「Safari 浏览器打不开该网页，因为网址无效」；两者成对出现、页面却各不相同
// （知乎 / 知乎专栏 / wap.zol / 百度经验 / bing 结果页）。
// 结论：有条导航在反复加载那个坏串 —— 浏览器报网址无效，扩展权限又拿同一个 host 去请求，
// 用户点「始终允许」写回的还是坏 key，于是两框一起循环。
// 处理：在导航入口把这个 host 非法的请求直接掐掉，不启动导航，两个弹窗同时消失。
// 正常 URL（含 percent-encoded 后的纯 ASCII）一律原样放行，不加任何额外判断。

static BOOL SPEHURLStringIsMalformed(NSString *s)
{
	if (!s.length) return NO;
	NSUInteger n = (s.length > 4096) ? 4096 : s.length;
	for (NSUInteger i = 0; i < n; i++) {
		unichar c = [s characterAtIndex:i];
		if (c == ' ' || c == '\t' || c == '\n' || c > 0x7E) return YES;
	}
	return NO;
}

static NSString *SPEHRequestURLString(id req)
{
	if (!req) return nil;
	if ([req isKindOfClass:[NSString class]]) return (NSString *)req;
	@try {
		if ([req isKindOfClass:[NSURL class]]) return [(NSURL *)req absoluteString];
		if ([req respondsToSelector:@selector(URL)]) {
			id u = ((id (*)(id, SEL))objc_msgSend)(req, @selector(URL));
			if ([u isKindOfClass:[NSURL class]]) return [(NSURL *)u absoluteString];
			if ([u isKindOfClass:[NSString class]]) return (NSString *)u;
		}
		if ([req respondsToSelector:@selector(absoluteString)]) {
			id u = ((id (*)(id, SEL))objc_msgSend)(req, @selector(absoluteString));
			if ([u isKindOfClass:[NSString class]]) return (NSString *)u;
		}
	} @catch (NSException *e) { }
	return nil;
}

#ifndef SPEH_NO_LOG
static int gBadNavLogCount = 0;
static void SPEHLogBadNav(const char *tag, SEL cmd, NSString *url)
{
	if (gBadNavLogCount >= 12) return;
	gBadNavLogCount++;
	SPEHLog(@"[badurl] #%d %s -[%s] url=%@ page=%@", gBadNavLogCount, tag,
			sel_getName(cmd), url ?: @"(nil)", SPEHCurrentPageURL());
	if (gBadNavLogCount <= 4) {
		@try {
			SPEHLog(@"[badurl] #%d stack=%@", gBadNavLogCount,
					[[NSThread callStackSymbols] componentsJoinedByString:@" <- "]);
		} @catch (NSException *e) { }
	}
}
#endif

// — WKWebView -loadRequest:（返回 WKNavigation，拦下时回 nil 表示未启动导航）
static IMP gOrigWKLoadRequest = NULL;
static id SPEHWKLoadRequestHook(id self, SEL _cmd, id req)
{
	NSString *u = SPEHRequestURLString(req);
	if (SPEHURLStringIsMalformed(u)) {
#ifndef SPEH_NO_LOG
		SPEHLogBadNav("拦截", _cmd, u);
#endif
		return nil;
	}
	if (gOrigWKLoadRequest) return ((id (*)(id, SEL, id))gOrigWKLoadRequest)(self, _cmd, req);
	return nil;
}

// — TabDocument -loadRequest: / -_loadRequest:（返回类型不定，统一按 id 转发：
//   arm64 上 objc_msgSend 的返回值走同一个 x0，void 方法多读一个 x0 是安全的，反之不行）
static IMP gOrigTabLoadRequest = NULL;
static id SPEHTabLoadRequestHook(id self, SEL _cmd, id req)
{
	NSString *u = SPEHRequestURLString(req);
	if (SPEHURLStringIsMalformed(u)) {
#ifndef SPEH_NO_LOG
		SPEHLogBadNav("拦截", _cmd, u);
#endif
		return nil;
	}
	if (gOrigTabLoadRequest) return ((id (*)(id, SEL, id))gOrigTabLoadRequest)(self, _cmd, req);
	return nil;
}

static IMP gOrigTabLoadRequestUnderscore = NULL;
static id SPEHTabLoadRequestUnderscoreHook(id self, SEL _cmd, id req)
{
	NSString *u = SPEHRequestURLString(req);
	if (SPEHURLStringIsMalformed(u)) {
#ifndef SPEH_NO_LOG
		SPEHLogBadNav("拦截", _cmd, u);
#endif
		return nil;
	}
	if (gOrigTabLoadRequestUnderscore) return ((id (*)(id, SEL, id))gOrigTabLoadRequestUnderscore)(self, _cmd, req);
	return nil;
}

static void SPEHInstallBadURLNavigationHooks(void)
{
	Class wk = NSClassFromString(@"WKWebView");
	Class tab = NSClassFromString(@"TabDocument");

	BOOL wkOK = NO, tabOK = NO, tabUOK = NO;
	if (wk && class_getInstanceMethod(wk, @selector(loadRequest:))) {
		SPEHPatchInstanceMethod(wk, @selector(loadRequest:), (IMP)SPEHWKLoadRequestHook, &gOrigWKLoadRequest);
		wkOK = (gOrigWKLoadRequest != NULL);
	}
	if (tab && class_getInstanceMethod(tab, @selector(loadRequest:))) {
		SPEHPatchInstanceMethod(tab, @selector(loadRequest:), (IMP)SPEHTabLoadRequestHook, &gOrigTabLoadRequest);
		tabOK = (gOrigTabLoadRequest != NULL);
	}
	if (tab && class_getInstanceMethod(tab, @selector(_loadRequest:))) {
		SPEHPatchInstanceMethod(tab, @selector(_loadRequest:), (IMP)SPEHTabLoadRequestUnderscoreHook, &gOrigTabLoadRequestUnderscore);
		tabUOK = (gOrigTabLoadRequestUnderscore != NULL);
	}
	SPEHLog(@"[badurl] hook WKWebView loadRequest:=%d | TabDocument loadRequest:=%d _loadRequest:=%d",
			wkOK, tabOK, tabUOK);
}

// MARK: - 阅读器击杀（白名单精准命中）

static BOOL SPEHReturnNOHook(id self, SEL _cmd) { return NO; }

typedef struct {
	const char *clsName;
	const char *selName;
} SPEHReaderRule;

static const SPEHReaderRule kReaderRules[] = {
	{ "_SFReaderController",                    "isReaderAvailable" },
	{ "_SFWebProcessPlugInReaderEnabledPageController", "readerHasBeenActivatedRecently" },
	{ "WBSReaderAvailabilityCheckResult",       "isReaderAvailable" },
	{ "WBSReaderAvailabilityCheckResult",       "isReaderAvailableIgnoringDynamicFontSize" },
	{ "WBSReaderAvailabilityCheckResult",       "isReaderAvailableForAllPages" },
	{ "_SFReaderController",                    "isReaderAvailableForAllPages" },
	{ "_SFReaderController",                    "canShowReader" },
	{ "WBSAutomaticReaderActivationManager",    "isEnabled" },
};

static void SPEHInstallReaderHooks(void)
{
	if (!SPEHReaderKillEnabled()) { SPEHLog(@"[reader] disabled by prefs"); return; }

	int hit = 0, miss = 0;
	NSUInteger total = sizeof(kReaderRules) / sizeof(kReaderRules[0]);

	for (NSUInteger i = 0; i < total; i++) {
		const char *clsC = kReaderRules[i].clsName;
		const char *selC = kReaderRules[i].selName;
		Class cls = objc_getClass(clsC);
		if (!cls) { miss++; continue; }

		SEL sel = sel_getUid(selC);
		Method m = class_getInstanceMethod(cls, sel);
		if (!m || !SPEHMethodReturnsBool(m)) { miss++; continue; }

		MSHookMessageEx(cls, sel, (IMP)SPEHReturnNOHook, NULL);
		hit++;
	}

	if (hit == 0 || SPEHProbeEnabled()) {
		SPEHLog(@"[reader] 白名单 total=%lu hit=%d miss=%d", (unsigned long)total, hit, miss);
	}
}

// MARK: - 「App 内打开」浮层 + Smart App Banner
//
// 两件不同的东西：
//   ① 底部绿色胶囊「App 内打开 ×」是网页自绘 HTML 浮层 → JS 清
//   ② 顶部 Smart App Banner 是 Safari 原生横幅，由 apple-itunes-app meta 触发
//      → JS 删 meta（下次加载不再生成）+ 原生 view 层直接拆除（当前这次立刻消失）

static NSString *SPEHOpenInAppJS(void)
{
	static NSString *js = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		js = @"(function(){try{"
			 // 每个页面只做「一次性初始化」，重复注入不会重复挂监听器
			 "if(!window.__speh)window.__speh={ready:0,click:0,s:0,dirty:1};"
			 "var first=!window.__speh.ready;window.__speh.ready=1;"
			 "var r={m:0,e:0,link:0};"
			 // ① 删 apple-itunes-app / smartbanner meta（Smart App Banner 的触发源头）
			 "var killMeta=function(){var ms=document.querySelectorAll('meta[name=apple-itunes-app],meta[name=smartbanner]');"
			 "for(var i=0;i<ms.length;i++){try{ms[i].parentNode.removeChild(ms[i]);r.m++;}catch(q){}}};"
			 "killMeta();"
			 // meta 可能在文档开始时还没解析出来：只观察新插入的 META 节点，不做整树遍历
			 "if(!window.__speh.mo){try{var mo=new MutationObserver(function(muts){window.__speh.dirty=1;"
			 "for(var a=0;a<muts.length;a++){var ad=muts[a].addedNodes;"
			 "for(var b=0;b<ad.length;b++){var n=ad[b];if(!n||n.tagName!=='META')continue;"
			 "var nm=String((n.getAttribute&&n.getAttribute('name'))||'').toLowerCase();"
			 "if(nm==='apple-itunes-app'||nm==='smartbanner'){try{n.parentNode.removeChild(n);}catch(q){}}}}});"
			 // 0.9.8：同时观察 style/class 属性变化——浮层若是预置节点靠 CSS 显示（非动态插入），
			 // childList 捕获不到，必须靠 attributes 置脏，否则 dirty 方案会漏卡片。回调仅置标志，开销极小。
			 "mo.observe(document.documentElement||document,{childList:true,subtree:true,attributes:true,attributeFilter:['style','class']});"
			 "window.__speh.mo=mo;}catch(o){}}"
			 // ② 自定义 scheme 白名单：只有这些放行，其余（itms-apps/ms-bing/bingapp/weixin...）一律算「跳 App」
			 "var ok=function(h){var m=/^([a-z][a-z0-9+.\\-]*):/i.exec(String(h||''));"
			 "if(!m)return true;var sc=m[1].toLowerCase();"
			 "return sc==='http'||sc==='https'||sc==='about'||sc==='data'||sc==='blob'||sc==='file'"
			 "||sc==='javascript'||sc==='tel'||sc==='mailto'||sc==='sms'||sc==='facetime';};"
			 // ③ 统计当前页面里「会跳 App」的链接数量 —— 这个数是预判它会不会弹卡片的证据
			 "try{var as=document.querySelectorAll('a[href]');var lim=Math.min(as.length,300);"
			 "for(var i2=0;i2<lim;i2++){if(!ok(as[i2].getAttribute('href')))r.link++;}}catch(z){}"
			 // ④ 点击拦截：捕获阶段只读判断，命中才 preventDefault（不改网页其它行为）
			 "if(!window.__speh.click){window.__speh.click=1;"
			 "document.addEventListener('click',function(e){try{var t=e.target;"
			 "while(t&&t.tagName!=='A'){t=t.parentNode;}if(!t)return;"
			 "var h=t.getAttribute&&t.getAttribute('href');if(!ok(h)){"
			 "e.preventDefault();e.stopPropagation();window.__speh.s=(window.__speh.s||0)+1;}}catch(x){}},true);}"
			 // ⑤ 清网页自绘的「App 内打开」浮层（中英双关键字 + 只认 fixed/sticky/absolute + 宽度够宽）
			 // 0.9.8：DOM 无变动时跳过全树扫描；卡片延迟插入会由 MutationObserver 重新置脏，不漏（JS 内不用 // 注释以免吃掉拼接行）
			 "if(window.__speh.dirty){"
			 "var kws=['App 内打开','App内打开','在App内打开','在 App 内打开','打开App','打开 App','open in app','Open in App','OPEN IN APP'];"
			 "var els=document.querySelectorAll('body *');var wlim=Math.max(240,window.innerWidth*0.6);"
			 "for(var j=0;j<els.length;j++){var el=els[j];if(!el.parentNode)continue;"
			 "var t=(el.textContent||'').replace(/^\\s+|\\s+$/g,'');if(!t||t.length>60)continue;"
			 "var hit=false;for(var k=0;k<kws.length;k++){if(t.indexOf(kws[k])>=0){hit=true;break;}}"
			 "if(!hit)continue;"
			 "var cs=getComputedStyle(el);"
			 "if((cs.position==='fixed'||cs.position==='sticky')&&el.getBoundingClientRect().width>=wlim){"
			 "el.parentNode.removeChild(el);r.e++;}}"
			 "window.__speh.dirty=0;r.scan=1;}"
			 "return 'first='+(first?1:0)+' meta='+r.m+' el='+r.e+' link='+r.link"
			 "+' scan='+r.scan+' click='+window.__speh.click+' s='+(window.__speh.s||0);"
			 "}catch(err){return 'ERR:'+err;}})()";
	});
	return js;
}

@protocol SPEHWebViewJS <NSObject>
- (void)evaluateJavaScript:(NSString *)script completionHandler:(void (^)(id result, NSError *error))handler;
@end

// 解析 JS 回报字符串里的整数
static int SPEHJSInt(NSString *s, NSString *key)
{
	if (!s || !key) return -1;
	NSString *pat = [key stringByAppendingString:@"="];
	NSRange r = [s rangeOfString:pat];
	if (r.location == NSNotFound) return -1;
	NSUInteger i = r.location + r.length;
	int v = 0; BOOL got = NO;
	while (i < s.length) {
		unichar c = [s characterAtIndex:i];
		if (c < '0' || c > '9') break;
		v = v * 10 + (int)(c - '0');
		got = YES;
		i++;
	}
	return got ? v : -1;
}

static char kOpenInAppInjectStamp = 0;

// 0.9.5：同一 webView、同一 URL、300ms 内的重复调用合并成一次。
// didMoveToWindow 和 webView:didFinishNavigation: 会紧挨着触发，原来会连注入两遍。
// 超过 300ms 的照常注入 —— reload 同 URL 时是新文档，必须重注入，不能按 URL 永久跳过。
static BOOL SPEHShouldSkipInject(id webView)
{
	NSMutableDictionary *st = objc_getAssociatedObject(webView, &kOpenInAppInjectStamp);
	if (!st) return NO;
	NSString *lastURL = st[@"url"];
	NSTimeInterval last = [st[@"t"] doubleValue];
	if (!lastURL.length) return NO;
	NSString *curURL = nil;
	@try { curURL = [[webView valueForKey:@"URL"] absoluteString]; } @catch (NSException *e) { }
	return [lastURL isEqualToString:(curURL ?: @"")] &&
		   (CFAbsoluteTimeGetCurrent() - last) < 0.3;
}

static void SPEHMarkInjected(id webView)
{
	NSString *curURL = nil;
	@try { curURL = [[webView valueForKey:@"URL"] absoluteString]; } @catch (NSException *e) { }
	if (!curURL) return;
	objc_setAssociatedObject(webView, &kOpenInAppInjectStamp,
		[@{ @"url": curURL, @"t": @(CFAbsoluteTimeGetCurrent()) } mutableCopy],
		OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void SPEHApplyOpenInAppJSAttempt(id webView, int attempt);

static void SPEHApplyOpenInAppJS(id webView)
{
	// 0.10.0：开关下沉到函数内部，使注入 hook 可被深色模块共用（不再被外层 return 挡住）
	if (!SPEHOpenInAppKillEnabled()) return;
	SPEHApplyOpenInAppJSAttempt(webView, 0);
}

static void SPEHApplyOpenInAppJSAttempt(id webView, int attempt)
{
	if (!webView) return;
	if (SPEHShouldSkipInject(webView)) return;

	// 0.9.3：日志里那串「JS 执行失败 执行JavaScript返回结果的类型不受支持」全是
	// 快速连按返回时的空注入 —— webView 正在换页/已脱离窗口，evaluateJavaScript 会返回
	// WKErrorCode 5（结果类型不支持）。
	// 0.9.5：不再一丢了之 —— 刚上屏 / 刚换页的那一次补一次 0.35s 后的重试，
	// 否则这一页就整页没有 JS 防线（Bing 那几张卡片正好是这时候漏的）。
	BOOL notReady = NO;
	@try {
		if ([webView isKindOfClass:[UIView class]] && !((UIView *)webView).window) notReady = YES;
		if ([webView respondsToSelector:@selector(isLoading)] && [webView isLoading]) notReady = YES;
	} @catch (NSException *e) { }

	if (notReady) {
		if (attempt == 0) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
						   dispatch_get_main_queue(), ^{
				SPEHApplyOpenInAppJSAttempt(webView, attempt + 1);
			});
		}
		return;
	}

	SPEHMarkInjected(webView);

	@try {
		[(id<SPEHWebViewJS>)webView evaluateJavaScript:SPEHOpenInAppJS() completionHandler:^(id result, NSError *error) {
			if (error) {
				if (SPEHProbeEnabled()) SPEHLog(@"[openinapp] JS 执行失败 %@", error.localizedDescription);
				return;
			}
			NSString *r = [result isKindOfClass:[NSString class]] ? (NSString *)result : nil;
			if (!r) return;

			int first = SPEHJSInt(r, @"first");
			int meta  = SPEHJSInt(r, @"meta");
			int elems = SPEHJSInt(r, @"el");
			int link  = SPEHJSInt(r, @"link");
			int click = SPEHJSInt(r, @"click");
			int blocked = SPEHJSInt(r, @"s");
			int scanned = SPEHJSInt(r, @"scan");

			// 0.9.3：探针默认关闭。「就绪」是诊断用的每页一条，只在 probe 打开时打；
			// 「清理」只在真的动过手（删了 meta / 拆了浮层 / 拦了点击）时打，属于真事件，保留。
			if (first == 1 && SPEHProbeEnabled()) {
				SPEHLog(@"[openinapp] 就绪 link=%d meta=%d click=%d", link, meta, click);
			}
			// 0.9.8：探针打开时记录全树扫描是否真的发生，用于确认 dirty 去噪生效
			if (scanned == 1 && SPEHProbeEnabled()) {
				SPEHLog(@"[openinapp] 全树扫描执行 el=%d", elems);
			}
			if (meta > 0 || elems > 0 || blocked > 0) {
				SPEHLog(@"[openinapp] 清理 meta=%d el=%d 已拦点击=%d", meta, elems, blocked);
			}
		}];
	} @catch (NSException *e) { }
}

// ─── Smart App Banner：精准命中（0.9.2 恢复）─────────────────────────────
//
// 0.9.1 曾把这段整体删除，怀疑它与「扩展权限反复弹窗」有关。现已证实那次弹窗来自
// Extensions.plist / Neo-Noir local.db 里的畸形 origin（huayuarc.xn--cn -928...），
// 与本模块无关，因此按老板要求「只保留精准命中」原样恢复。
//
// 精准原则：只 hook 下面这 8 个**明确存在、明确语义**的方法，
// 绝不按类名通扫（0.6.0 的父子类重复 hook 曾导致自递归爆栈闪退）。
// 运行时会先 class_getInstanceMethod 判存在再挂，缺哪个就少挂哪个，不会挂错。

static IMP gOrigSetAppBanner = NULL;
static IMP gOrigSetAppSuggestionBanner = NULL;
static IMP gOrigDidFindAppBanner = NULL;
static IMP gOrigSetStoreBannersDisabled = NULL;
static IMP gOrigAppBannerGetter = NULL;
static IMP gOrigBCDidCompleteCheck = NULL;
static IMP gOrigBCPinTop = NULL;
static IMP gOrigBCRemoveBanner = NULL;

// 计数：证明这条链到底有没有被调用（老板要看"命中证据"）
static int gBannerHitSet = 0;
static int gBannerHitDidFind = 0;
static int gBannerHitBCCheck = 0;

static void SPEHSetAppBannerHook(id self, SEL _cmd, id banner)
{
	if (banner) {
		if (gBannerHitSet < 10) {
			gBannerHitSet++;
			SPEHLog(@"[smartbanner] 命中 setAppBanner: 丢弃 %@",
					NSStringFromClass(object_getClass(banner)));
		}
	}
	// 不转发：banner 对象永远进不了 TabDocument
}

static void SPEHSetAppSuggestionBannerHook(id self, SEL _cmd, id banner, BOOL pinned)
{
	if (banner && gBannerHitSet < 10) {
		gBannerHitSet++;
		SPEHLog(@"[smartbanner] 命中 setAppSuggestionBanner:isPinned: 丢弃 %@",
				NSStringFromClass(object_getClass(banner)));
	}
	// 不转发
}

static void SPEHDidFindAppBannerHook(id self, SEL _cmd, id content)
{
	if (gBannerHitDidFind < 10) {
		gBannerHitDidFind++;
		SPEHLog(@"[smartbanner] 命中 didFindAppBannerWithContent: 丢弃 %@",
				content ? NSStringFromClass(object_getClass(content)) : @"(nil)");
	}
	// 不转发：Safari 认为「没发现 app banner」
}

// appBanner getter 一律返回 nil：任何读它的渲染路径都拿不到 banner 对象
static id SPEHAppBannerGetterHook(id self, SEL _cmd)
{
	return nil;
}

static void SPEHSetStoreBannersDisabledHook(id self, SEL _cmd, BOOL value)
{
	// 无论 Safari 传什么，一律 YES
	if (gOrigSetStoreBannersDisabled) {
		((void (*)(id, SEL, BOOL))gOrigSetStoreBannersDisabled)(self, _cmd, YES);
	}
}

// BrowserController「检查完成 → 上屏」链路掐掉
static void SPEHBCDidCompleteCheckHook(id self, SEL _cmd, id tabDocument)
{
	if (gBannerHitBCCheck < 10) {
		gBannerHitBCCheck++;
		SPEHLog(@"[smartbanner] 命中 tabDocumentDidCompleteCheckForAppBanner:");
	}
	// 不转发
}

static void SPEHBCPinTopHook(id self, SEL _cmd, BOOL pinned, id tabDocument)
{
	// 不转发：不把横幅钉到顶部
}

static void SPEHBCRemoveBannerHook(id self, SEL _cmd, id tabDocument, BOOL animated)
{
	if (gOrigBCRemoveBanner) {
		((void (*)(id, SEL, id, BOOL))gOrigBCRemoveBanner)(self, _cmd, tabDocument, animated);
	}
}

static void SPEHInstallSmartAppBannerPreciseHooks(void)
{
	// 0.9.3 修：原来是 per-webView 的 `first` 判断，Safari 有多个 WKWebView，
	// 每个新 webView 挂窗口都会重装一遍 → 日志里「精准 hook 8 条」出现 7 次，
	// 同一 SEL 被反复 MSHookMessageEx 会把 orig 指向自己的上一层，迟早自递归。
	// 改成进程级只装一次。
	static BOOL installed = NO;
	if (installed) return;
	installed = YES;

	NSMutableArray *hit = [NSMutableArray array];

	Class tabCls = NSClassFromString(@"TabDocument");
	if (!tabCls) {
		SPEHLog(@"[smartbanner] TabDocument 未加载，跳过");
	} else {
		struct { const char *sel; IMP imp; IMP *orig; const char *label; } items[] = {
			{ "setAppBanner:",                    (IMP)SPEHSetAppBannerHook,            &gOrigSetAppBanner,           "setAppBanner:" },
			{ "setAppSuggestionBanner:isPinned:", (IMP)SPEHSetAppSuggestionBannerHook,  &gOrigSetAppSuggestionBanner, "setAppSuggestionBanner:isPinned:" },
			{ "didFindAppBannerWithContent:",     (IMP)SPEHDidFindAppBannerHook,        &gOrigDidFindAppBanner,       "didFindAppBannerWithContent:" },
			{ "setStoreBannersAreDisabled:",      (IMP)SPEHSetStoreBannersDisabledHook, &gOrigSetStoreBannersDisabled, "setStoreBannersAreDisabled:" },
			{ "appBanner",                        (IMP)SPEHAppBannerGetterHook,         &gOrigAppBannerGetter,        "appBanner" },
		};
		for (size_t i = 0; i < sizeof(items) / sizeof(items[0]); i++) {
			SEL sel = NSSelectorFromString([NSString stringWithUTF8String:items[i].sel]);
			if (class_getInstanceMethod(tabCls, sel)) {
				SPEHPatchInstanceMethod(tabCls, sel, items[i].imp, items[i].orig);
				[hit addObject:[NSString stringWithFormat:@"TabDocument -%s", items[i].label]];
			}
		}
	}

	Class bcCls = NSClassFromString(@"BrowserController");
	if (bcCls) {
		struct { const char *sel; IMP imp; IMP *orig; const char *label; } items[] = {
			{ "tabDocumentDidCompleteCheckForAppBanner:", (IMP)SPEHBCDidCompleteCheckHook, &gOrigBCDidCompleteCheck, "tabDocumentDidCompleteCheckForAppBanner:" },
			{ "setAppBannerPinnedToTop:forTabDocument:",  (IMP)SPEHBCPinTopHook,          &gOrigBCPinTop,          "setAppBannerPinnedToTop:forTabDocument:" },
			{ "removeAppBannerFromTabDocument:animated:", (IMP)SPEHBCRemoveBannerHook,    &gOrigBCRemoveBanner,    "removeAppBannerFromTabDocument:animated:" },
		};
		for (size_t i = 0; i < sizeof(items) / sizeof(items[0]); i++) {
			SEL sel = NSSelectorFromString([NSString stringWithUTF8String:items[i].sel]);
			if (class_getInstanceMethod(bcCls, sel)) {
				SPEHPatchInstanceMethod(bcCls, sel, items[i].imp, items[i].orig);
				[hit addObject:[NSString stringWithFormat:@"BrowserController -%s", items[i].label]];
			}
		}
	}

	SPEHLog(@"[smartbanner] 精准 hook %lu 条: %@", (unsigned long)hit.count,
			hit.count ? [hit componentsJoinedByString:@" | "] : @"(一条都没挂上)");
}

// MARK: - 「App 内打开」浮层的注入时机
//
// 0.9.1：Smart App Banner 的原生拦截代码（TabDocument appBanner / setAppBanner: /
// didFindAppBannerWithContent: / BrowserController 检查链路 / 视图清扫 / 类名探针）
// 已全部删除。老板实测这些 hook 与扩展权限反复弹窗的时间线重合，先全删掉排除干扰。
// 现在本模块只剩：WKWebView didMoveToWindow 时跑一次 JS，清网页自绘的「App 内打开」浮层
// 与 apple-itunes-app meta（纯 DOM 操作，不碰任何原生对象、不碰 configuration）。

static IMP gOrigWVDidMoveToWindow = NULL;

// 定义在地址栏手势模块里
static void SPEHNeutralizeURLBarSwipe(UIView *anchor, NSString *tag);

static void SPEHWVDidMoveToWindowHook(UIView *self, SEL _cmd)
{
	if (gOrigWVDidMoveToWindow) ((void (*)(id, SEL))gOrigWVDidMoveToWindow)(self, _cmd);
	if (!self.window) return;

	static char kInjected;
	BOOL first = !objc_getAssociatedObject(self, &kInjected);
	objc_setAssociatedObject(self, &kInjected, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	__weak UIView *weakSelf = self;

	// 地址栏横滑禁用：每次挂载都跑（标签栏会重建），两个时间点兜住懒加载出来的视图
	if (first) {
		for (NSNumber *d in @[ @1.2, @3.5 ]) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
				dispatch_get_main_queue(), ^{
					SPEHNeutralizeURLBarSwipe(weakSelf, [NSString stringWithFormat:@"%@s", d]);
				});
		}
	}

	// 装 banner 的精准 hook：只装一次（TabDocument 是单例级，重复装会重复 hook）
	if (first && SPEHSmartBannerKillEnabled()) {
		SPEHInstallSmartAppBannerPreciseHooks();
	}

	// 清「App 内打开」浮层与 apple-itunes-app meta（纯 JS，不碰原生）
	NSArray *delays = @[ @0.8, @2.5, @5.0 ];
	for (NSNumber *d in delays) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			SPEHApplyOpenInAppJS(weakSelf);
		});
	}
}

// 关键缺口修复（0.9.2）：
//   Safari 只有一个 WKWebView 反复复用，`didMoveToWindow` 只在第一次挂载时触发一次。
//   所以「导航到新页面后」上面的 JS 根本不会重跑 —— 这也是以前 JS 侧拦截时灵时不灵的根因。
//   TabDocument 自己是 webView 的 navigationDelegate，这里只做「转发 + 加载完成后跑一次 JS」，
//   不涉及任何 completion handler（0.8.2 崩溃是 decisionHandler 的 PAC 问题，这里没有）。
static IMP gOrigTabDidFinishNav = NULL;

static void SPEHTabDidFinishNavigationHook(id self, SEL _cmd, id webView, id navigation)
{
	if (gOrigTabDidFinishNav) {
		((void (*)(id, SEL, id, id))gOrigTabDidFinishNav)(self, _cmd, webView, navigation);
	}
	if (webView) {
		__weak id weakWV = webView;
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
			dispatch_get_main_queue(), ^{
				SPEHApplyOpenInAppJS(weakWV);
			});
	}
}

static void SPEHInstallOpenInAppHooks(void)
{
	if (!SPEHOpenInAppKillEnabled()) {
		SPEHLog(@"[inject] openinapp 关闭，不装注入 hook");
		return;
	}

	Class wkCls = NSClassFromString(@"WKWebView");
	if (!wkCls) { SPEHLog(@"[openinapp] WKWebView 未加载"); return; }

	SPEHPatchInstanceMethod(wkCls, @selector(didMoveToWindow), (IMP)SPEHWVDidMoveToWindowHook, &gOrigWVDidMoveToWindow);

	// 每次页面加载完成都补一次 JS（webView 被复用，didMoveToWindow 不会再触发）
	NSMutableArray *navHit = [NSMutableArray array];
	Class tabCls = NSClassFromString(@"TabDocument");
	if (tabCls) {
		for (NSString *sn in @[ @"webView:didFinishNavigation:", @"_webView:didFinishNavigation:" ]) {
			SEL sel = NSSelectorFromString(sn);
			if (class_getInstanceMethod(tabCls, sel)) {
				SPEHPatchInstanceMethod(tabCls, sel, (IMP)SPEHTabDidFinishNavigationHook, &gOrigTabDidFinishNav);
				[navHit addObject:sn];
				break;   // 只挂一个，避免同一 selector 重复替换
			}
		}
	}

	SPEHLog(@"[openinapp] hook didMoveToWindow=%s nav=%@",
			gOrigWVDidMoveToWindow ? "ok" : "FAILED",
			navHit.count ? [navHit componentsJoinedByString:@","] : @"(无 didFinishNavigation)");
}

// MARK: - 「在 App 中打开 / 继续」提示（Bing 等通用链接）
//
// 老板实测：用 Bing 搜索时 Safari 会从底部弹一张「继续搜索」卡片，
// 一行「微软必应 APP → 打开」，一行「浏览器 → 继续」。这是 iOS 的 App Link 提示，
// 由 Safari 在「当前页面对应某个 App 的 universal link」时主动弹出，跟网页自身无关。
//
// 0.8.0 日志实证（真机 dump 的方法名，之前猜的 +appLinkWithURL: / -isEnabledForURL: 都不存在）：
//   WBSAppLink 实例: _synchronouslyFetchAppLinkWithError:、_getAppLinkWithCompletionHandler:、
//                    decideOpenStrategyWithCompletionHandler:
//   LSAppLink 类方法: getAppLinkWithURL:completionHandler:、appLinksWithURL:limit:error:、
//                    appLinksWithURL:limit:includeLinksForCurrentApplication:error:
// 所以按真名来：让这两层都拿不到任何 AppLink，Safari 就只剩「在浏览器继续」。

static BOOL SPEHAppLinkKillEnabled(void) { return SPEHBoolPref(@"killAppLinkPrompt", YES); }

static IMP gOrigFetchAppLinkSync = NULL;
static IMP gOrigGetAppLinkWithURL = NULL;
static IMP gOrigAppLinksWithURL = NULL;
static IMP gOrigAppLinksWithURL2 = NULL;
static IMP gOrigIncludeAppLinkActions = NULL;
static int gAppLinkLogCount = 0;

static void SPEHPatchClassMethod(Class cls, SEL sel, IMP newImp, IMP *outOld)
{
	if (!cls) return;
	MSHookMessageEx(object_getClass(cls), sel, newImp, outOld);
}

// 老板要求：这个卡片是「偶尔才弹」，必须能确定拦截是否真的命中。
// 0.9.3：默认只在「值得记」的时候落盘 —— ① probe 打开时全记；② 命中 bing 域名的查询永远记
// （就是那张「微软必应 APP / 浏览器 继续」卡片的来源，留着当长期证据）。
// 其它站点每次返回 nil 的记录属探针，默认不写，避免把日志刷满。
static BOOL SPEHURLIsBing(id url)
{
#ifdef SPEH_NO_LOG
	return NO;   // 只为日志服务，无日志变体直接返回
#else
	NSString *s = nil;
	@try {
		if ([url isKindOfClass:[NSURL class]]) s = [(NSURL *)url absoluteString];
		else if ([url isKindOfClass:[NSString class]]) s = url;
		else if ([url respondsToSelector:@selector(absoluteString)]) s = [url valueForKey:@"absoluteString"];
	} @catch (NSException *e) { }
	return s ? ([s rangeOfString:@"bing." options:NSCaseInsensitiveSearch].location != NSNotFound) : NO;
#endif
}

// 0.9.5：日志去噪。日志实测 Bing 每翻一页会对**同一个结果页**重复查 2~6 次
// （first=19 连查 6 次），每次都要把 200+ 字符的长 URL 格式化成 NSString，这才是这块的主要开销。
// 改成按「接口 + URL 去掉 query」去重：同 key 只写首条，之后每累计 10 次写一行汇总。
// 证据力不变 —— 「这个域名查过、并且返回 nil」这条事实仍然完整保留。
// 0.9.9 编译修复：这三个符号只服务于写日志的去重；no-log 变体整体不编译，
// 否则 -Wunused-function/-Wunused-variable 在 -Werror 下会失败（0.9.8 GitHub 端提交即栽在这里）。
#ifndef SPEH_NO_LOG
static NSMutableSet *gAppLinkSeen = nil;
static int gAppLinkSuppress = 0;

static NSString *SPEHAppLinkKey(NSString *kind, id url)
{
	NSString *s = @"";
	@try {
		if ([url isKindOfClass:[NSURL class]]) s = [(NSURL *)url absoluteString];
		else if ([url isKindOfClass:[NSString class]]) s = url;
		else if ([url respondsToSelector:@selector(absoluteString)]) s = [url valueForKey:@"absoluteString"];
	} @catch (NSException *e) { }
	NSRange q = [s rangeOfString:@"?"];
	if (q.location != NSNotFound) s = [s substringToIndex:q.location];
	if (s.length > 120) s = [s substringToIndex:120];
	return [(kind ?: @"") stringByAppendingString:s];
}
#endif

// 返回 YES 表示「这一条是新页面，值得写日志」；NO 表示同一页的重复查询，已合并计数。
static BOOL SPEHAppLinkLogOnce(NSString *kind, id url)
{
#ifdef SPEH_NO_LOG
	return NO;   // 无日志变体：连去重查表的开销一并跳过
#else
	// 0.9.8 优化：AppLink 查询可能在后台线程并发，NSMutableSet 读写加锁；
	// 用固定 token 做锁（gAppLinkSeen 初始为 nil 时 @synchronized(nil) 不加锁，会失效）
	static dispatch_once_t onceToken;
	static id seenLock = nil;
	dispatch_once(&onceToken, ^{
		gAppLinkSeen = [NSMutableSet set];
		seenLock = [NSObject new];
	});
	@synchronized (seenLock) {
		NSString *key = SPEHAppLinkKey(kind, url);
		if ([gAppLinkSeen containsObject:key]) {
			gAppLinkSuppress++;
			int sup = gAppLinkSuppress;
			if (sup % 10 == 0) {
				SPEHLog(@"[applink] 同页重复查询累计 %d 次（明细已省略）", sup);
			}
			return NO;
		}
		if (gAppLinkSeen.count > 200) [gAppLinkSeen removeAllObjects];   // 防无限增长
		[gAppLinkSeen addObject:key];
		gAppLinkSuppress = 0;
		return YES;
	}
#endif
}

static void SPEHAppLinkLog(NSString *fmt, ...)
{
#ifdef SPEH_NO_LOG
	return;
#else
	if (gAppLinkLogCount >= 200) return;
	gAppLinkLogCount++;
	va_list ap;
	va_start(ap, fmt);
	NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);
	SPEHLog(@"[applink] #%d %@", gAppLinkLogCount, msg);
#endif
}

// -[WBSAppLink _synchronouslyFetchAppLinkWithError:] -> nil
static id SPEHFetchAppLinkSyncHook(id self, SEL _cmd, NSError **error)
{
	if (SPEHAppLinkKillEnabled()) {
		if (SPEHProbeEnabled()) {
			if (SPEHAppLinkLogOnce(@"sync", self)) SPEHAppLinkLog(@"同步取 AppLink → nil");
		}
		return nil;
	}
	if (gOrigFetchAppLinkSync) return ((id (*)(id, SEL, NSError **))gOrigFetchAppLinkSync)(self, _cmd, error);
	return nil;
}

// +[LSAppLink appLinksWithURL:limit:error:] -> 空数组
static id SPEHAppLinksWithURLHook(id self, SEL _cmd, id url, NSUInteger limit, NSError **error)
{
	if (SPEHAppLinkKillEnabled()) {
		if (SPEHProbeEnabled()) {
			if (SPEHAppLinkLogOnce(@"list", url)) SPEHAppLinkLog(@"查询 AppLink 列表 %@ → 空", url);
		}
		return @[];
	}
	if (gOrigAppLinksWithURL) return ((id (*)(id, SEL, id, NSUInteger, NSError **))gOrigAppLinksWithURL)(self, _cmd, url, limit, error);
	return @[];
}

static id SPEHAppLinksWithURL2Hook(id self, SEL _cmd, id url, NSUInteger limit, BOOL includeCurrent, NSError **error)
{
	if (SPEHAppLinkKillEnabled()) {
		if (SPEHProbeEnabled()) {
			if (SPEHAppLinkLogOnce(@"list2", url)) SPEHAppLinkLog(@"查询 AppLink 列表(含当前App) %@ → 空", url);
		}
		return @[];
	}
	if (gOrigAppLinksWithURL2) return ((id (*)(id, SEL, id, NSUInteger, BOOL, NSError **))gOrigAppLinksWithURL2)(self, _cmd, url, limit, includeCurrent, error);
	return @[];
}

// +[LSAppLink getAppLinkWithURL:completionHandler:] -> 回调 (nil, nil)
static void SPEHGetAppLinkHook(id self, SEL _cmd, id url, id completion)
{
	if (SPEHAppLinkKillEnabled()) {
		// 0.9.5：先走过去重（一次字典查表），只有「新页面」才继续算域名 / 格式化长 URL。
		// 同一页的重复查询到这里就结束 —— 不再做 rangeOfString，也不再拼 200+ 字符的日志串。
		BOOL fresh = SPEHAppLinkLogOnce(@"async", url);
		// Bing 的查询永远留证（那张「微软必应 APP / 浏览器 继续」卡片的来源）。
		if (fresh && (SPEHProbeEnabled() || SPEHURLIsBing(url))) {
			SPEHAppLinkLog(@"异步取 AppLink %@ → nil", url);
		}
		if (completion) {
			void (^cb)(id, id) = completion;
			@try { cb(nil, nil); } @catch (NSException *e) { }
		}
		return;
	}
	if (gOrigGetAppLinkWithURL) ((void (*)(id, SEL, id, id))gOrigGetAppLinkWithURL)(self, _cmd, url, completion);
}

static BOOL SPEHIncludeAppLinkActionsHook(id self, SEL _cmd, id webView, id element)
{
	if (SPEHAppLinkKillEnabled()) return NO;   // 分享菜单里也不出现「在 App 中打开」
	if (gOrigIncludeAppLinkActions) return ((BOOL (*)(id, SEL, id, id))gOrigIncludeAppLinkActions)(self, _cmd, webView, element);
	return NO;
}

static void SPEHInstallAppLinkHooks(void)
{
	if (!SPEHAppLinkKillEnabled()) { SPEHLog(@"[applink] disabled by prefs"); return; }

	NSMutableArray *hit = [NSMutableArray array];

	Class wbsCls = NSClassFromString(@"WBSAppLink");
	if (wbsCls) {
		SEL sel = NSSelectorFromString(@"_synchronouslyFetchAppLinkWithError:");
		if (class_getInstanceMethod(wbsCls, sel)) {
			SPEHPatchInstanceMethod(wbsCls, sel, (IMP)SPEHFetchAppLinkSyncHook, &gOrigFetchAppLinkSync);
			[hit addObject:@"WBSAppLink -_synchronouslyFetchAppLinkWithError:"];
		}
	}

	Class lsCls = NSClassFromString(@"LSAppLink");
	if (lsCls) {
		SEL s1 = NSSelectorFromString(@"getAppLinkWithURL:completionHandler:");
		if (class_getClassMethod(lsCls, s1)) {
			SPEHPatchClassMethod(lsCls, s1, (IMP)SPEHGetAppLinkHook, &gOrigGetAppLinkWithURL);
			[hit addObject:@"LSAppLink +getAppLinkWithURL:completionHandler:"];
		}
		SEL s2 = NSSelectorFromString(@"appLinksWithURL:limit:error:");
		if (class_getClassMethod(lsCls, s2)) {
			SPEHPatchClassMethod(lsCls, s2, (IMP)SPEHAppLinksWithURLHook, &gOrigAppLinksWithURL);
			[hit addObject:@"LSAppLink +appLinksWithURL:limit:error:"];
		}
		SEL s3 = NSSelectorFromString(@"appLinksWithURL:limit:includeLinksForCurrentApplication:error:");
		if (class_getClassMethod(lsCls, s3)) {
			SPEHPatchClassMethod(lsCls, s3, (IMP)SPEHAppLinksWithURL2Hook, &gOrigAppLinksWithURL2);
			[hit addObject:@"LSAppLink +appLinksWithURL:limit:includeLinksForCurrentApplication:error:"];
		}
	}

	// 0.9.8：只挂第一个命中，避免 TabDocument / _SFTabDocument 或两个 SEL 同时命中时
	// 共用一个 gOrigIncludeAppLinkActions 导致 orig 被覆盖（0.6.0 同类自递归隐患）
	BOOL includeHooked = NO;
	for (NSString *cn in @[ @"TabDocument", @"_SFTabDocument" ]) {
		if (includeHooked) break;
		Class tabCls = NSClassFromString(cn);
		if (!tabCls) continue;
		for (NSString *sn in @[ @"_webView:shouldIncludeAppLinkActionsForElement:",
								@"webView:shouldIncludeAppLinkActionsForElement:" ]) {
			SEL sel = NSSelectorFromString(sn);
			if (class_getInstanceMethod(tabCls, sel)) {
				SPEHPatchInstanceMethod(tabCls, sel, (IMP)SPEHIncludeAppLinkActionsHook, &gOrigIncludeAppLinkActions);
				[hit addObject:[NSString stringWithFormat:@"%@ -%@", cn, sn]];
				includeHooked = YES;
				break;
			}
		}
	}

	SPEHLog(@"[applink] hook %lu 条: %@", (unsigned long)hit.count,
			hit.count ? [hit componentsJoinedByString:@" | "] : @"(未命中任何方法)");
}

// MARK: - （已删除）返回后滚动恢复模块
//
// 0.9.4：老板「我现在不用元宝，卡顿那些代码都删除」 ⇒ 整模块移除。
// 删掉的东西：
//   · -[WKWebView goBack]/goForward/reload/reloadFromOrigin/loadRequest: 五个 hook
//   · 2.5s 后退窗口「吞 reload / 吞同 URL loadRequest」
//   · SPEHResetScroll 三次（0.3/0.9/1.8s）复位 scrollEnabled / pan 的兜底
//   · 对应 prefs 开关 fixBackScroll 与 CI 校验串
// 为什么删：这套只为「返回后滑不动」的 SPA 站点（元宝）加的，而且左滑手势返回
// 根本不走 -[WKWebView goBack]，对它本来就没生效。留着只是多 5 个 WKWebView hook 面。

// MARK: - 禁用底部地址栏左右滑动切页
//
// 老板实测：在底部输入网址/搜索的地址栏上左右滑，会切到上一页/下一页，极易误触。
// 做法：hook -[UIView addGestureRecognizer:]，只对「地址栏/工具栏」这一类 host 上的
// 滑动手势生效（UISwipeGestureRecognizer，以及 URL 输入区上的 UIPanGestureRecognizer），
// 直接不挂 + 置 disabled。页面滚动用的是 WKWebView 内部 scrollView 的 pan，
// 不经过这里，所以不影响网页滚动。

static BOOL SPEHURLBarSwipeKillEnabled(void) { return SPEHBoolPref(@"killURLBarSwipe", YES); }

static BOOL SPEHHostLooksLikeURLBar(NSString *cls)
{
	if (!cls.length) return NO;
	static NSString *const kws[] = { @"URL", @"Address", @"UnifiedBar", @"Toolbar", @"TextBar", @"LocationBar" };
	for (unsigned i = 0; i < sizeof(kws) / sizeof(kws[0]); i++) {
		if ([cls rangeOfString:kws[i]].location != NSNotFound) return YES;
	}
	return NO;
}

static IMP gOrigAddGesture = NULL;

// 0.9.5：addGestureRecognizer: 是 UIView 级别的全局 hook，Safari 里调用非常频繁。
// 原来每次都调 NSStringFromClass + 最多 8 次 rangeOfString 做类名匹配 —— 现在按 Class 缓存结果，
// 命中缓存后只剩一次字典查表（探针关闭时连类名字符串都不构造）。
// flags: bit0 = 类名像地址栏；bit1 = 类名含 URL / Address（pan 只在这些类上禁）
static NSMutableDictionary *gHostClsFlags = nil;

static int SPEHHostClsFlags(Class c)
{
	if (!c) return 0;
	// 0.9.8 优化：addGestureRecognizer: 偶发非主线程调用，NSMutableDictionary 读写加锁。
	// 同样用固定 token 做锁；命中缓存后一次字典查表即返回，锁粒度极小。
	static dispatch_once_t onceToken;
	static id hostLock = nil;
	dispatch_once(&onceToken, ^{
		gHostClsFlags = [NSMutableDictionary dictionary];
		hostLock = [NSObject new];
	});
	@synchronized (hostLock) {
		NSValue *key = [NSValue valueWithPointer:(__bridge const void *)c];
		NSNumber *cached = gHostClsFlags[key];
		if (cached) return cached.intValue;

		NSString *name = NSStringFromClass(c);
		int flags = 0;
		if (SPEHHostLooksLikeURLBar(name)) flags |= 1;
		if ([name rangeOfString:@"URL"].location != NSNotFound ||
			[name rangeOfString:@"Address"].location != NSNotFound) flags |= 2;

		if (gHostClsFlags.count > 300) [gHostClsFlags removeAllObjects];
		gHostClsFlags[key] = @(flags);
		return flags;
	}
}

// 胶囊栏 pan 标记 + 横向分量清零（保留纵向）
static char kCapsulePanTag = 0;
static IMP gOrigPanSetTranslation = NULL;

static void SPEHPanSetTranslationHook(UIPanGestureRecognizer *self, SEL _cmd, CGPoint t, UIView *view)
{
	if (objc_getAssociatedObject(self, &kCapsulePanTag) && SPEHURLBarSwipeKillEnabled()) {
		if (fabs(t.x) > fabs(t.y)) t.x = 0.0;
	}
	if (gOrigPanSetTranslation) {
		((void (*)(id, SEL, CGPoint, UIView *))gOrigPanSetTranslation)(self, _cmd, t, view);
	}
}

static void SPEHEnhanceAddGestureHook(UIView *self, SEL _cmd, UIGestureRecognizer *gr)
{
	// 先按手势类型快速过滤（绝大多数调用在这里就返回，开销可忽略），
	// 再做类名匹配（已按 Class 缓存）。
	if (gr &&
		([gr isKindOfClass:[UISwipeGestureRecognizer class]] ||
		 [gr isKindOfClass:[UIPanGestureRecognizer class]]) &&
		SPEHURLBarSwipeKillEnabled()) {
		@try {
			Class hostC = object_getClass(self);
			int flags = SPEHHostClsFlags(hostC);
			if (flags & 1) {
				BOOL isSwipe = [gr isKindOfClass:[UISwipeGestureRecognizer class]];
				// pan 只在明确的地址输入控件上禁，避免误伤工具栏其它交互
				BOOL isPanOnURL = [gr isKindOfClass:[UIPanGestureRecognizer class]] && (flags & 2);

				if (isSwipe || isPanOnURL) {
					gr.enabled = NO;
					if (SPEHProbeEnabled()) {
						SPEHLog(@"[urlswipe] 已禁用 %@ on %@",
								NSStringFromClass(object_getClass(gr)), NSStringFromClass(hostC));
					}
					return;   // 不转发 = 手势根本没挂上
				}
			}
			if (SPEHProbeEnabled() && [gr isKindOfClass:[UISwipeGestureRecognizer class]]) {
				// 只记一次，用来确认地址栏的真实类名（下一版可按真名收紧）
				static NSMutableSet *seen = nil;
				static dispatch_once_t once;
				dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
				NSString *key = [NSString stringWithFormat:@"%@|%ld", NSStringFromClass(hostC),
					(long)((UISwipeGestureRecognizer *)gr).direction];
				if (![seen containsObject:key] && seen.count < 40) {
					[seen addObject:key];
					SPEHLog(@"[urlswipe] 探针 swipe 挂到 %@ direction=%ld（未拦截）",
							NSStringFromClass(hostC), (long)((UISwipeGestureRecognizer *)gr).direction);
				}
			}
		} @catch (NSException *e) { }
	}
	if (gOrigAddGesture) ((void (*)(id, SEL, id))gOrigAddGesture)(self, _cmd, gr);
}

static void SPEHInstallURLBarSwipeHooks(void)
{
	if (!SPEHURLBarSwipeKillEnabled()) { SPEHLog(@"[urlswipe] disabled by prefs"); return; }

	SPEHPatchInstanceMethod([UIView class], NSSelectorFromString(@"addGestureRecognizer:"),
		(IMP)SPEHEnhanceAddGestureHook, &gOrigAddGesture);

	// 0.6.1 日志实证：底部地址栏的真实结构是 SFCapsuleNavigationBar / SFCapsuleCollectionView，
	// 横滑切页不是 UISwipeGestureRecognizer，而是这个胶囊横向滚动视图的 pan。
	// 所以按类名含 URL/Bar 去拦手势永远拦不到 —— 必须直接对胶囊视图动手。
	SPEHPatchInstanceMethod([UIPanGestureRecognizer class], NSSelectorFromString(@"setTranslation:inView:"),
		(IMP)SPEHPanSetTranslationHook, &gOrigPanSetTranslation);

	SPEHLog(@"[urlswipe] hook addGestureRecognizer=%s panSetTranslation=%s",
			gOrigAddGesture ? "ok" : "FAILED", gOrigPanSetTranslation ? "ok" : "FAILED");
}

// 找到胶囊栏，把它所有 pan 打上标记；之后 setTranslation 里只吃掉横向分量，
// 纵向（上拉展开标签页网格）不受影响。

// 找到胶囊栏/底部工具条，直接把「横滑切页」那颗手势本体掐死。
// 0.6.2 日志实证：标记了 7 个 pan，但 setTranslation:inView: 一条都没触发
// → 真正处理横滑的是 UIScrollView 自己的 _UIScrollViewPanGestureRecognizer
//   （子类重写了 setTranslation，父类 hook 拦不到），或者根本不走 setTranslation。
// 所以改成两手：① 带横向翻页能力的 scrollView 直接 scrollEnabled=NO
//              ② 条状视图上的 pan/swipe 手势 enabled=NO（它就是切页那一颗）

static int gKilledRecognizers = 0;

static BOOL SPEHBarAreaView(UIView *v, CGFloat winH)
{
	if (!v) return NO;
	NSString *cls = NSStringFromClass(object_getClass(v));
	if ([cls rangeOfString:@"SFCapsule"].location != NSNotFound) return YES;
	if ([cls rangeOfString:@"SFUnifiedBar"].location != NSNotFound) return YES;
	if ([cls rangeOfString:@"SFUnifiedTabBar"].location != NSNotFound) return YES;
	if ([cls isEqualToString:@"BrowserToolbar"]) return YES;

	// 兜底按位置判定：贴着屏幕底部、高度像一条工具栏
	CGRect f = v.frame;
	if (f.size.height > 0 && f.size.height <= 140 && f.origin.y >= winH - 200) return YES;
	return NO;
}

static void SPEHKillBarSwipes(UIView *v, CGFloat winH, int depth)
{
	if (!v || depth > 8) return;

	if (SPEHBarAreaView(v, winH)) {
		NSString *cls = NSStringFromClass(object_getClass(v));

		// ① 能横向翻页的 scrollView：直接关掉滚动
		if ([v isKindOfClass:[UIScrollView class]]) {
			UIScrollView *sv = (UIScrollView *)v;
			if (sv.contentSize.width > sv.bounds.size.width * 1.15 && sv.scrollEnabled) {
				sv.scrollEnabled = NO;
				if (SPEHProbeEnabled()) {
					SPEHLog(@"[urlswipe] 关闭横向滚动 %@ contentW=%.0f boundsW=%.0f",
							cls, sv.contentSize.width, sv.bounds.size.width);
				}
			}
		}

		// ② 条状视图上的 pan / swipe：本体禁用
		NSArray *grs = nil;
		@try { grs = [v gestureRecognizers]; } @catch (NSException *e) { }
		for (UIGestureRecognizer *g in grs) {
			if (!([g isKindOfClass:[UIPanGestureRecognizer class]] ||
				  [g isKindOfClass:[UISwipeGestureRecognizer class]])) continue;
			if (!g.enabled) continue;
			g.enabled = NO;
			gKilledRecognizers++;
			if (SPEHProbeEnabled() && gKilledRecognizers <= 30) {
				SPEHLog(@"[urlswipe] 禁用 %@ on %@", NSStringFromClass(object_getClass(g)), cls);
			}
		}
	}

	for (UIView *s in [v subviews]) SPEHKillBarSwipes(s, winH, depth + 1);
}

static void SPEHNeutralizeURLBarSwipe(UIView *anchor, NSString *tag)
{
	if (!anchor || !SPEHURLBarSwipeKillEnabled()) return;
	UIView *root = anchor.window ?: anchor;
	@try {
		CGFloat winH = root.bounds.size.height;
		gKilledRecognizers = 0;
		SPEHKillBarSwipes(root, winH, 0);

		static NSMutableSet *seen = nil;
		static dispatch_once_t once;
		dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
		NSString *key = [NSString stringWithFormat:@"%@|%d", tag, gKilledRecognizers];
		if (SPEHProbeEnabled() && ![seen containsObject:key] && seen.count < 12) {
			[seen addObject:key];
			SPEHLog(@"[urlswipe] %@ 禁用条状手势 %d 个", tag, gKilledRecognizers);
		}
	} @catch (NSException *e) { }
}

// MARK: - 入口

%ctor
{
	@autoreleasepool {
		if (!SPEHEnabled()) return;

		SPEHLog(@"==============================================");
		SPEHLog(@"Safari16Enhance " SPEH_VERSION " loaded, pid=%d", getpid());
#ifndef SPEH_NO_LOG
		SPEHLog(@"log file = %@", SPEHLogPath());
#endif
		// 0.12.5：必须在任何 hook/WebExtension 控制器初始化之前洗掉非法 origin key，
		// 否则 Safari 已经把那条坏 pattern 读进内存，清磁盘就没意义了。
		int sanitized = SPEHSanitizeExtensionPlist();
		SPEHLog(@"[extperm] 权限表净化 removed=%d（0=无脏数据 -1..-6=异常码）", sanitized);
		(void)sanitized;   // no-log 变体里 SPEHLog 是空宏，避免 -Wunused 被 -Werror 拦下

		// 0.12.8：全盘扫 + 修。SafariTabs.db 里那条 bookmarks 已改掉，弹窗却还在，
		// 说明这个 origin 在 WebKit / AppGroup 侧另有副本 —— 这次不猜目录，直接全扫。
		// 第一批（Safari / WebKit / Preferences / 容器）体积小，同步跑，确保早于会话恢复。
		int wideFixed = -1;
		NSString *wideReport = SPEHScanAndPurgeBadToken(&wideFixed);
		SPEHLog(@"[badscan] 命中: %@", wideReport);
		SPEHLog(@"[badscan] 已净化文件数=%d", wideFixed);
		(void)wideFixed;

		// 第二批：AppGroup 有上百个组、体量大，扔后台线程，免得拖慢启动。
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			NSArray *slowRoots = @[ @"/var/mobile/Containers/Shared/AppGroup" ];
			int f = -1;
			NSString *rep = SPEHScanAndPurgeBadTokenInRoots(slowRoots, &f);
			SPEHLog(@"[badscan][AppGroup] 命中: %@ / 净化=%d", rep, f);
			(void)f;
		});

		// 0.12.5：启动后扫两遍，把 URL 就是那串畸形内容的标签页关掉（源头在会话恢复里）。
		for (NSNumber *delay in @[ @3.0, @10.0 ]) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
						   dispatch_get_main_queue(), ^{
				int closed = SPEHCloseBadTabs();
				SPEHLog(@"[extperm] 清扫畸形标签页 closed=%d（-1..-4=枚举失败码）", closed);
				(void)closed;
				// 库有可能被 Safari 重新写入过，再全盘清一遍（幂等）
				int againFixed = -1;
				NSString *againReport = SPEHScanAndPurgeBadToken(&againFixed);
				SPEHLog(@"[badscan] 复清命中: %@ / 净化=%d", againReport, againFixed);
				(void)againFixed;
			});
		}

#ifndef SPEH_NO_LOG
		// 0.12.6：进程内扫 Safari 共享目录（SSH 读不到的 datavault 区），定位坏串的持久化落点
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
					   dispatch_get_main_queue(), ^{
			SPEHLog(@"[extperm] 共享目录命中: %@", SPEHScanSafariSharedDir());
		});
#endif
		SPEHLog(@"dialog=%d reader=%d openinapp=%d smartbanner=%d applink=%d probe=%d",
				SPEHDialogKillEnabled(), SPEHReaderKillEnabled(),
				SPEHOpenInAppKillEnabled(), SPEHSmartBannerKillEnabled(),
				SPEHAppLinkKillEnabled(), SPEHProbeEnabled());

		SPEHInstallSFDialogHooks();
		SPEHInstallAppOpenDialogHooks();
		SPEHInstallBadURLNavigationHooks();
#ifndef SPEH_NO_LOG
		// 0.12.2 诊断：枚举权限相关类名，下一版据此精准 hook 权限判定入口
		SPEHLog(@"[extperm] 权限相关类: %@", SPEHScanPermissionClasses());
#endif
		SPEHInstallReaderHooks();
		SPEHInstallOpenInAppHooks();
		SPEHInstallAppLinkHooks();
		SPEHInstallURLBarSwipeHooks();
	}
}
