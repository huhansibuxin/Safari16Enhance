// Safari16Enhance 0.2.0 - iOS 16 Safari 增强
//
// 0.1.0 实测事实：
//   - 引擎注入成功：controller = _SFSearchEngineController，_populateSearchEngines 已 hook，引擎数组 10 个
//   - 但「打不开该网页」弹窗没有走 -[UIViewController presentViewController:animated:completion:]，
//     日志零命中，也没有 alert 级 window → 必须换探测点（UIAlertController 生命周期 + 工厂方法）
//
// 0.2.0 变更：
//   1. 弹窗：present 链路 + UIAlertController viewWillAppear/viewDidAppear + 工厂方法（带调用栈）+ 全窗口监听，
//      命中后尽力 dismiss 并 toast
//   2. 阅读器：运行时按类名扫描所有 *Reader* 类，把「是否可用」判定一律压成 NO，
//      地址栏「阅读器可用」提示自然不再出现
//   3. 返回缓存：运行时在 WKPreferences 类层次上找 *BackForward*Enabled: 这类 SPI 并打开，
//      让「从下一页返回」走 bfcache 恢复而不是重新拉网络
//
// 原则：所有 hook 先检查类/方法存在性，BOOLEAN 返回类型校验，全部 @try 包裹，绝不让 Safari 崩

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <unistd.h>

#define SPEH_VERSION "0.2.0"

// CFSTR 只接受 C 字符串字面量，故偏好域用 C 字符串宏
#define SPEH_PREF_DOMAIN_CSTR "com.huhansibuxin.safari16enhance"
#define SPEH_PREF_DOMAIN SPEH_PREF_DOMAIN_CSTR
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

	// 真实写入校验：只判断目录存在不算数
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

static NSString *SPEHStringPref(NSString *key, NSString *def)
{
	CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(SPEH_PREF_DOMAIN_CSTR));
	if (!v) return def;
	NSString *r = def;
	if (CFGetTypeID(v) == CFStringGetTypeID()) r = [(__bridge NSString *)v copy];
	CFRelease(v);
	return r;
}

static NSString *const SPEHDefaultEngineName = @"元宝搜索";
static NSString *const SPEHDefaultEngineURL  = @"https://so.qq.com/isearch?query={searchTerms}";

static BOOL SPEHEnabled(void)              { return SPEHBoolPref(@"enabled", YES); }
static BOOL SPEHEngineEnabled(void)        { return SPEHBoolPref(@"customEngineEnabled", YES); }
static BOOL SPEHAlertSuppressEnabled(void) { return SPEHBoolPref(@"suppressErrorAlert", YES); }
static BOOL SPEHReaderKillEnabled(void)    { return SPEHBoolPref(@"killReader", YES); }
static BOOL SPEHBFCacheEnabled(void)       { return SPEHBoolPref(@"backForwardCache", YES); }
static BOOL SPEHProbeEnabled(void)         { return SPEHBoolPref(@"probeEnabled", YES); }

static NSString *SPEHEngineName(void)      { return SPEHStringPref(@"customEngineName", SPEHDefaultEngineName); }
static NSString *SPEHEngineURL(void)       { return SPEHStringPref(@"customEngineURL", SPEHDefaultEngineURL); }

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

static void SPEHPatchClassMethod(Class cls, SEL sel, IMP newImp, IMP *outOld)
{
	if (!cls) return;
	Method m = class_getClassMethod(cls, sel);
	if (!m) return;
	MSHookMessageEx(object_getClass(cls), sel, newImp, outOld);
}

static void SPEHDumpMethodList(Class cls, NSUInteger limit, NSString *tag)
{
	if (!cls) return;
	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	SPEHLog(@"[probe-%@] class %@ (%u methods)", tag, NSStringFromClass(cls), count);
	for (unsigned int i = 0; i < count && i < limit; i++) {
		SPEHLog(@"[probe-%@]    - %@  types=%s", tag, NSStringFromSelector(method_getName(methods[i])), method_getTypeEncoding(methods[i]));
	}
	free(methods);
}

// MARK: - 搜索引擎注入（0.1.0 已验证可用）

@protocol SPEHEngineInfoInit <NSObject>
- (id)initWithDictionary:(NSDictionary *)dict usingContext:(id)context;
@end

static Class gSearchEngineControllerClass = Nil;
static Class gSearchEngineInfoClass = Nil;
static id gCustomSearchEngine = nil;
static BOOL gEngineHooked = NO;
static int gEngineRetryCount = 0;

