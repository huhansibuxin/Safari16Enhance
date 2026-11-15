// Safari16Enhance 0.9.0 - iOS 16 Safari 增强
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

#define SPEH_VERSION "0.9.0"

// CFSTR 只接受 C 字符串字面量，故偏好域用 C 字符串宏
#define SPEH_PREF_DOMAIN_CSTR "com.huhansibuxin.safari16enhance"
#define SPEH_LOG_NAME    @"Safari16Enhance.log"

// MARK: - 日志（写入 Safari 容器 Documents）

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

	NSDateFormatter *df = [[NSDateFormatter alloc] init];
	df.dateFormat = @"MM-dd HH:mm:ss.SSS";
	NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];

	dispatch_async(SPEHLogQueue(), ^{
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
static BOOL SPEHBackScrollFixEnabled(void) { return SPEHBoolPref(@"fixBackScroll", YES); }
static BOOL SPEHProbeEnabled(void)         { return SPEHBoolPref(@"probeEnabled", YES); }

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
		SPEHLog(@"[reader] 精准命中 -[%s %s] -> NO", clsC, selC);
		hit++;
	}

	SPEHLog(@"[reader] 白名单 total=%lu hit=%d miss=%d", (unsigned long)total, hit, miss);
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
		js = @"(function(){try{var r={m:0,e:0};"
			 "var killMeta=function(){var ms=document.querySelectorAll('meta[name=apple-itunes-app],meta[name=smartbanner]');"
			 "for(var i=0;i<ms.length;i++){try{ms[i].parentNode.removeChild(ms[i]);r.m++;}catch(q){}}};"
			 "killMeta();"
			 // 文档开始时 meta 可能还没解析出来，挂 MutationObserver 见到就删（GitHub 横幅就靠这条）
			 // 只查新插入的 META 节点，不做整树遍历，避免长页面上的 CPU 开销
			 "try{var mo=new MutationObserver(function(muts){for(var a=0;a<muts.length;a++){var ad=muts[a].addedNodes;"
			 "for(var b=0;b<ad.length;b++){var n=ad[b];if(!n||n.tagName!=='META')continue;"
			 "var nm=String((n.getAttribute&&n.getAttribute('name'))||'').toLowerCase();"
			 "if(nm==='apple-itunes-app'||nm==='smartbanner'){try{n.parentNode.removeChild(n);r.m++;}catch(q){}}}}});"
			 "mo.observe(document.documentElement||document,{childList:true,subtree:true});}catch(o){}"
			 "var kws=['App 内打开','App内打开','在App内打开','在 App 内打开','打开App','打开 App'];"
			 "var els=document.querySelectorAll('body *');"
			 "for(var j=0;j<els.length;j++){var el=els[j];if(!el.parentNode)continue;"
			 "var t=(el.textContent||'').replace(/^\\s+|\\s+$/g,'');if(!t||t.length>40)continue;"
			 "var hit=false;for(var k=0;k<kws.length;k++){if(t.indexOf(kws[k])>=0){hit=true;break;}}"
			 "if(!hit)continue;"
			 "var cs=getComputedStyle(el);"
			 "if(cs.position==='fixed'||cs.position==='sticky'||cs.position==='absolute'){el.parentNode.removeChild(el);r.e++;}}"
			 "return 'meta='+r.m+' el='+r.e;}catch(err){return 'ERR:'+err;}})()";
	});
	return js;
}

@protocol SPEHWebViewJS <NSObject>
- (void)evaluateJavaScript:(NSString *)script completionHandler:(void (^)(id result, NSError *error))handler;
@end

static void SPEHApplyOpenInAppJS(id webView)
{
	if (!webView) return;
	@try {
		[(id<SPEHWebViewJS>)webView evaluateJavaScript:SPEHOpenInAppJS() completionHandler:^(id result, NSError *error) {
			if (error) {
				if (SPEHProbeEnabled()) SPEHLog(@"[openinapp] JS 执行失败 %@", error.localizedDescription);
				return;
			}
			NSString *r = [result isKindOfClass:[NSString class]] ? (NSString *)result : nil;
			if (!r || [r isEqualToString:@"meta=0 el=0"]) return;   // 没啥可清，不刷日志
			SPEHLog(@"[openinapp] 清理结果 %@", r);
		}];
	} @catch (NSException *e) { }
}

