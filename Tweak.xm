// Safari16Enhance 0.14.3 - iOS 16 Safari 增强
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

#define SPEH_VERSION "0.14.3"

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

static IMP gOrigPresentDialog = NULL;
static void SPEHPresentDialogHook(id self, SEL _cmd, id dialog)
{
	NSString *desc = SPEHDialogDescribe(dialog);
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
			 // 0.13.5：App 引流卡片特征词（Bing / 起点通用），MO 即时拆除与全树扫描共用
			 "var KWS=['App 内打开','App内打开','在App内打开','在 App 内打开','打开App','打开 App','open in app','Open in App','OPEN IN APP',"
			 "'继续搜索','搜你所想','搜你所想，有求必应','搜你所想,有求必应','微软必应APP','使用必应应用搜索','在必应应用中打开',"
			 "'继续浏览精彩内容','在此处浏览','起点读书APP','海量好书','新人免费','免费读',"
			 "'打开稀土掘金','稀土掘金APP','去APP查看','去App查看','在APP中打开','在App中打开','APP内打开','继续浏览'];"
			 // 把含特征词的节点整块拆掉：向上找 fixed/absolute/sticky 或全宽容器，排除 body/script
			 "var rip=function(node){try{var bx=node,dp=0,root=null;"
			 "while(bx&&bx.nodeType===1&&dp<10){var bs=getComputedStyle(bx);"
			 "if(bs.position==='fixed'||bs.position==='sticky'||bs.position==='absolute'){root=bx;break;}"
			 "if(bx.getBoundingClientRect().width>=Math.max(240,window.innerWidth*0.6)){root=bx;break;}"
			 "bx=bx.parentNode;dp++;}"
			 "if(!root)root=node;if(root===document.body||root===document.documentElement)root=node;"
			 "if(root.parentNode){root.parentNode.removeChild(root);r.e++;}}catch(q){}};"
			 // 只看新增节点的 textContent，命中特征词才 rip；不做全树遍历，开销与节点数成正比
			 "var hitKw=function(txt){if(!txt||txt.length>200)return false;for(var z=0;z<KWS.length;z++)"
			 "if(txt.indexOf(KWS[z])>=0)return true;return false;};"
			 // ① 删 apple-itunes-app / smartbanner meta（Smart App Banner 的触发源头）
			 "var killMeta=function(){var ms=document.querySelectorAll('meta[name=apple-itunes-app],meta[name=smartbanner]');"
			 "for(var i=0;i<ms.length;i++){try{ms[i].parentNode.removeChild(ms[i]);r.m++;}catch(q){}}};"
			 "killMeta();"
			 // meta 可能在文档开始时还没解析出来：只观察新插入的 META 节点，不做整树遍历
			 "if(!window.__speh.mo){try{var mo=new MutationObserver(function(muts){window.__speh.dirty=1;"
			 "for(var a=0;a<muts.length;a++){var ad=muts[a].addedNodes;"
			 "for(var b=0;b<ad.length;b++){var n=ad[b];if(!n)continue;"
			 // 文本节点：nodeValue 是纯文本，匹配命中就连父节点一起拆（最廉价路径）
			 "if(n.nodeType===3){if(hitKw(n.nodeValue))rip(n.parentElement||n);continue;}"
			 "if(n.nodeType!==1)continue;"
			 "var nm=String((n.getAttribute&&n.getAttribute('name'))||'').toLowerCase();"
			 "if(nm==='apple-itunes-app'||nm==='smartbanner'){try{n.parentNode.removeChild(n);}catch(q){}}"
			 // 0.13.5：只查新增节点自身短文本，超过 60 个直接子元素的容器跳过（卡片不会有）：
			 // 不遍历整棵子树、不对每个后代取 textContent，避免重 DOM 页面 O(n^2) 卡主线程。
			 "if(n.childElementCount>60)continue;if(hitKw(n.textContent))rip(n);}}});"
			 // 0.9.8：同时观察 style/class 属性变化——浮层若是预置节点靠 CSS 显示（非动态插入），
			 // childList 捕获不到，必须靠 attributes 置脏，否则 dirty 方案会漏卡片。回调仅置标志，开销极小。
			 "mo.observe(document.documentElement||document,{childList:true,subtree:true,attributes:true,attributeFilter:['style','class']});"
			 "window.__speh.mo=mo;}catch(o){}}"
			 // ② 自定义 scheme 白名单 + App Store 域名黑名单（0.13.5 通用拦）：
			 //    只有白名单 scheme 放行；itms* 自定义 scheme、以及 any Apple App Store
			 //    下载域名（itunes/apps/appstore/phobos.apple.com(.cn)）的 http(s) 链接
			 //    一律视为「跳 App」拦掉。这样起点/稀土掘金/Bing 的「在此处浏览/用APP」
			 //    按钮无论用自定义 scheme 还是 https 下载页，都统一命中，不用逐个补词。
			 "var ok=function(h){h=String(h||'');"
			 "var store=/^itms/i.test(h);"
			 "if(!store){try{var tmp=document.createElement('a');tmp.href=h;"
			 "var hh=(tmp.hostname||'').toLowerCase();"
			 "store=/(^|\\.)(itunes|apps|appstore|phobos)\\.apple\\.(com|cn|com\\.cn)$/.test(hh);"
			 "}catch(q){}}"
			 "if(store)return false;"
			 "var m=/^([a-z][a-z0-9+.\\-]*):/i.exec(h);"
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
			 "e.preventDefault();e.stopPropagation();window.__speh.s=(window.__speh.s||0)+1;"
			 // 0.13.5 探测：把被拦元素的真实 HTML 特征存起来，随返回值打到日志（withlog 版）
			 "var cn=(typeof t.className==='string')?t.className:'';"
			 "window.__speh.hit=(t.tagName||'?')+'#'+(t.id||'')+'.'+cn.slice(0,60)+'|'+(h||'').slice(0,120);}"
			 "}catch(x){}},true);}"
			 // ④B 0.13.5：Bing 搜索结果页的「继续搜索 / 微软必应APP / 浏览器 继续」卡片
			 //   Bing 的 OpalUpsell:ContinueSearch 脚本给 #b_results li a 挂冒泡 click，
			 //   先 preventDefault 再 CSPopupView.show()，点「继续」才 location.href 跳转。
			 //   对策：在 document 捕获阶段只 stopPropagation、**不** preventDefault ——
			 //   Bing 的处理器收不到事件，而 <a> 的默认导航不受影响，链接照常打开。
			 "if(!window.__speh.bing&&/bing\\./i.test(location.hostname||'')){window.__speh.bing=1;"
			 "document.addEventListener('click',function(e){try{var n=e.target;var inRes=false,dep=0;"
			 "while(n&&n.nodeType===1&&dep<40){if(n.id==='b_results'){inRes=true;break;}n=n.parentNode;dep++;}"
			 "if(!inRes)return;var a=e.target;dep=0;"
			 "while(a&&a.nodeType===1&&a.tagName!=='A'&&dep<12){a=a.parentNode;dep++;}"
			 "if(!a||!a.getAttribute)return;var h=a.getAttribute('href')||'';"
			 "if(/^https?:/i.test(h)){e.stopPropagation();window.__speh.cs=(window.__speh.cs||0)+1;"
			 // 鲁棒兜底：万一个别 WKWebView 版本把「事件被中断」当成未激活、默认导航没发生，
			 // 700ms 后校验①期间没有第二次点击②location 未变，才手工跳转，避免串页。
			 "window.__speh.ns=(window.__speh.ns||0)+1;var seq=window.__speh.ns,base=location.href;"
			 "setTimeout(function(){try{if(seq!==window.__speh.ns)return;if(location.href!==base)return;"
			 "location.href=h;}catch(q){}},700);}"
			 "}catch(x){}},true);}"
			 // ⑤ 清网页自绘的「App 内打开」浮层（中英双关键字 + 只认 fixed/sticky/absolute + 宽度够宽）
			 // 0.9.8：DOM 无变动时跳过全树扫描；卡片延迟插入会由 MutationObserver 重新置脏，不漏（JS 内不用 // 注释以免吃掉拼接行）
			 // 0.13.5：加入 Bing 卡片特征词（继续搜索 / 搜你所想 / 微软必应APP 等），
			 //   并把「找到文本节点后向上爬到全宽定位容器再删」补上 —— 原来只删文本节点本身，
			 //   Bing 的标题在内层小元素、宽度判定永远不过。同时排除 SCRIPT/STYLE，避免误删脚本。
			 "if(window.__speh.dirty){"
			 "var els=document.querySelectorAll('body *');"
			 "for(var j=0;j<els.length;j++){var el=els[j];if(!el.parentNode)continue;"
			 "var tg=el.tagName;if(tg==='SCRIPT'||tg==='STYLE'||tg==='NOSCRIPT'||tg==='TEMPLATE')continue;"
			 "var t=(el.textContent||'').replace(/^\\s+|\\s+$/g,'');if(!t||t.length>200)continue;"
			 "if(hitKw(t)){rip(el);}}"
			 "window.__speh.dirty=0;r.scan=1;}"
			 "return 'first='+(first?1:0)+' meta='+r.m+' el='+r.e+' link='+r.link"
			 "+' scan='+r.scan+' click='+window.__speh.click+' s='+(window.__speh.s||0)"
			 "+' cs='+(window.__speh.cs||0)+' hit='+(window.__speh.hit||'-');"
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

// 0.13.5：解析 JS 回报里的字符串字段（取 key= 之后到下一个空格为止）
static NSString *SPEHJSStr(NSString *s, NSString *key)
{
	if (!s || !key) return nil;
	NSString *pat = [key stringByAppendingString:@"="];
	NSRange r = [s rangeOfString:pat];
	if (r.location == NSNotFound) return nil;
	NSUInteger i = r.location + r.length;
	NSUInteger start = i;
	while (i < s.length && [s characterAtIndex:i] != ' ') i++;
	return [s substringWithRange:NSMakeRange(start, i - start)];
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
			int bingCs  = SPEHJSInt(r, @"cs=");

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
			// 0.13.5：Bing 结果页「继续搜索」卡片的压制计数（捕获阶段 stopPropagation 命中）
			if (bingCs > 0) {
				SPEHLog(@"[openinapp] Bing 结果页点击压制 累计=%d", bingCs);
			}
			// 0.13.5：通用跳 App 拦截命中 —— 打出被点元素的真实 HTML 特征
			if (blocked > 0) {
				NSString *hit = SPEHJSStr(r, @"hit");
				if (hit && ![hit isEqualToString:@"-"]) {
					SPEHLog(@"[openinapp] 拦跳App 累计=%d 元素=%@", blocked, hit);
				}
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

// 定义在地址栏模块（文件后部）；WKWebView 挂载时 SafariFramework 已基本加载完成，
// 这里补装一次容器 hitTest hook，避免只靠地址栏模块的短轮询。
static void SPEHInstallCapCVHitTestHook(void);

static void SPEHWVDidMoveToWindowHook(UIView *self, SEL _cmd)
{
	if (gOrigWVDidMoveToWindow) ((void (*)(id, SEL))gOrigWVDidMoveToWindow)(self, _cmd);
	if (!self.window) return;

	static char kInjected;
	BOOL first = !objc_getAssociatedObject(self, &kInjected);
	objc_setAssociatedObject(self, &kInjected, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	__weak UIView *weakSelf = self;

	// 地址栏：容器 hitTest hook 打在真实类 SFCapsuleCollectionView 上。该类属于 SafariFramework，
	// 加载时机晚于本 tweak，所以每次 webview 挂载时补装一次（函数内部幂等，装过即返回）。
	SPEHInstallCapCVHitTestHook();

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

// MARK: - 底部地址栏：按真实类名精准禁用（0.14.3）
//
// 老板实测：在底部地址栏左右滑、或点相邻页露出的那一小截、或点两者之间那条空白缝，都会切上一页/下一页。
// 目标：只禁这几条，宽度/外观保持系统原样，中间的当前页点照常能用，上拉标签页不受影响。
//
// 真实结构（0.13.7 真机运行时视图树 dump，不是猜的）：
//   d=0 SFCapsuleView            f=(20,807,390,44)  gr=[]
//   d=1 SFCapsuleCollectionView  f=(0,0,430,932)    gr=[UITap, UIPan, UIPan]
//   d=2 UIView                   f=(0,0,430,932)    gr=[UIPan]
//
// 0.14.0 真机日志（单击 10 命中 / 滑动 12 命中 / 滚动层 0 命中）确定唯一有效链路：
//   · 单击 = 容器上的 UITapGestureRecognizer → hook setState:，收到 state=3(Ended) 改 5(Failed)
//     ⇒ action 不执行 ⇒ 不切页。
//   · 滑动 = 同一容器上的 UIPanGestureRecognizer → hook setState:，Changed/Ended 判横向占优即 Failed。
//     它不读 translationInView:（0.13.9 清零横向分量后照样切页），所以只能掐状态机。
//   · scrollEnabled 那几层（didMoveToWindow / layoutSubviews / setScrollEnabled: / translation）日志全空，
//     滑动不是滚动偏移驱动，已全部删除。
// 0.14.1 补的缺口：0.14.0 的点击判定要求「必须落在某个侧边胶囊 frame 内」，于是
//   · 当前页与相邻页之间那条不属于任何控件的空白缝被放行（老板实测点它照样切页）；
//   · 相邻页胶囊与当前页胶囊的 frame 有重叠区，重叠处被 `onSide && !onCenter` 判成放行。
//   改为反向判定：胶囊那一整条横带里，只要不在当前页胶囊内部就一律拦（详见 SPEHBlockZone）。
// 全部按类名 + 真实子视图几何精确匹配，不用硬编码坐标。
//
// 0.14.3 结构改造（老板要求尽量不要 hook 全局类）：单击不再 hook 全局 UITapGestureRecognizer，
//   改为只 hook SFCapsuleCollectionView 自己的 hitTest:withEvent: —— 命中拦截区域就返回一个
//   挂在 window 上的遮挡视图（它不是容器的后代），容器上的 tap/pan 都收不到这次触摸，因此
//   不切页，也不会穿透到下层 WKWebView 误触网页链接。全机其它 tap 手势彻底不受影响。
//   滑动仍保留一条全局 UIPanGestureRecognizer hook：Safari 已占用其 delegate，横向/纵向方向判定
//   只能在状态机这一层做，实例级无可替代入口；钩子首帧就做廉价类判定，非胶囊体系直接返回。
//   同时把拦截区域在垂直方向上下各放宽 20pt（kPadY）：覆盖老板实测漏掉的「左右露出那一节
//   上方一点点」窄带 —— 那条缝不属于任何胶囊，但容器 tap 照样识别，点下去仍会切页。
//
// 0.14.2 性能：这两条 hook 挂在全局手势类上，全机每次 tap / pan 都会进来。原先把偏好读取
// （CFPreferencesCopyAppValue，跨进程 plist 查表）放在「是否胶囊体系」判定之前，等于每次触摸都
// 白读一次偏好；pan 还会在每个 Changed 帧（60Hz）重新扫一遍子视图。现在改为：
//   · 先做 isKindOfClass 廉价判定，命中胶囊体系才读偏好；
//   · pan 的「胶囊归属 + 偏好」只在 Began 算一次，结果缓存到识别器上，之后每帧只读一个 NSNumber。

static BOOL SPEHURLBarSwipeKillEnabled(void) { return SPEHBoolPref(@"killURLBarSwipe", YES); }

static Class gCapsuleCVClass = NULL;    // SFCapsuleCollectionView（胶囊分页容器）
static Class gCapsuleViewClass = NULL;  // SFCapsuleView（单个胶囊）

static IMP gOrigPanSetState = NULL;

// 该视图是否属于底部胶囊地址栏体系（容器或单个胶囊）
static BOOL SPEHIsCapsuleView(UIView *v)
{
	if (!v) return NO;
	if (gCapsuleCVClass && [v isKindOfClass:gCapsuleCVClass]) return YES;
	if (gCapsuleViewClass && [v isKindOfClass:gCapsuleViewClass]) return YES;
	return NO;
}

// 滑动用的更宽一档判定：0.13.7 dump 里胶囊容器的父 UIView 上也挂着一颗 UIPan，
// 横向拖拽可能由它驱动，所以「本身是胶囊体系」或「直接子视图就是胶囊体系」都算。
// 仍是按类判定，不看坐标。
static BOOL SPEHIsCapsuleHostDeep(UIView *v)
{
	if (!v) return NO;
	if (SPEHIsCapsuleView(v)) return YES;
	for (UIView *s in [v subviews]) {
		if (SPEHIsCapsuleView(s)) return YES;
	}
	return NO;
}

// 从任意胶囊体系视图往上找胶囊容器当几何参照
static UIView *SPEHCapsuleContainerOf(UIView *v)
{
	UIView *cur = v;
	for (int i = 0; cur && i < 6; i++) {
		if (gCapsuleCVClass && [cur isKindOfClass:gCapsuleCVClass]) return cur;
		cur = [cur superview];
	}
	return v;
}

// 一次触摸是否落在「该拦的区域」里（0.14.3）。
//
// 判定全部基于真实子视图几何，不看硬编码坐标：
//   band       = 所有 SFCapsuleView 子视图 frame 的并集（容器坐标系）；
//   centerRect = 中心离屏幕中线最近、且偏离小于 15% 屏宽的那个胶囊 = 当前页胶囊。
//
// 0.14.1 只按「胶囊那一行的高度」判（上下各留 2pt），老板实测还漏了：
//   左右两侧露出的相邻页胶囊**上方那一点点窄带** —— 它不属于任何胶囊、也不在那一行内，
//   但容器上的 tap 照样识别，点下去还是切上一页/下一页。
// 0.14.3 把 band 在垂直方向上下各放宽 kPadY（覆盖上方那条窄带与下方同理），
// 规则不变：放宽后的带内、只要不在当前页胶囊内部，就一律拦。
//
// outBlank：触点不在任何胶囊 frame 内（空白缝 / 上下窄带），仅用于日志区分；
// outAbove：触点位于胶囊那一行的上方（老板这次指的漏点），仅用于日志区分。
static BOOL SPEHBlockZone(UIView *cv, CGPoint pInCv, BOOL *outBlank, BOOL *outAbove)
{
	if (outBlank) *outBlank = NO;
	if (outAbove) *outAbove = NO;

	UIWindow *win = [cv window];
	if (!win) return NO;
	CGFloat winW = [win bounds].size.width;
	if (winW <= 0) return NO;

	// 上下各放宽这么多：覆盖老板说的「左右露出那一节上方一点点」那条窄带
	const CGFloat kPadY = 20.0;

	CGRect band = CGRectNull;
	CGRect centerRect = CGRectNull;
	BOOL inAnyCapsule = NO;
	CGFloat bestDelta = CGFLOAT_MAX;

	for (UIView *s in [cv subviews]) {
		if (gCapsuleViewClass && ![s isKindOfClass:gCapsuleViewClass]) continue;
		CGRect f = [s frame];
		if (f.size.width <= 0 || f.size.height <= 0) continue;
		band = CGRectIsNull(band) ? f : CGRectUnion(band, f);
		if (CGRectContainsPoint(f, pInCv)) inAnyCapsule = YES;
		CGRect wf = [s convertRect:[s bounds] toView:win];
		CGFloat d = fabs(CGRectGetMidX(wf) - winW / 2.0);
		if (d < winW * 0.15 && d < bestDelta) { bestDelta = d; centerRect = f; }
	}
	if (CGRectIsNull(band) || CGRectIsNull(centerRect)) return NO;

	CGRect zone = CGRectInset(band, 0, -kPadY);
	if (!CGRectContainsPoint(zone, pInCv)) return NO;

	// 当前页胶囊内部：放行（点它进编辑，是正常操作）
	if (CGRectContainsPoint(centerRect, pInCv)) return NO;

	if (outBlank) *outBlank = !inAnyCapsule;
	if (outAbove) *outAbove = (pInCv.y < CGRectGetMinY(band));
	return YES;
}

// 吞触摸用的遮挡视图。
//
// 它只作为 hitTest 的返回值出现：自身 hitTest 返回 nil，所以正常 hit-test 永远轮不到它
// （只能被我们显式返回）。它挂在 window 上、不是胶囊容器的后代 ⇒ 容器上的 UITap/UIPan
// 都收不到这次触摸 ⇒ 不切页；同时也挡住了穿透到下层 WKWebView 的误触网页链接。
@interface SPEHTouchShield : UIView
@end

@implementation SPEHTouchShield
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
@end

static UIView *gTouchShield = nil;

static UIView *SPEHShieldForWindow(UIWindow *win)
{
	if (gTouchShield && gTouchShield.superview != win) {
		[gTouchShield removeFromSuperview];
		gTouchShield = nil;
	}
	if (!gTouchShield) {
		SPEHTouchShield *sh = [[SPEHTouchShield alloc] initWithFrame:[win bounds]];
		sh.backgroundColor = [UIColor clearColor];
		sh.userInteractionEnabled = YES;
		sh.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[win insertSubview:sh atIndex:0];   // 最底层：正常 hit-test 不会先命中它
		gTouchShield = sh;
	}
	return gTouchShield;
}

// ② 单击（0.14.3 起实例级，不再 hook 全局 UITapGestureRecognizer）。
//
// 挂在 SFCapsuleCollectionView 自己的 hitTest:withEvent: 上：命中拦截区域就返回遮挡视图。
// 返回的视图不是容器的后代 ⇒ 容器上那颗 UITapGestureRecognizer 的 _shouldReceiveTouch:
// 直接判否 ⇒ 手势不识别 ⇒ 切页 action 不执行。只 hook 这一个私有类，全机其它 tap 手势
// 完全不受影响（0.14.2 那版是 hook 全局 UIGestureRecognizer，每次触摸都进钩子）。
static IMP gOrigCapCVHitTest = NULL;

static UIView *SPECapCVHitTestHook(UIView *self, SEL _cmd, CGPoint point, UIEvent *event)
{
	UIView *hit = nil;
	if (gOrigCapCVHitTest) {
		hit = ((UIView *(*)(id, SEL, CGPoint, UIEvent *))gOrigCapCVHitTest)(self, _cmd, point, event);
	}
	if (!hit || !gCapsuleCVClass) return hit;

	@try {
		// 先做区域判定（纯几何、纳秒级），命中才去读偏好（CFPreferences 跨进程查表）
		BOOL blank = NO, above = NO;
		if (!SPEHBlockZone(self, point, &blank, &above)) return hit;
		if (!SPEHURLBarSwipeKillEnabled()) return hit;

		UIWindow *win = [self window];
		if (!win) return hit;
#ifndef SPEH_NO_LOG
		static int n = 0;
		if (n < 12) {
			n++;
			SPEHLog(@"[urlswipe] ② 触摸拦截 x=%.0f y=%.0f 空白缝=%d 上方=%d -> 吞触摸（不进容器手势）",
					point.x, point.y, blank ? 1 : 0, above ? 1 : 0);
		}
#endif
		return SPEHShieldForWindow(win);
	} @catch (NSException *e) { }
	return hit;
}

// ① 滑动：同一个容器上的 UIPanGestureRecognizer。
//    0.13.9 日志实证它不读 translationInView:（清零后照样切页），所以必须掐状态机：
//    拖动到 Changed 时判方向，横向占优就直接置 Failed，Safari 的 pan 处理器收不到 Ended，不会切页。
//    纵向占优（上拉展开标签页）完全放行。
// 每帧（Changed）都要判方向，所以「是否胶囊体系 + 偏好是否开启」只在 Began 算一次，
// 结果缓存到识别器自身；之后每帧只读一个 NSNumber，避免 60Hz 扫子视图 + 读 CFPreferences。
static char kPanCapsuleFlag = 0;
static NSNumber *SPEHFlagNS(BOOL v)
{
	static NSNumber *yes = nil, *no = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ yes = @YES; no = @NO; });
	return v ? yes : no;
}

static BOOL SPEHPanCapsuleCached(UIPanGestureRecognizer *gr, BOOL recompute)
{
	NSNumber *flag = objc_getAssociatedObject(gr, &kPanCapsuleFlag);
	if (flag && !recompute) return flag.boolValue;
	// 先做廉价类判定，命中才读偏好
	BOOL isCap = SPEHIsCapsuleHostDeep([gr view]) && SPEHURLBarSwipeKillEnabled();
	objc_setAssociatedObject(gr, &kPanCapsuleFlag, SPEHFlagNS(isCap), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return isCap;
}

static void SPEHPanStateHook(id self, SEL _cmd, NSInteger state)
{
	if (gCapsuleCVClass && state == 1) {
		@try { SPEHPanCapsuleCached((UIPanGestureRecognizer *)self, YES); } @catch (NSException *e) { }
	}
	if ((state == 2 || state == 3) && gCapsuleCVClass) {
		@try {
			UIPanGestureRecognizer *gr = (UIPanGestureRecognizer *)self;
			UIView *host = [gr view];
			if (SPEHPanCapsuleCached(gr, NO)) {
				CGPoint t = [gr translationInView:host];
				CGPoint v = [gr velocityInView:host];
				BOOL horiz = (fabs(v.x) > fabs(v.y) * 1.2 && fabs(v.x) > 80.0) ||
							 (fabs(t.x) > fabs(t.y) * 1.2 && fabs(t.x) > 5.0);
				if (horiz) {
#ifndef SPEH_NO_LOG
					static int n = 0;
					if (n < 12) {
						n++;
						SPEHLog(@"[urlswipe] ① 横向拖动 t=(%.1f,%.1f) v=(%.0f,%.0f) host=%@ state=%ld -> Failed",
								t.x, t.y, v.x, v.y,
								NSStringFromClass(object_getClass(host)), (long)state);
					}
#endif
					state = 5;
				}
			}
		} @catch (NSException *e) { }
	}
	if (gOrigPanSetState) ((void (*)(id, SEL, NSInteger))gOrigPanSetState)(self, _cmd, state);
}

// 容器类的 hitTest:withEvent: 只有在 SafariFramework 加载后才拿得到，
// 而本 tweak 的 ctor 早于它，所以这里做「拿到类才打补丁 + 短轮询」：
// 每次只做一次 NSClassFromString，命中即停，最多 10 秒。
static BOOL gCapCVHitTestPatched = NO;

static void SPEHInstallCapCVHitTestHook(void)
{
	if (gCapCVHitTestPatched) return;
	if (!gCapsuleCVClass) gCapsuleCVClass = NSClassFromString(@"SFCapsuleCollectionView");
	if (!gCapsuleViewClass) gCapsuleViewClass = NSClassFromString(@"SFCapsuleView");
	if (!gCapsuleCVClass) return;
	SPEHPatchInstanceMethod(gCapsuleCVClass, NSSelectorFromString(@"hitTest:withEvent:"),
		(IMP)SPECapCVHitTestHook, &gOrigCapCVHitTest);
	if (gOrigCapCVHitTest) {
		gCapCVHitTestPatched = YES;
		SPEHLog(@"[urlswipe] ② 容器 hitTest hook 已装（capCV=%@ capView=%@）",
				NSStringFromClass(gCapsuleCVClass),
				gCapsuleViewClass ? NSStringFromClass(gCapsuleViewClass) : @"nil");
	}
}

static void SPEHRetryCapCVHitTestHook(int tries)
{
	if (gCapCVHitTestPatched || tries <= 0) return;
	SPEHInstallCapCVHitTestHook();
	if (gCapCVHitTestPatched) return;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
		dispatch_get_main_queue(), ^{ SPEHRetryCapCVHitTestHook(tries - 1); });
}

static void SPEHInstallURLBarSwipeHooks(void)
{
	if (!SPEHURLBarSwipeKillEnabled()) { SPEHLog(@"[urlswipe] disabled by prefs"); return; }

	gCapsuleCVClass   = NSClassFromString(@"SFCapsuleCollectionView");
	gCapsuleViewClass = NSClassFromString(@"SFCapsuleView");

	// ① 单击（0.14.3 起）：只 hook SFCapsuleCollectionView 自己的 hitTest:withEvent:，
	//    不再 hook 全局 UITapGestureRecognizer —— 全机其它 tap 手势彻底不受影响。
	//    类可能尚未加载（SafariFramework 晚于本 tweak），所以带 10 秒短轮询补齐。
	SPEHInstallCapCVHitTestHook();
	if (!gCapCVHitTestPatched) SPEHRetryCapCVHitTestHook(40);

	// ② 滑动：UIPanGestureRecognizer 的状态机是唯一能按方向判定的入口（Safari 已占用其 delegate，
	//    实例级无法替代），这条保留为全局 hook，但首帧就做廉价类判定，非胶囊体系直接返回。
	SPEHPatchInstanceMethod([UIPanGestureRecognizer class], NSSelectorFromString(@"setState:"),
		(IMP)SPEHPanStateHook, &gOrigPanSetState);

	SPEHLog(@"[urlswipe] 0.14.3 安装 capCV=%d capView=%d capCVHitTest=%s panSetState=%s",
			gCapsuleCVClass ? 1 : 0, gCapsuleViewClass ? 1 : 0,
			gOrigCapCVHitTest ? "ok" : "延迟等类加载", gOrigPanSetState ? "ok" : "FAIL");
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
		SPEHLog(@"dialog=%d reader=%d openinapp=%d smartbanner=%d applink=%d probe=%d",
				SPEHDialogKillEnabled(), SPEHReaderKillEnabled(),
				SPEHOpenInAppKillEnabled(), SPEHSmartBannerKillEnabled(),
				SPEHAppLinkKillEnabled(), SPEHProbeEnabled());

		SPEHInstallSFDialogHooks();
		SPEHInstallAppOpenDialogHooks();
		SPEHInstallReaderHooks();
		SPEHInstallOpenInAppHooks();
		SPEHInstallAppLinkHooks();
		SPEHInstallURLBarSwipeHooks();
	}
}