static IMP gOrigPopulateSearchEngines = NULL;
static IMP gOrigDefaultSearchEngine = NULL;
static IMP gOrigDefaultSearchEngineIfPopulated = NULL;

static id SPEHCreateCustomSearchEngine(id controller)
{
	NSString *urlTemplate = SPEHEngineURL();
	if (![urlTemplate containsString:@"{searchTerms}"]) {
		SPEHLog(@"[engine] custom URL 模板缺少 {searchTerms}，放弃注入");
		return nil;
	}
	Class infoCls = gSearchEngineInfoClass;
	if (!infoCls) return nil;

	NSDictionary *dict = @{
		@"SearchEngineIdentifier" : @"com.huhansibuxin.speh.custom",
		@"SearchEngineID" : @20261115,
		@"SearchURLTemplate" : urlTemplate,
		@"SuggestionsURLTemplate" : @"",
		@"ShortName" : SPEHEngineName(),
		@"ScriptingName" : SPEHEngineName(),
	};

	id engine = nil;
	SEL modernSel = @selector(initWithDictionary:usingContext:);
	SEL legacySel = NSSelectorFromString(@"engineFromDictionary:withController:");

	if ([infoCls instancesRespondToSelector:modernSel]) {
		engine = [(id<SPEHEngineInfoInit>)[infoCls alloc] initWithDictionary:dict usingContext:controller];
	} else if ([infoCls respondsToSelector:legacySel]) {
		typedef id (*LegacyFn)(id, SEL, id, id);
		engine = ((LegacyFn)objc_msgSend)(infoCls, legacySel, dict, controller);
	}

	SPEHLog(@"[engine] built engine=%@ name=%@", engine, SPEHEngineName());
	return engine;
}

static void SPEHPopulateSearchEnginesHook(id self, SEL _cmd)
{
	if (gOrigPopulateSearchEngines) ((void (*)(id, SEL))gOrigPopulateSearchEngines)(self, _cmd);
	if (!SPEHEngineEnabled()) return;

	if (!gCustomSearchEngine) gCustomSearchEngine = SPEHCreateCustomSearchEngine(self);
	if (!gCustomSearchEngine) return;

	@try {
		id engines = nil;
		@try { engines = [self valueForKey:@"_searchEngines"]; } @catch (NSException *e) { }
		if (!engines) { @try { engines = [self valueForKey:@"engines"]; } @catch (NSException *e) { } }

		if ([engines isKindOfClass:[NSMutableArray class]]) {
			NSMutableArray *arr = (NSMutableArray *)engines;
			if (![arr containsObject:gCustomSearchEngine]) {
				[arr addObject:gCustomSearchEngine];
				SPEHLog(@"[engine] appended, total=%lu", (unsigned long)arr.count);
			}
		} else if ([engines isKindOfClass:[NSArray class]]) {
			NSArray *arr = (NSArray *)engines;
			if (![arr containsObject:gCustomSearchEngine]) {
				NSArray *newArr = [arr arrayByAddingObject:gCustomSearchEngine];
				@try { [self setValue:newArr forKey:@"_searchEngines"]; } @catch (NSException *e) { }
				@try { [self setValue:newArr forKey:@"engines"]; } @catch (NSException *e) { }
				SPEHLog(@"[engine] replaced immutable array, total=%lu", (unsigned long)newArr.count);
			}
		}
	} @catch (NSException *e) {
		SPEHLog(@"[engine] populate exception: %@", e);
	}
}

static id SPEHDefaultSearchEngineHook(id self, SEL _cmd)
{
	if (SPEHEngineEnabled() && gCustomSearchEngine) return gCustomSearchEngine;
	if (gOrigDefaultSearchEngine) return ((id (*)(id, SEL))gOrigDefaultSearchEngine)(self, _cmd);
	return nil;
}

static id SPEHDefaultSearchEngineIfPopulatedHook(id self, SEL _cmd)
{
	if (SPEHEngineEnabled() && gCustomSearchEngine) return gCustomSearchEngine;
	if (gOrigDefaultSearchEngineIfPopulated) return ((id (*)(id, SEL))gOrigDefaultSearchEngineIfPopulated)(self, _cmd);
	return nil;
}