// 0.8.0 踩坑（老板实测）：原来这里用 WKUserScript 往 configuration.userContentController
// 里 addUserScript，做「文档开始就删 meta」。后果是第三方 Safari 扩展集体异常：
//   · Userscripts 的「自动加载下一页」不再执行；
//   · Dark Night 每个页面都重新请求网站权限。
// 根因：WKWebView 的 configuration 在初始化时已被内部 copy，之后再改（addUserScript /
// 换 processPool）是非法的，会打乱 Safari 自己的注入管线（扩展 content script 走同一套）。
// 结论：绝不碰 configuration / userContentController / processPool。
// 删 meta 改用 evaluateJavaScript 在各时间点执行；横幅本身已由原生 hook 拦住。

// Smart App Banner 原生 view：运行时按类名找，统一挂 didMoveToWindow


// 0.5.0 实测 hooked=0：iOS 16 的类名不含 "SmartAppBanner"，猜不出就得探。
// 这里做三层探针，一次拿全：
//   ① 全量类名扫描（Banner / AppLink / AppInfoOverlay）
//   ② Safari 关键类上含 Banner/AppLink 的方法名
//   ③ 从 window 根 dump 视图树（横幅是原生 view，只能这么看到它）
static void SPEHDumpViewTree(UIView *v, int depth, NSMutableString *out, int *budget)
{
	if (!v || depth > 5 || *budget <= 0) return;
	const char *nm = class_getName(object_getClass(v));
	NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)(depth * 2) withString:@" " startingAtIndex:0];
	[out appendFormat:@"\n%@%s %@", pad, nm, NSStringFromCGRect(v.frame)];
	(*budget)--;
	NSArray *subs = [v subviews];
	NSUInteger lim = MIN(subs.count, (NSUInteger)10);
	for (NSUInteger i = 0; i < lim; i++) SPEHDumpViewTree(subs[i], depth + 1, out, budget);
}

static void SPEHDumpBannerCandidates(UIView *anchor)
{
	NSMutableArray *clsHits = [NSMutableArray array];
	unsigned int count = 0;
	Class *classes = objc_copyClassList(&count);
	for (unsigned int i = 0; i < count; i++) {
		const char *nm = class_getName(classes[i]);
		if (!nm) continue;
		if (strstr(nm, "Banner") || strstr(nm, "AppLink") || strstr(nm, "AppInfoOverlay") ||
			strstr(nm, "ITunesStore") || strstr(nm, "StoreProduct")) {
			[clsHits addObject:[NSString stringWithUTF8String:nm]];
			if (clsHits.count >= 40) break;
		}
	}
	free(classes);
	SPEHLog(@"[smartbanner] 类名候选 %lu 条: %@",
			(unsigned long)clsHits.count,
			clsHits.count ? [clsHits componentsJoinedByString:@", "] : @"(无)");

	for (NSString *cn in @[ @"TabDocument", @"_SFTabDocument", @"_SFWebView", @"SFWebView", @"BrowserController" ]) {
		Class c = NSClassFromString(cn);
		if (!c) continue;
		NSMutableArray *ms = [NSMutableArray array];
		unsigned int n = 0;
		Method *list = class_copyMethodList(c, &n);
		for (unsigned int i = 0; i < n; i++) {
			const char *sn = sel_getName(method_getName(list[i]));
			if (strstr(sn, "Banner") || strstr(sn, "AppLink") || strstr(sn, "ITunes")) {
				[ms addObject:[NSString stringWithUTF8String:sn]];
			}
		}
		free(list);
		if (ms.count) SPEHLog(@"[smartbanner] %@ 方法: %@", cn, [ms componentsJoinedByString:@", "]);
	}

	if (!anchor) return;
	UIView *root = anchor.window ?: anchor;
	NSMutableString *tree = [NSMutableString string];
	int budget = 120;
	SPEHDumpViewTree(root, 0, tree, &budget);
	SPEHLog(@"[smartbanner] 视图树(%d 节点):%@", 120 - budget, tree);
}

// 0.6.0 崩溃复盘（IPS 实证）：
//   把类名匹配从 "SmartAppBanner" 放宽到 "Banner" 后，同时命中了父子类，
//   MSHookMessageEx 对父子两个类各 hook 一次 didMoveToWindow，子类那次的 orig
//   直接指向父类被替换后的 IMP（也就是本函数自己），于是 A→A 自调，
//   栈帧全是 SPEHSmartBannerDidMoveToWindow +216，最终 KERN_PROTECTION_FAILURE 爆栈。
// 结论：这种「按类名通扫 + 循环 hook 同一 selector」的做法本身不可靠，整体移除。
// 顶部横幅改由「JS 删 apple-itunes-app meta」从源头断掉，原生侧只保留只读探针。

