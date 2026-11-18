// Safari16Enhance 0.13.3 - iOS 16 Safari 增强
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

#define SPEH_VERSION "0.13.3"

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
			 // 0.13.3：App 引流卡片特征词（Bing / 起点通用），MO 即时拆除与全树扫描共用
			 "var KWS=['App 内打开','App内打开','在App内打开','在 App 内打开','打开App','打开 App','open in app','Open in App','OPEN IN APP',"
			 "'继续搜索','搜你所想','搜你所想，有求必应','搜你所想,有求必应','微软必应APP','使用必应应用搜索','在必应应用中打开',"
			 "'继续浏览精彩内容','在此处浏览','起点读书APP','海量好书','新人免费','免费读'];"
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
			 // 0.13.3：只查新增节点自身短文本，超过 60 个直接子元素的容器跳过（卡片不会有）：
			 // 不遍历整棵子树、不对每个后代取 textContent，避免重 DOM 页面 O(n^2) 卡主线程。
			 "if(n.childElementCount>60)continue;if(hitKw(n.textContent))rip(n);}}});"
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
			 // ④B 0.13.3：Bing 搜索结果页的「继续搜索 / 微软必应APP / 浏览器 继续」卡片
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
			 // 0.13.3：加入 Bing 卡片特征词（继续搜索 / 搜你所想 / 微软必应APP 等），
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
			 "+' cs='+(window.__speh.cs||0);"
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
			// 0.13.3：Bing 结果页「继续搜索」卡片的压制计数（捕获阶段 stopPropagation 命中）
			if (bingCs > 0) {
				SPEHLog(@"[openinapp] Bing 结果页点击压制 累计=%d", bingCs);
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

// MARK: - 0.13.3 底部地址栏「单击边缘露出的相邻地址」切页精确拦截
//
// 左右滑切页已由上面的胶囊栏 pan / scrollEnabled 禁用（老板实测生效），这部分一行不动。
// 剩下的漏洞：当前胶囊左/右会露出一小截相邻标签的地址，点那一小截仍会切页。
// 做法：hook 底部胶囊栏 collectionView 的 hitTest:withEvent:，只有当被点中的 cell
// 不是「中心对齐当前可视区」的那一个（即边缘露出的相邻 cell）时返回 nil，
// 让这次触摸到不了 cell ⇒ 不触发 didSelect ⇒ 不切页。
// 点中间的当前页照常进编辑；上拉开标签页的 pan 起点在中间，不受影响。
// 不用私有 delegate 方法名，避免误伤；只认贴屏底部、高度像胶囊栏的 collectionView。

static IMP gOrigCapsuleCVHitTest = NULL;
static int gCapsuleLogN = 0;

static UIView *SPEHCapsuleCVHitTestHook(id self, SEL _cmd, CGPoint point, UIEvent *event)
{
	UIView *hit = nil;
	if (gOrigCapsuleCVHitTest) {
		hit = ((UIView *(*)(id, SEL, CGPoint, UIEvent *))gOrigCapsuleCVHitTest)(self, _cmd, point, event);
	}
	if (!SPEHURLBarSwipeKillEnabled() || !hit) return hit;

	UICollectionView *cv = (UICollectionView *)self;
	UIWindow *win = [cv window];
	if (!win) return hit;

	CGRect f = [cv frame];
	CGFloat winH = [win bounds].size.height;
	CGFloat winW = [win bounds].size.width;
	// 快速过滤：只认贴屏幕底部、高度像一条胶囊栏、宽度够宽的 collectionView
	if (f.size.height <= 0 || f.size.height > 100 ||
		f.origin.y < winH - 130 || f.size.width < winW * 0.5) return hit;

	NSIndexPath *ip = nil;
	UICollectionViewLayoutAttributes *attr = nil;
	@try {
		ip = [cv indexPathForItemAtPoint:point];
		if (ip) attr = [cv layoutAttributesForItemAtIndexPath:ip];
	} @catch (NSException *e) { return hit; }
	if (!ip || !attr) return hit;

	CGFloat cellCx = CGRectGetMidX([attr frame]);
	CGFloat visCx  = [cv contentOffset].x + CGRectGetMidX([cv bounds]);
	CGFloat delta  = fabs(cellCx - visCx);
	CGFloat lim    = CGRectGetWidth([cv bounds]) * 0.4;

	// 每次命中底部 collectionView 的点击都记一条（withlog 版全打，nolog 版编译掉）
	if (gCapsuleLogN < 20) {
		gCapsuleLogN++;
		SPEHLog(@"[urlprobe] cvHit cv=%@ hit=%@ item=%ld cellCx=%.0f visCx=%.0f delta=%.0f lim=%.0f %@",
			NSStringFromClass(object_getClass(cv)), NSStringFromClass(object_getClass(hit)),
			(long)[ip item], cellCx, visCx, delta, lim,
			delta > lim ? @"=> BLOCK" : @"=> pass");
	}

	if (delta > lim) {
		// 返回 cv 自身吞掉事件：到不了 cell ⇒ 不触发 didSelect ⇒ 不切页；
		// 同时不返回 nil（nil 会穿透到下层 WKWebView，反而误触网页链接）。
		return cv;
	}
	return hit;
}

#ifndef SPEH_NO_LOG
// 视图树 dump：把底部区域所有 UIScrollView / UICollectionView 的真实类名和几何打出来
static void SPEHDumpBarViews(UIView *v, CGFloat winH, int depth)
{
	if (!v || depth > 9) return;
	NSString *cls = NSStringFromClass(object_getClass(v));
	CGRect f = [v frame];
	BOOL bottom = (f.size.height > 0 && f.origin.y >= winH - 200);
	if (bottom && ([v isKindOfClass:[UIScrollView class]] ||
				   [cls rangeOfString:@"Capsule"].location != NSNotFound ||
				   [cls rangeOfString:@"Bar"].location != NSNotFound)) {
		NSString *extra = @"";
		if ([v isKindOfClass:[UIScrollView class]]) {
			UIScrollView *sv = (UIScrollView *)v;
			extra = [NSString stringWithFormat:@" content=(%.0f,%.0f) offsetX=%.0f scroll=%d paging=%d",
				sv.contentSize.width, sv.contentSize.height, sv.contentOffset.x, sv.scrollEnabled, sv.pagingEnabled];
		}
		SPEHLog(@"[urlprobe] tree d=%d %@ frame=(%.0f,%.0f,%.0f,%.0f)%@",
			depth, cls, f.origin.x, f.origin.y, f.size.width, f.size.height, extra);
	}
	for (UIView *s in [v subviews]) SPEHDumpBarViews(s, winH, depth + 1);
}
#endif

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

	// 0.13.3：单击边缘切页拦截 + 探测。
	// 拦截点在 UICollectionView 的 hitTest（只认底部胶囊 collectionView）；
	// 探测点 SPEHDumpBarViews 在地址栏挂窗后 dump 真实视图树。
	SPEHPatchInstanceMethod([UICollectionView class], NSSelectorFromString(@"hitTest:withEvent:"),
		(IMP)SPEHCapsuleCVHitTestHook, &gOrigCapsuleCVHitTest);

	SPEHLog(@"[urlswipe] hooks addGesture=%s panSetTrans=%s cvHitTest=%s",
			gOrigAddGesture ? "ok" : "FAIL", gOrigPanSetTranslation ? "ok" : "FAIL",
			gOrigCapsuleCVHitTest ? "ok" : "FAIL");
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
#ifndef SPEH_NO_LOG
		// 0.13.3：探测版只 dump 一次真实底部视图树，确认控件到底是哪个类
		static BOOL dumped = NO;
		if (!dumped) {
			dumped = YES;
			SPEHLog(@"[urlprobe] === bar view tree dump ===");
			SPEHDumpBarViews(root, winH, 0);
		}
#endif

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