static void SPEHInstallSearchEngineHooks(void)
{
	gSearchEngineControllerClass = NSClassFromString(@"SearchEngineController") ?: NSClassFromString(@"_SFSearchEngineController");
	gSearchEngineInfoClass = NSClassFromString(@"SearchEngineInfo") ?: NSClassFromString(@"_SFSearchEngineInfo");
	if (!gSearchEngineControllerClass) return;

	SPEHLog(@"[engine] controller=%@ info=%@", NSStringFromClass(gSearchEngineControllerClass), NSStringFromClass(gSearchEngineInfoClass));

	BOOL hookedPopulate = NO;
	for (NSString *name in @[ @"_populateSearchEngines", @"populateSearchEngines", @"_updateSearchEngines" ]) {
		SEL sel = NSSelectorFromString(name);
		if (class_getInstanceMethod(gSearchEngineControllerClass, sel)) {
			SPEHPatchInstanceMethod(gSearchEngineControllerClass, sel, (IMP)SPEHPopulateSearchEnginesHook, &gOrigPopulateSearchEngines);
			hookedPopulate = YES;
			break;
		}
	}
	if (!hookedPopulate) SPEHDumpMethodList(gSearchEngineControllerClass, 80, @"engine");

	SPEHPatchInstanceMethod(gSearchEngineControllerClass, @selector(defaultSearchEngine), (IMP)SPEHDefaultSearchEngineHook, &gOrigDefaultSearchEngine);
	SPEHPatchInstanceMethod(gSearchEngineControllerClass, @selector(defaultSearchEngineIfPopulated), (IMP)SPEHDefaultSearchEngineIfPopulatedHook, &gOrigDefaultSearchEngineIfPopulated);

	gEngineHooked = YES;
}

static void SPEHScheduleSearchEngineHookInstall(void)
{
	if (gEngineHooked) return;
	if (gEngineRetryCount >= 12) return;
	gEngineRetryCount++;
	SPEHInstallSearchEngineHooks();
	if (!gEngineHooked) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			SPEHScheduleSearchEngineHookInstall();
		});
	}
}

// MARK: - 弹窗拦截（0.2.0：多探测点 + 生命周期拦截）

static IMP gOrigPresentViewController = NULL;
static IMP gOrigAlertFactory = NULL;
static IMP gOrigAlertViewWillAppear = NULL;
static IMP gOrigAlertViewDidAppear = NULL;