// 0.6.1 探针拿到的真名（TabDocument）：
//   setAppBanner: / didFindAppBannerWithContent: / appBanner / setStoreBannersAreDisabled:
//   BrowserController: removeAppBannerFromTabDocument:animated: / setAppBannerPinnedToTop:forTabDocument:
// 精准做法：banner 一到 TabDocument 就吞掉，从源头不让它存在 —— 单类单选方法 hook，
// 不涉及父子类通扫，不会有 0.6.0 那类自递归风险。

static IMP gOrigSetAppBanner = NULL;
static IMP gOrigSetStoreBannersDisabled = NULL;
static IMP gOrigSetAppSuggestionBanner = NULL;
static IMP gOrigDidFindAppBanner = NULL;

// 按类名拆「页面顶部横幅」视图。
// 0.6.2 日志的视图树证明：横幅不是 TabDocument 的属性渲染，而是挂在
// MobileSafariWindow 下面的一层 view（框在页面顶部），所以吞 setter 有可能吞不到，
// 必须再加一层「见到就拆」。
static int SPEHKillBannerViews(UIView *v, int depth, CGRect winRect)
{
	if (!v || depth > 9) return 0;
	int killed = 0;

	NSString *cls = NSStringFromClass(object_getClass(v));
	BOOL looks = ([cls rangeOfString:@"Banner"].location != NSNotFound ||
				  [cls rangeOfString:@"AppLink"].location != NSNotFound);
	if (looks) {
		CGRect inWindow = v.bounds;
		@try {
			UIView *win = v.window;
			if (win) inWindow = [v convertRect:v.bounds toView:win];
		} @catch (NSException *e) { }
		// 只打「页面顶部、条状、不占满屏」的横幅，避免误伤其它同名视图
		if (inWindow.size.height > 20 && inWindow.size.height <= 240 &&
			inWindow.origin.y < winRect.size.height * 0.45) {
			@try {
				v.hidden = YES;
				[v removeFromSuperview];
			} @catch (NSException *e) { }
			SPEHLog(@"[smartbanner] 拆除视图 %@ rect=%@", cls, NSStringFromCGRect(inWindow));
			return 1;
		}
	}

	for (UIView *s in [v subviews]) killed += SPEHKillBannerViews(s, depth + 1, winRect);
	return killed;
}

static void SPEHSweepBannerViews(UIView *anchor, NSString *tag)
{
	if (!anchor) return;
	UIView *root = anchor.window ?: anchor;
	if (!root) return;
	@try {
		int n = SPEHKillBannerViews(root, 0, root.bounds);
		if (n > 0) SPEHLog(@"[smartbanner] %@ 共拆除 %d 个横幅视图", tag, n);
	} @catch (NSException *e) { }
}

// 扫所有窗口（不依赖某个 webView 的锚点）
static void SPEHSweepAllWindows(NSString *tag)
{
	@try {
		int total = 0;
		for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
			if (![scene isKindOfClass:[UIWindowScene class]]) continue;
			for (UIWindow *w in ((UIWindowScene *)scene).windows) {
				total += SPEHKillBannerViews(w, 0, w.bounds);
			}
		}
		if (total > 0) SPEHLog(@"[smartbanner] %@ 拆掉 %d 个", tag, total);
	} @catch (NSException *e) { }
}

// 横幅类名到现在还没确定（0.7.0 里有 didFindAppBanner 被丢弃 21 次，但用户仍看到横幅，
// 说明那个横幅视图的类名既不含 Banner 也不含 AppLink）。
// 这里把「页面顶部、条状」的所有视图类名打出来，一次拿真名。
static void SPEHDumpTopAreaRec(UIView *v, int depth, UIView *win, NSMutableArray *out)
{
	if (!v || depth > 9 || out.count >= 24) return;
	CGRect r = v.bounds;
	@try { if (win) r = [v convertRect:v.bounds toView:win]; } @catch (NSException *e) { }
	CGFloat winH = win.bounds.size.height;
	if (r.size.height > 18 && r.size.height <= 260 && r.size.width > 180 && r.origin.y < winH * 0.42) {
		[out addObject:[NSString stringWithFormat:@"%@%@", NSStringFromClass(object_getClass(v)),
			NSStringFromCGRect(r)]];
	}
	for (UIView *s in [v subviews]) SPEHDumpTopAreaRec(s, depth + 1, win, out);
}

static void SPEHDumpTopArea(UIView *anchor, NSString *tag)
{
	if (!anchor || !SPEHProbeEnabled()) return;
	UIView *root = anchor.window ?: anchor;
	if (!root) return;
	@try {
		NSMutableArray *out = [NSMutableArray array];
		SPEHDumpTopAreaRec(root, 0, root, out);
		SPEHLog(@"[smartbanner] %@ 顶部条状视图 %lu 个: %@", tag, (unsigned long)out.count,
				out.count ? [out componentsJoinedByString:@" | "] : @"(无)");
	} @catch (NSException *e) { }
}

static void SPEHSetAppBannerHook(id self, SEL _cmd, id banner)
{
	if (banner && SPEHProbeEnabled()) {
		SPEHLog(@"[smartbanner] 拦截 setAppBanner: 丢弃 %@", NSStringFromClass(object_getClass(banner)));
	}
	// 不转发：banner 永远进不了 TabDocument
}

static void SPEHSetAppSuggestionBannerHook(id self, SEL _cmd, id banner, BOOL pinned)
{
	if (SPEHProbeEnabled()) {
		SPEHLog(@"[smartbanner] 拦截 setAppSuggestionBanner:isPinned: 丢弃 %@",
				banner ? NSStringFromClass(object_getClass(banner)) : @"(nil)");
	}
	// 不转发
}

static IMP gOrigAppBannerGetter = NULL;
static IMP gOrigBCDidCompleteCheck = NULL;
static IMP gOrigBCPinTop = NULL;
static IMP gOrigBCRemoveBanner = NULL;

static void SPEHSweepAllWindows(NSString *tag);

static void SPEHDidFindAppBannerHook(id self, SEL _cmd, id content)
{
	// 不转发：Safari 认为「没发现 app banner」，不会再建视图
	if (SPEHProbeEnabled()) {
		SPEHLog(@"[smartbanner] 拦截 didFindAppBannerWithContent: 丢弃 %@",
				content ? NSStringFromClass(object_getClass(content)) : @"(nil)");
	}
	// 有些版本即使这里不转发，BrowserController 那边也会补建一次视图，顺手再扫一遍
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
		dispatch_get_main_queue(), ^{
			SPEHSweepAllWindows(@"didFind 后");
		});
}

// appBanner getter 一律返回 nil：任何读它的渲染路径都拿不到 banner 对象
static id SPEHAppBannerGetterHook(id self, SEL _cmd)
{
	return nil;
}

// BrowserController 的「检查完成 → 上屏」链路整段掐掉
static void SPEHBCDidCompleteCheckHook(id self, SEL _cmd, id tabDocument)
{
	if (SPEHProbeEnabled()) SPEHLog(@"[smartbanner] 拦截 tabDocumentDidCompleteCheckForAppBanner:");
	// 不转发
}

static void SPEHBCPinTopHook(id self, SEL _cmd, BOOL pinned, id tabDocument)
{
	// 不转发：不把横幅钉到顶部
}

static void SPEHBCRemoveBannerHook(id self, SEL _cmd, id tabDocument, BOOL animated)
{
	if (gOrigBCRemoveBanner) ((void (*)(id, SEL, id, BOOL))gOrigBCRemoveBanner)(self, _cmd, tabDocument, animated);
}

static void SPEHSetStoreBannersDisabledHook(id self, SEL _cmd, BOOL value)
{
	// 无论 Safari 传什么，一律 YES（全局禁用商店横幅）
	if (gOrigSetStoreBannersDisabled) {
		((void (*)(id, SEL, BOOL))gOrigSetStoreBannersDisabled)(self, _cmd, YES);
	}
}