static BOOL SPEHIsTargetErrorAlert(UIAlertController *alert)
{
	NSString *title = alert.title ?: @"";
	NSString *message = alert.message ?: @"";
	NSString *combined = [title stringByAppendingString:message];

	NSArray *keywords = @[
		@"打不开该网页", @"打不开这个网页", @"无法打开该网页", @"无法打开这个网页",
		@"打不开网页", @"网址无效", @"地址无效", @"无法显示网页", @"找不到服务器",
		@"cannot open the page", @"can't open the page", @"cannot be opened",
		@"address is invalid", @"the URL is invalid", @"cannot connect"
	];
	for (NSString *kw in keywords) {
		if ([combined rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
	}
	return NO;
}

static void SPEHLogAlertContext(UIAlertController *alert, NSString *stage)
{
	NSString *presenter = @"-";
	UIViewController *p = alert.presentingViewController;
	if (p) presenter = NSStringFromClass([p class]);
	NSString *parent = @"-";
	if (alert.parentViewController) parent = NSStringFromClass([alert.parentViewController class]);

	SPEHLog(@"[alert] %@ class=%@ title=%@ message=%@ presenter=%@ parent=%@ actions=%lu",
			stage, NSStringFromClass([alert class]), alert.title, alert.message, presenter, parent,
			(unsigned long)alert.actions.count);
}

static void SPEHSuppressAlert(UIAlertController *alert, NSString *stage)
{
	SPEHLog(@"[alert] SUPPRESSED via %@: %@ / %@", stage, alert.title, alert.message);
	NSString *toast = alert.title.length ? alert.title : @"网页无法打开";
	if (alert.message.length && alert.message.length <= 24) {
		toast = [toast stringByAppendingFormat:@" · %@", alert.message];
	}
	SPEHShowToast(toast);
}

// ① present 链路（0.1.0 未命中，保留兜底）
static void SPEHPresentViewControllerHook(UIViewController *self, SEL _cmd, UIViewController *vc, BOOL animated, void (^completion)(void))
{
	if (SPEHAlertSuppressEnabled() && [vc isKindOfClass:[UIAlertController class]]) {
		UIAlertController *alert = (UIAlertController *)vc;
		SPEHLogAlertContext(alert, @"present");
		if (SPEHIsTargetErrorAlert(alert)) {
			SPEHSuppressAlert(alert, @"present");
			if (completion) completion();
			return;
		}
	}
	if (gOrigPresentViewController) {
		((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))gOrigPresentViewController)(self, _cmd, vc, animated, completion);
	}
}

// ② 工厂方法：任何 alert 被创建都会命中，附调用栈用于定位真实链路
static id SPEHAlertFactoryHook(id self, SEL _cmd, NSString *title, NSString *message, UIAlertControllerStyle style)
{
	if (SPEHProbeEnabled()) {
		NSArray *stack = [NSThread callStackSymbols];
		SPEHLog(@"[alert] CREATE class=%@ title=%@ message=%@", NSStringFromClass(self), title, message);
		NSUInteger n = MIN(stack.count, 10);
		for (NSUInteger i = 0; i < n; i++) SPEHLog(@"[alert]    %@", stack[i]);
	}
	if (gOrigAlertFactory) {
		return ((id (*)(id, SEL, NSString *, NSString *, UIAlertControllerStyle))gOrigAlertFactory)(self, _cmd, title, message, style);
	}
	return nil;
}

// ③ 生命周期：任何 in-process alert 出现都会走这里，最可靠的拦截点
static void SPEHAlertViewWillAppearHook(UIAlertController *self, SEL _cmd)
{
	if (gOrigAlertViewWillAppear) ((void (*)(id, SEL))gOrigAlertViewWillAppear)(self, _cmd);

	if (!SPEHAlertSuppressEnabled()) return;
	SPEHLogAlertContext(self, @"viewWillAppear");

	if (SPEHIsTargetErrorAlert(self)) {
		SPEHSuppressAlert(self, @"viewWillAppear");
		dispatch_async(dispatch_get_main_queue(), ^{
			@try { [self dismissViewControllerAnimated:NO completion:nil]; } @catch (NSException *e) { }
		});
	}
}

static void SPEHAlertViewDidAppearHook(UIAlertController *self, SEL _cmd)
{
	if (gOrigAlertViewDidAppear) ((void (*)(id, SEL))gOrigAlertViewDidAppear)(self, _cmd);

	if (!SPEHAlertSuppressEnabled()) return;
	if (SPEHIsTargetErrorAlert(self)) {
		SPEHSuppressAlert(self, @"viewDidAppear");
		@try { [self dismissViewControllerAnimated:NO completion:nil]; } @catch (NSException *e) { }
	}
}

static void SPEHInstallAlertHooks(void)
{
	SPEHPatchInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:),
							(IMP)SPEHPresentViewControllerHook, &gOrigPresentViewController);
	SPEHLog(@"[hook] presentViewController=%s", gOrigPresentViewController ? "ok" : "FAILED");

	SPEHPatchClassMethod([UIAlertController class], @selector(alertControllerWithTitle:message:preferredStyle:),
						 (IMP)SPEHAlertFactoryHook, &gOrigAlertFactory);
	SPEHLog(@"[hook] alertFactory=%s", gOrigAlertFactory ? "ok" : "FAILED");

	SPEHPatchInstanceMethod([UIAlertController class], @selector(viewWillAppear:),
							(IMP)SPEHAlertViewWillAppearHook, &gOrigAlertViewWillAppear);
	SPEHLog(@"[hook] alertWillAppear=%s", gOrigAlertViewWillAppear ? "ok" : "FAILED");

	SPEHPatchInstanceMethod([UIAlertController class], @selector(viewDidAppear:),
							(IMP)SPEHAlertViewDidAppearHook, &gOrigAlertViewDidAppear);
	SPEHLog(@"[hook] alertDidAppear=%s", gOrigAlertViewDidAppear ? "ok" : "FAILED");

	// 探针：任何新窗口都记（排除键盘窗，避免刷屏）
	[[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification
													  object:nil
													   queue:[NSOperationQueue mainQueue]
												  usingBlock:^(NSNotification *note) {
		if (!SPEHProbeEnabled()) return;
		UIWindow *w = note.object;
		if (![w isKindOfClass:[UIWindow class]]) return;
		NSString *cls = NSStringFromClass([w class]);
		if ([cls rangeOfString:@"Keyboard" options:NSCaseInsensitiveSearch].location != NSNotFound) return;
		SPEHLog(@"[probe] window visible class=%@ level=%.0f hidden=%d", cls, w.windowLevel, w.isHidden);
	}];
}

// MARK: - 阅读器击杀
//
// 「阅读器可用」是 Safari 判定文章页后在地址栏临时替换 URL 的提示，
// 源头是 *Reader* 类的可用性判定。这里按类名通用扫描，把零参 BOOL 判定压成 NO。