static void SPEHInstallSmartAppBannerPreciseHooks(void)
{
	Class tabCls = NSClassFromString(@"TabDocument");
	if (!tabCls) { SPEHLog(@"[smartbanner] TabDocument 未加载"); return; }

	SPEHPatchInstanceMethod(tabCls, NSSelectorFromString(@"setAppBanner:"),
		(IMP)SPEHSetAppBannerHook, &gOrigSetAppBanner);
	SPEHPatchInstanceMethod(tabCls, NSSelectorFromString(@"setAppSuggestionBanner:isPinned:"),
		(IMP)SPEHSetAppSuggestionBannerHook, &gOrigSetAppSuggestionBanner);
	SPEHPatchInstanceMethod(tabCls, NSSelectorFromString(@"didFindAppBannerWithContent:"),
		(IMP)SPEHDidFindAppBannerHook, &gOrigDidFindAppBanner);
	SPEHPatchInstanceMethod(tabCls, NSSelectorFromString(@"setStoreBannersAreDisabled:"),
		(IMP)SPEHSetStoreBannersDisabledHook, &gOrigSetStoreBannersDisabled);
	SPEHPatchInstanceMethod(tabCls, NSSelectorFromString(@"appBanner"),
		(IMP)SPEHAppBannerGetterHook, &gOrigAppBannerGetter);

	Class bcCls = NSClassFromString(@"BrowserController");
	if (bcCls) {
		SPEHPatchInstanceMethod(bcCls, NSSelectorFromString(@"tabDocumentDidCompleteCheckForAppBanner:"),
			(IMP)SPEHBCDidCompleteCheckHook, &gOrigBCDidCompleteCheck);
		SPEHPatchInstanceMethod(bcCls, NSSelectorFromString(@"setAppBannerPinnedToTop:forTabDocument:"),
			(IMP)SPEHBCPinTopHook, &gOrigBCPinTop);
		SPEHPatchInstanceMethod(bcCls, NSSelectorFromString(@"removeAppBannerFromTabDocument:animated:"),
			(IMP)SPEHBCRemoveBannerHook, &gOrigBCRemoveBanner);
	}

	SPEHLog(@"[smartbanner] 精准 hook setAppBanner=%s appBanner(nil)=%s didFind=%s storeDisabled=%s bcCheck=%s bcPin=%s",
			gOrigSetAppBanner ? "ok" : "missing",
			gOrigAppBannerGetter ? "ok" : "missing",
			gOrigDidFindAppBanner ? "ok" : "missing",
			gOrigSetStoreBannersDisabled ? "ok" : "missing",
			gOrigBCDidCompleteCheck ? "ok" : "missing",
			gOrigBCPinTop ? "ok" : "missing");
}

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

	if (first) {
		// 原生接口 / 探针只在每个 webView 首次挂载时跑一次，不参与日常滚动
		// 注意：这里不再改 configuration / userContentController / processPool，
		// 否则会打乱 Safari 扩展的 content script 注入（见上文 0.8.0 踩坑说明）。
		if (SPEHProbeEnabled()) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
				dispatch_get_main_queue(), ^{
					SPEHDumpBannerCandidates(weakSelf);
				});
		}
	}

	// 横幅视图清扫：多个时间点，横幅有时在页面加载完后才插进来
	for (NSNumber *d in @[ @1.0, @2.5, @4.0, @6.0 ]) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
			dispatch_get_main_queue(), ^{
				SPEHSweepBannerViews(weakSelf, [NSString stringWithFormat:@"%@s", d]);
			});
	}

	// 顶部条状视图类名探针（只在装了 probe 时跑，拿来定位横幅真身）
	if (SPEHProbeEnabled()) {
		for (NSNumber *d in @[ @1.5, @3.2 ]) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
				dispatch_get_main_queue(), ^{
					SPEHDumpTopArea(weakSelf, [NSString stringWithFormat:@"%@s", d]);
				});
		}
	}

	// 条状手势禁用：每次挂载都跑（标签栏会重建），两个时间点兜住懒加载出来的视图
	for (NSNumber *d in @[ @1.2, @3.5 ]) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
			dispatch_get_main_queue(), ^{
				SPEHNeutralizeURLBarSwipe(weakSelf, [NSString stringWithFormat:@"%@s", d]);
			});
	}

	NSArray *delays = @[ @0.8, @2.5, @5.0 ];
	for (NSNumber *d in delays) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			SPEHApplyOpenInAppJS(weakSelf);
		});
	}
}

static void SPEHInstallOpenInAppHooks(void)
{
	if (!SPEHOpenInAppKillEnabled()) { SPEHLog(@"[openinapp] disabled by prefs"); return; }

	Class wkCls = NSClassFromString(@"WKWebView");
	if (!wkCls) { SPEHLog(@"[openinapp] WKWebView 未加载"); return; }

	SPEHPatchInstanceMethod(wkCls, @selector(didMoveToWindow), (IMP)SPEHWVDidMoveToWindowHook, &gOrigWVDidMoveToWindow);
	SPEHLog(@"[openinapp] hook didMoveToWindow=%s", gOrigWVDidMoveToWindow ? "ok" : "FAILED");

	SPEHInstallSmartAppBannerPreciseHooks();
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

static void SPEHAppLinkLog(NSString *fmt, ...)
{
	if (!SPEHProbeEnabled() || gAppLinkLogCount >= 20) return;
	gAppLinkLogCount++;
	va_list ap;
	va_start(ap, fmt);
	NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
	va_end(ap);
	SPEHLog(@"[applink] %@", msg);
}

// -[WBSAppLink _synchronouslyFetchAppLinkWithError:] -> nil
static id SPEHFetchAppLinkSyncHook(id self, SEL _cmd, NSError **error)
{
	if (SPEHAppLinkKillEnabled()) {
		SPEHAppLinkLog(@"同步取 AppLink → nil");
		return nil;
	}
	if (gOrigFetchAppLinkSync) return ((id (*)(id, SEL, NSError **))gOrigFetchAppLinkSync)(self, _cmd, error);
	return nil;
}

// +[LSAppLink appLinksWithURL:limit:error:] -> 空数组
static id SPEHAppLinksWithURLHook(id self, SEL _cmd, id url, NSUInteger limit, NSError **error)
{
	if (SPEHAppLinkKillEnabled()) {
		SPEHAppLinkLog(@"查询 AppLink 列表 %@ → 空", url);
		return @[];
	}
	if (gOrigAppLinksWithURL) return ((id (*)(id, SEL, id, NSUInteger, NSError **))gOrigAppLinksWithURL)(self, _cmd, url, limit, error);
	return @[];
}

static id SPEHAppLinksWithURL2Hook(id self, SEL _cmd, id url, NSUInteger limit, BOOL includeCurrent, NSError **error)
{
	if (SPEHAppLinkKillEnabled()) {
		SPEHAppLinkLog(@"查询 AppLink 列表(含当前App) %@ → 空", url);
		return @[];
	}
	if (gOrigAppLinksWithURL2) return ((id (*)(id, SEL, id, NSUInteger, BOOL, NSError **))gOrigAppLinksWithURL2)(self, _cmd, url, limit, includeCurrent, error);
	return @[];
}

// +[LSAppLink getAppLinkWithURL:completionHandler:] -> 回调 (nil, nil)
static void SPEHGetAppLinkHook(id self, SEL _cmd, id url, id completion)
{
	if (SPEHAppLinkKillEnabled()) {
		SPEHAppLinkLog(@"异步取 AppLink %@ → nil", url);
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

	for (NSString *cn in @[ @"TabDocument", @"_SFTabDocument" ]) {
		Class tabCls = NSClassFromString(cn);
		if (!tabCls) continue;
		for (NSString *sn in @[ @"_webView:shouldIncludeAppLinkActionsForElement:",
								@"webView:shouldIncludeAppLinkActionsForElement:" ]) {
			SEL sel = NSSelectorFromString(sn);
			if (class_getInstanceMethod(tabCls, sel)) {
				SPEHPatchInstanceMethod(tabCls, sel, (IMP)SPEHIncludeAppLinkActionsHook, &gOrigIncludeAppLinkActions);
				[hit addObject:[NSString stringWithFormat:@"%@ -%@", cn, sn]];
			}
		}
	}

	SPEHLog(@"[applink] hook %lu 条: %@", (unsigned long)hit.count,
			hit.count ? [hit componentsJoinedByString:@" | "] : @"(未命中任何方法)");
}

// MARK: - 返回后滚动恢复
//
// 老板实测：返回上一页后，页面前几次上/下滑完全不响应，加载完也要滑几下才生效。
// 日志取证（0.5.0）：goBack 后 0.3/0.9/1.8s 检查 scrollEnabled 与 pan 全部是 YES，
// 一条「复位」都没打 → 不是原生被禁用，而是页面 JS 残留滚动锁（部分 SPA 站点，
// 百度传统页不锁，所以百度不卡）。所以改为：① JS 复位页面的 overflow / touch-action
// 与残留全屏遮罩；② 后退窗口内吞掉 Safari 多余的一次 reload / 同 URL loadRequest。

static IMP gOrigWKGoBack = NULL;
static IMP gOrigWKGoForward = NULL;
static IMP gOrigWKReload = NULL;
static IMP gOrigWKReloadFromOrigin = NULL;
static IMP gOrigWKLoadRequest = NULL;

// 后退窗口：goBack 之后 2.5 秒内，丢弃同一 webView 上的多余 reload
static id gSuppressView = nil;
static NSTimeInterval gSuppressUntil = 0;

static BOOL SPEHInBackWindow(id webView)
{
	if (!gSuppressView || webView != gSuppressView) return NO;
	return [NSDate timeIntervalSinceReferenceDate] <= gSuppressUntil;
}

static void SPEHResetScroll(id webView, NSString *tag)
{
	if (!webView || !SPEHBackScrollFixEnabled()) return;
	@try {
		id sv = [webView valueForKey:@"scrollView"];
		if (!sv) return;
		BOOL changed = NO;
		if ([sv respondsToSelector:@selector(isScrollEnabled)] && ![sv isScrollEnabled]) {
			[sv setScrollEnabled:YES];
			changed = YES;
		}
		id pan = [sv valueForKey:@"panGestureRecognizer"];
		if (pan && [pan respondsToSelector:@selector(isEnabled)] && ![pan isEnabled]) {
			[pan setEnabled:YES];
			changed = YES;
		}
		if (changed && SPEHProbeEnabled()) {
			SPEHLog(@"[backscroll] %@ 复位 scrollView (enabled/pan)", tag);
		}
	} @catch (NSException *e) { }
}

static void SPEHWKGoBackHook(id self, SEL _cmd)
{
	if (gOrigWKGoBack) ((void (*)(id, SEL))gOrigWKGoBack)(self, _cmd);

	if (!SPEHBackScrollFixEnabled()) return;

	gSuppressView = self;
	gSuppressUntil = [NSDate timeIntervalSinceReferenceDate] + 2.5;

	__weak id weakSelf = self;
	NSArray *delays = @[ @0.30, @0.90, @1.80 ];
	for (NSNumber *d in delays) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			SPEHResetScroll(weakSelf, [NSString stringWithFormat:@"goBack+%@s", d]);
		});
	}
	if (SPEHProbeEnabled()) SPEHLog(@"[backnav] goBack 打开 2.5s 后退窗口（吞 reload）");
}