static BOOL SPEHReturnNOHook(id self, SEL _cmd) { return NO; }

static BOOL SPEHLooksLikeAvailabilitySelector(NSString *selName)
{
	return [selName hasPrefix:@"isReader"] || [selName hasPrefix:@"reader"] ||
		   [selName hasPrefix:@"_isReader"] || [selName hasPrefix:@"isArticleAvailable"] ||
		   [selName hasPrefix:@"isReaderAvailable"];
}

static void SPEHInstallReaderHooks(void)
{
	if (!SPEHReaderKillEnabled()) { SPEHLog(@"[reader] disabled by prefs"); return; }

	unsigned int count = 0;
	Class *classes = objc_copyClassList(&count);
	int classHits = 0, methodHits = 0;

	for (unsigned int i = 0; i < count; i++) {
		Class cls = classes[i];
		const char *name = class_getName(cls);
		if (!name) continue;
		NSString *clsName = [NSString stringWithUTF8String:name];
		if (!clsName) continue;
		if ([clsName rangeOfString:@"Reader"].location == NSNotFound) continue;
		classHits++;

		unsigned int mcount = 0;
		Method *methods = class_copyMethodList(cls, &mcount);
		for (unsigned int j = 0; j < mcount; j++) {
			SEL sel = method_getName(methods[j]);
			const char *selC = sel_getName(sel);
			NSString *selName = [NSString stringWithUTF8String:selC];
			if (!selName) continue;
			if (strchr(selC, ':')) continue;                      // 只处理零参判定
			if (!SPEHLooksLikeAvailabilitySelector(selName)) continue;
			if (!SPEHMethodReturnsBool(methods[j])) continue;
			MSHookMessageEx(cls, sel, (IMP)SPEHReturnNOHook, NULL);
			SPEHLog(@"[reader] -[%@ %@] -> NO", clsName, selName);
			methodHits++;
		}
		free(methods);

		Class meta = object_getClass(cls);
		if (meta) {
			unsigned int ccount = 0;
			Method *cms = class_copyMethodList(meta, &ccount);
			for (unsigned int j = 0; j < ccount; j++) {
				SEL sel = method_getName(cms[j]);
				const char *selC = sel_getName(sel);
				NSString *selName = [NSString stringWithUTF8String:selC];
				if (!selName) continue;
				if (strchr(selC, ':')) continue;
				if (!SPEHLooksLikeAvailabilitySelector(selName)) continue;
				if (!SPEHMethodReturnsBool(cms[j])) continue;
				MSHookMessageEx(meta, sel, (IMP)SPEHReturnNOHook, NULL);
				SPEHLog(@"[reader] +[%@ %@] -> NO", clsName, selName);
				methodHits++;
			}
			free(cms);
		}
	}
	free(classes);

	SPEHLog(@"[reader] 'Reader' classes=%d, availability hooks=%d", classHits, methodHits);
}

// MARK: - 返回不重新加载（打开 WebKit back/forward cache）
//
// iOS 16 系统框架在 dyld shared cache 里，无法静态查 SPI 名，
// 故运行时在 WKPreferences 类层次上找所有 *BackForward*Enabled: 的 setter 并置 YES。

static void SPEHLogPreferencesCandidates(id prefs)
{
	SPEHLog(@"[bfcache] dump WKPreferences 候选 setter：");
	Class cls = object_getClass(prefs);
	int depth = 0;
	while (cls && cls != [NSObject class] && depth < 4) {
		unsigned int n = 0;
		Method *ms = class_copyMethodList(cls, &n);
		for (unsigned int i = 0; i < n; i++) {
			NSString *s = NSStringFromSelector(method_getName(ms[i]));
			if (!s) continue;
			BOOL hit = ([s rangeOfString:@"ack" options:NSCaseInsensitiveSearch].location != NSNotFound ||
						[s rangeOfString:@"Cache" options:NSCaseInsensitiveSearch].location != NSNotFound);
			if (hit && [s hasSuffix:@":"]) SPEHLog(@"[bfcache]    %@", s);
		}
		free(ms);
		cls = class_getSuperclass(cls);
		depth++;
	}
}