static void SPEHWKGoForwardHook(id self, SEL _cmd)
{
	if (gOrigWKGoForward) ((void (*)(id, SEL))gOrigWKGoForward)(self, _cmd);
	SPEHResetScroll(self, @"goForward");
}

static void SPEHWKReloadHook(id self, SEL _cmd)
{
	if (SPEHInBackWindow(self)) {
		if (SPEHProbeEnabled()) SPEHLog(@"[backnav] 后退窗口内吞掉 -%s", sel_getName(_cmd));
		return;
	}
	if (gOrigWKReload) ((void (*)(id, SEL))gOrigWKReload)(self, _cmd);
}

static void SPEHWKReloadFromOriginHook(id self, SEL _cmd)
{
	if (SPEHInBackWindow(self)) {
		if (SPEHProbeEnabled()) SPEHLog(@"[backnav] 后退窗口内吞掉 -%s", sel_getName(_cmd));
		return;
	}
	if (gOrigWKReloadFromOrigin) ((void (*)(id, SEL))gOrigWKReloadFromOrigin)(self, _cmd);
}

// 只吞「URL 与当前页完全相同」的 loadRequest（即重载同一页），
// 用户返回后点新链接不会受影响。
static void SPEHWKLoadRequestHook(id self, SEL _cmd, id request)
{
	if (SPEHInBackWindow(self) && request) {
		@try {
			NSURL *u = [request valueForKey:@"URL"];
			NSURL *cur = [self valueForKey:@"URL"];
			if (u && cur && [[u absoluteString] isEqualToString:[cur absoluteString]]) {
				if (SPEHProbeEnabled()) SPEHLog(@"[backnav] 后退窗口内吞掉同 URL loadRequest");
				return;
			}
		} @catch (NSException *e) { }
	}
	if (gOrigWKLoadRequest) ((void (*)(id, SEL, id))gOrigWKLoadRequest)(self, _cmd, request);
}

static void SPEHInstallBackScrollHooks(void)
{
	if (!SPEHBackScrollFixEnabled()) { SPEHLog(@"[backscroll] disabled by prefs"); return; }

	Class wkCls = NSClassFromString(@"WKWebView");
	if (!wkCls) return;

	SPEHPatchInstanceMethod(wkCls, NSSelectorFromString(@"goBack"), (IMP)SPEHWKGoBackHook, &gOrigWKGoBack);
	SPEHPatchInstanceMethod(wkCls, NSSelectorFromString(@"goForward"), (IMP)SPEHWKGoForwardHook, &gOrigWKGoForward);
	SPEHPatchInstanceMethod(wkCls, NSSelectorFromString(@"reload"), (IMP)SPEHWKReloadHook, &gOrigWKReload);
	SPEHPatchInstanceMethod(wkCls, NSSelectorFromString(@"reloadFromOrigin"), (IMP)SPEHWKReloadFromOriginHook, &gOrigWKReloadFromOrigin);
	SPEHPatchInstanceMethod(wkCls, NSSelectorFromString(@"loadRequest:"), (IMP)SPEHWKLoadRequestHook, &gOrigWKLoadRequest);

	for (NSString *name in @[ @"_SFWebView", @"SFWebView" ]) {
		Class sub = NSClassFromString(name);
		if (!sub) continue;
		unsigned int n = 0;
		Method *ms = class_copyMethodList(sub, &n);
		for (unsigned int i = 0; i < n; i++) {
			const char *selName = sel_getName(method_getName(ms[i]));
			if (strcmp(selName, "goBack") == 0) {
				SPEHPatchInstanceMethod(sub, NSSelectorFromString(@"goBack"), (IMP)SPEHWKGoBackHook, NULL);
			} else if (strcmp(selName, "reload") == 0) {
				SPEHPatchInstanceMethod(sub, NSSelectorFromString(@"reload"), (IMP)SPEHWKReloadHook, NULL);
			} else if (strcmp(selName, "reloadFromOrigin") == 0) {
				SPEHPatchInstanceMethod(sub, NSSelectorFromString(@"reloadFromOrigin"), (IMP)SPEHWKReloadFromOriginHook, NULL);
			}
		}
		free(ms);
	}

	SPEHLog(@"[backscroll] hooks goBack=%s goForward=%s reload=%s reloadFromOrigin=%s loadRequest=%s",
			gOrigWKGoBack ? "ok" : "FAILED", gOrigWKGoForward ? "ok" : "FAILED",
			gOrigWKReload ? "ok" : "FAILED", gOrigWKReloadFromOrigin ? "ok" : "FAILED",
			gOrigWKLoadRequest ? "ok" : "FAILED");
}

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

// 胶囊栏 pan 标记 + 横向分量清零（保留纵向）
static char kCapsulePanTag = 0;
static IMP gOrigPanSetTranslation = NULL;

static void SPEHPanSetTranslationHook(UIPanGestureRecognizer *self, SEL _cmd, CGPoint t, UIView *view)
{
	if (SPEHURLBarSwipeKillEnabled() && objc_getAssociatedObject(self, &kCapsulePanTag)) {
		if (fabs(t.x) > fabs(t.y)) t.x = 0.0;
	}
	if (gOrigPanSetTranslation) {
		((void (*)(id, SEL, CGPoint, UIView *))gOrigPanSetTranslation)(self, _cmd, t, view);
	}
}

static void SPEHEnhanceAddGestureHook(UIView *self, SEL _cmd, UIGestureRecognizer *gr)
{
	// 先按手势类型快速过滤（绝大多数调用在这里就返回，开销可忽略），
	// 再做类名字符串匹配。
	if (SPEHURLBarSwipeKillEnabled() && gr &&
		([gr isKindOfClass:[UISwipeGestureRecognizer class]] ||
		 [gr isKindOfClass:[UIPanGestureRecognizer class]])) {
		@try {
			NSString *hostCls = NSStringFromClass(object_getClass(self));
			if (SPEHHostLooksLikeURLBar(hostCls)) {
				BOOL isSwipe = [gr isKindOfClass:[UISwipeGestureRecognizer class]];
				// pan 只在明确的地址输入控件上禁，避免误伤工具栏其它交互
				BOOL isPanOnURL = [gr isKindOfClass:[UIPanGestureRecognizer class]] &&
					([hostCls rangeOfString:@"URL"].location != NSNotFound ||
					 [hostCls rangeOfString:@"Address"].location != NSNotFound);

				if (isSwipe || isPanOnURL) {
					gr.enabled = NO;
					SPEHLog(@"[urlswipe] 已禁用 %@ on %@",
							NSStringFromClass(object_getClass(gr)), hostCls);
					return;   // 不转发 = 手势根本没挂上
				}
			}
			if (SPEHProbeEnabled() && [gr isKindOfClass:[UISwipeGestureRecognizer class]]) {
				// 只记一次，用来确认地址栏的真实类名（下一版可按真名收紧）
				static NSMutableSet *seen = nil;
				static dispatch_once_t once;
				dispatch_once(&once, ^{ seen = [NSMutableSet set]; });
				NSString *key = [NSString stringWithFormat:@"%@|%ld", hostCls,
					(long)((UISwipeGestureRecognizer *)gr).direction];
				if (![seen containsObject:key] && seen.count < 40) {
					[seen addObject:key];
					SPEHLog(@"[urlswipe] 探针 swipe 挂到 %@ direction=%ld（未拦截）",
							hostCls, (long)((UISwipeGestureRecognizer *)gr).direction);
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
				SPEHLog(@"[urlswipe] 关闭横向滚动 %@ contentW=%.0f boundsW=%.0f",
						cls, sv.contentSize.width, sv.bounds.size.width);
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
		SPEHLog(@"log file = %@", SPEHLogPath());
		SPEHLog(@"dialog=%d reader=%d openinapp=%d backscroll=%d applink=%d probe=%d",
				SPEHDialogKillEnabled(), SPEHReaderKillEnabled(),
				SPEHOpenInAppKillEnabled(), SPEHBackScrollFixEnabled(),
				SPEHAppLinkKillEnabled(), SPEHProbeEnabled());

		SPEHInstallSFDialogHooks();
		SPEHInstallReaderHooks();
		SPEHInstallOpenInAppHooks();
		SPEHInstallBackScrollHooks();
		SPEHInstallAppLinkHooks();
		SPEHInstallURLBarSwipeHooks();
	}
}