static void SPEHEnableBFCache(id prefs)
{
	if (!prefs) return;
	static char kMarker;
	if (objc_getAssociatedObject(prefs, &kMarker)) return;
	objc_setAssociatedObject(prefs, &kMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	int applied = 0;
	Class cls = object_getClass(prefs);
	int depth = 0;
	while (cls && cls != [NSObject class] && depth < 6) {
		unsigned int n = 0;
		Method *ms = class_copyMethodList(cls, &n);
		for (unsigned int i = 0; i < n; i++) {
			SEL sel = method_getName(ms[i]);
			const char *selC = sel_getName(sel);
			if (!selC) continue;
			NSString *s = [NSString stringWithUTF8String:selC];
			if (!s) continue;

			BOOL isSetter = [s hasPrefix:@"_set"] || [s hasPrefix:@"set"];
			if (!isSetter || ![s hasSuffix:@":"]) continue;
			if ([s rangeOfString:@"BackForward" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;

			const char *types = method_getTypeEncoding(ms[i]);
			if (!types || types[0] != 'v' || types[1] != '@' || types[2] != ':') continue;

			@try {
				((void (*)(id, SEL, BOOL))objc_msgSend)(prefs, sel, YES);
				SPEHLog(@"[bfcache] %@ -> YES", s);
				applied++;
			} @catch (NSException *e) {
				SPEHLog(@"[bfcache] %@ exception %@", s, e);
			}
		}
		free(ms);
		cls = class_getSuperclass(cls);
		depth++;
	}

	if (applied == 0) SPEHLogPreferencesCandidates(prefs);
}

static IMP gOrigSetPreferences = NULL;
static IMP gOrigPreferencesGetter = NULL;

static void SPEHSetPreferencesHook(id self, SEL _cmd, id prefs)
{
	if (gOrigSetPreferences) ((void (*)(id, SEL, id))gOrigSetPreferences)(self, _cmd, prefs);
	if (SPEHBFCacheEnabled()) SPEHEnableBFCache(prefs);
}

static id SPEHPreferencesGetterHook(id self, SEL _cmd)
{
	id prefs = gOrigPreferencesGetter ? ((id (*)(id, SEL))gOrigPreferencesGetter)(self, _cmd) : nil;
	if (SPEHBFCacheEnabled()) SPEHEnableBFCache(prefs);
	return prefs;
}

static void SPEHInstallBFCacheHooks(void)
{
	if (!SPEHBFCacheEnabled()) { SPEHLog(@"[bfcache] disabled by prefs"); return; }

	Class cfgCls = NSClassFromString(@"WKWebViewConfiguration");
	if (!cfgCls) { SPEHLog(@"[bfcache] WKWebViewConfiguration 未加载"); return; }

	SPEHPatchInstanceMethod(cfgCls, NSSelectorFromString(@"setPreferences:"), (IMP)SPEHSetPreferencesHook, &gOrigSetPreferences);
	SPEHPatchInstanceMethod(cfgCls, NSSelectorFromString(@"preferences"), (IMP)SPEHPreferencesGetterHook, &gOrigPreferencesGetter);
	SPEHLog(@"[bfcache] hooks setPreferences=%s preferences=%s",
			gOrigSetPreferences ? "ok" : "FAILED", gOrigPreferencesGetter ? "ok" : "FAILED");
}

// MARK: - 入口

%ctor
{
	@autoreleasepool {
		if (!SPEHEnabled()) return;

		SPEHLog(@"==============================================");
		SPEHLog(@"Safari16Enhance " SPEH_VERSION " loaded, pid=%d", getpid());
		SPEHLog(@"container home = %@", NSHomeDirectory());
		SPEHLog(@"log file        = %@", SPEHLogPath());
		SPEHLog(@"engine=%d(%@) alert=%d reader=%d bfcache=%d probe=%d",
				SPEHEngineEnabled(), SPEHEngineName(), SPEHAlertSuppressEnabled(),
				SPEHReaderKillEnabled(), SPEHBFCacheEnabled(), SPEHProbeEnabled());

		SPEHInstallAlertHooks();
		SPEHInstallReaderHooks();
		SPEHInstallBFCacheHooks();
		SPEHScheduleSearchEngineHookInstall();

		if (SPEHProbeEnabled()) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
					unsigned int count = 0;
					Class *classes = objc_copyClassList(&count);
					NSMutableArray *readerCls = [NSMutableArray array];
					for (unsigned int i = 0; i < count; i++) {
						const char *nm = class_getName(classes[i]);
						if (!nm) continue;
						NSString *s = [NSString stringWithUTF8String:nm];
						if (s && [s rangeOfString:@"Reader"].location != NSNotFound) [readerCls addObject:s];
					}
					free(classes);
					SPEHLog(@"[probe] Reader classes: %@", [readerCls componentsJoinedByString:@", "]);
				});
			});
		}
	}
}
