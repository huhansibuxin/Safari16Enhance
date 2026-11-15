// Safari16Enhance 0.3.0 - iOS 16 Safari 增强
//
// 实测事实链：
//   0.1.0：引擎注入成功（_SFSearchEngineController + _populateSearchEngines，10 个引擎）；
//          「打不开该网页」弹窗对 presentViewController 零命中。
//   0.2.0：加上 UIAlertController 工厂 + viewWillAppear/viewDidAppear + 全窗口监听，仍然零命中；
//          窗口日志里只有 MobileSafariWindow / UITextEffectsWindow / UIRemoteKeyboardWindow。
//          → 该弹窗不是 UIAlertController，也不经过 UIViewController present 链路。
//          → 设备上只有 com.apple.mobilesafari 一个 UI 进程（无 SafariViewService），排除跨进程。
//          → 唯一剩下的形态：直接往 window 上挂自定义 view（或自定义 VC 但绕开了 present）。
//   阅读器：0.2.0 的类名通扫命中 3 个真实方法，老板实测已生效。
//   bfcache：0.2.0 dump 出的 WKPreferences 候选 setter 里没有 BackForward 相关，
//          iOS 16 上不存在 _setBackForwardCacheEnabled: 这类开关 → 换候选名 + 全量 dump 确认。
//
// 0.4.0 变更（基于 0.3.0 日志实证）：
//   1. 弹窗：真身确认是 Safari 自绘的 SFDialogView（挂在 _SFWebView 上），
//      改 hook -[SFDialogView didMoveToWindow] / layoutSubviews，递归取文本，
//      只有命中「打不开该网页 / 网址无效」才 removeFromSuperview + toast，不误伤网页 JS 对话框
//   2. 返回：实测左滑手势返回有缓存、按钮返回重载 → 不是 bfcache 问题，是调用路径多了一次 reload，
//      改为 goBack/goForward 打开 2 秒窗口，窗口内吞掉 reload / reloadFromOrigin
//   3. bfcache：确认 iOS 16 WKPreferences 无相关 SPI，dump 改为每类只做一次，避免刷日志
//
// 原则：所有 hook 先检查类/方法存在性，返回类型校验，全部 @try 包裹，绝不让 Safari 崩

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <unistd.h>

#define SPEH_VERSION "0.4.0"

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

// MARK: - 搜索引擎注入（已实测可用，逻辑保持不变）

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

	for (NSString *name in @[ @"_populateSearchEngines", @"populateSearchEngines", @"_updateSearchEngines" ]) {
		SEL sel = NSSelectorFromString(name);
		if (class_getInstanceMethod(gSearchEngineControllerClass, sel)) {
			SPEHPatchInstanceMethod(gSearchEngineControllerClass, sel, (IMP)SPEHPopulateSearchEnginesHook, &gOrigPopulateSearchEngines);
			break;
		}
	}

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

// MARK: - 弹窗拦截
//
// 0.2.0 结论：该弹窗既不是 UIAlertController，也不经过 UIViewController present 链路，
// 且设备上只有 com.apple.mobilesafari 一个 UI 进程，因此只可能是「直接挂 view 到 window」。
// 0.3.0 加视图层探针，用类名过滤 + 去重，把真实类名抓出来。

static IMP gOrigPresentViewController = NULL;
static IMP gOrigAlertFactory = NULL;
static IMP gOrigAlertViewWillAppear = NULL;
static IMP gOrigAlertViewDidAppear = NULL;
static IMP gOrigUIViewDidMoveToWindow = NULL;
static IMP gOrigVCViewDidAppear = NULL;

static NSMutableSet *gSeenViewClasses = nil;
static NSLock *gSeenLock = nil;

static void SPEHInitSeenSets(void)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		gSeenViewClasses = [NSMutableSet set];
		gSeenLock = [[NSLock alloc] init];
	});
}

// 只看类名像弹窗的，避免刷屏
static BOOL SPEHClassNameLooksLikeAlert(const char *name)
{
	if (!name) return NO;
	return (strstr(name, "Alert") != NULL) ||
		   (strstr(name, "Dialog") != NULL) ||
		   (strstr(name, "Prompt") != NULL);
}

// 首次见到某类名才记录，返回 YES 表示是新类
static BOOL SPEHMarkSeen(NSString *cls)
{
	if (cls.length == 0) return NO;
	SPEHInitSeenSets();
	[gSeenLock lock];
	BOOL isNew = ![gSeenViewClasses containsObject:cls];
	if (isNew) [gSeenViewClasses addObject:cls];
	[gSeenLock unlock];
	return isNew;
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

static BOOL SPEHIsTargetErrorAlert(UIAlertController *alert)
{
	NSString *title = alert.title ?: @"";
	NSString *message = alert.message ?: @"";
	return SPEHTextMatchesError([title stringByAppendingString:message]);
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

// ① present 链路（保留兜底）
static void SPEHPresentViewControllerHook(UIViewController *self, SEL _cmd, UIViewController *vc, BOOL animated, void (^completion)(void))
{
	if (SPEHProbeEnabled() && vc) {
		NSString *cls = NSStringFromClass([vc class]);
		if (SPEHClassNameLooksLikeAlert([cls UTF8String]) && SPEHMarkSeen(cls)) {
			SPEHLog(@"[alert] present 链路首次出现类: %@", cls);
		}
	}
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

// ② 工厂方法
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

// ③ 生命周期
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

// ④ 视图层探针：任何类名像弹窗的 view 挂到 window 上都会命中
static void SPEHUIViewDidMoveToWindowHook(UIView *self, SEL _cmd)
{
	if (gOrigUIViewDidMoveToWindow) ((void (*)(id, SEL))gOrigUIViewDidMoveToWindow)(self, _cmd);

	if (!SPEHProbeEnabled()) return;
	if (!self.window) return;

	const char *name = class_getName(object_getClass(self));
	if (!SPEHClassNameLooksLikeAlert(name)) return;
	// SFDialog* 由专用模块处理，这里不重复记
	if (strncmp(name, "SFDialog", 8) == 0) return;

	NSString *cls = [NSString stringWithUTF8String:name];
	if (!SPEHMarkSeen(cls)) return;

	NSMutableString *chain = [NSMutableString string];
	UIView *v = self.superview;
	int depth = 0;
	while (v && depth < 6) {
		if (chain.length) [chain appendString:@" <- "];
		[chain appendString:NSStringFromClass([v class])];
		v = v.superview;
		depth++;
	}
	NSString *text = @"-";
	if ([self isKindOfClass:[UILabel class]]) text = ((UILabel *)self).text ?: @"-";
	SPEHLog(@"[alertview] 挂载 class=%@ frame=%@ windowLevel=%.0f chain=%@ text=%@",
			cls, NSStringFromCGRect(self.frame), self.window.windowLevel,
			chain.length ? chain : @"(root)", text);
}

// ⑤ 视图控制器层探针：绕开 present 的自定义 VC 也能抓到
static void SPEHVCViewDidAppearHook(UIViewController *self, SEL _cmd)
{
	if (gOrigVCViewDidAppear) ((void (*)(id, SEL))gOrigVCViewDidAppear)(self, _cmd);

	if (!SPEHProbeEnabled()) return;
	const char *name = class_getName(object_getClass(self));
	if (!SPEHClassNameLooksLikeAlert(name) && !strstr(name, "Error")) return;

	NSString *cls = [NSString stringWithUTF8String:name];
	if (!SPEHMarkSeen(cls)) return;
	SPEHLog(@"[alertvc] appear class=%@ presenter=%@", cls,
			self.presentingViewController ? NSStringFromClass([self.presentingViewController class]) : @"-");
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

	SPEHPatchInstanceMethod([UIView class], @selector(didMoveToWindow),
							(IMP)SPEHUIViewDidMoveToWindowHook, &gOrigUIViewDidMoveToWindow);
	SPEHLog(@"[hook] viewDidMoveToWindow=%s", gOrigUIViewDidMoveToWindow ? "ok" : "FAILED");

	SPEHPatchInstanceMethod([UIViewController class], @selector(viewDidAppear:),
							(IMP)SPEHVCViewDidAppearHook, &gOrigVCViewDidAppear);
	SPEHLog(@"[hook] vcViewDidAppear=%s", gOrigVCViewDidAppear ? "ok" : "FAILED");

	// 窗口监听：只记非键盘窗
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

// MARK: - SFDialogView 精准击杀（0.3.0 日志实证的真身）
//
// 实测证据（13:38:52）：
//   [alertview] 挂载 class=SFDialogView frame={{0,0},{430,932}}
//   chain = _SFWebView <- TabDocumentView <- UIScrollView <- SFOrderedContainerView
// 结论：「Safari 打不开该网页 / 因为网址无效」不是 UIAlertController，
// 而是 Safari 自绘的 SFDialogView（内含 SFDialogContentView + SFDialogTextView），
// 直接 addSubview 到 _SFWebView 上，所以 presentViewController / alert 工厂永远抓不到。
//
// 处理：只按文本内容精准命中才拆，避免误伤网页自己的 JS alert/confirm/prompt。

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

static char kSFDialogHandledKey;
static char kSFDialogLastCheckKey;

static void SPEHInspectSFDialog(UIView *dialog)
{
	if (!dialog) return;
	if (!SPEHAlertSuppressEnabled()) return;
	if (objc_getAssociatedObject(dialog, &kSFDialogHandledKey)) return;

	// 节流：同一对话框 0.25s 内只检查一次
	NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
	NSNumber *last = objc_getAssociatedObject(dialog, &kSFDialogLastCheckKey);
	if (last && (now - last.doubleValue) < 0.25) return;
	objc_setAssociatedObject(dialog, &kSFDialogLastCheckKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	NSString *text = SPEHCollectDialogText(dialog, 0);
	if (text.length == 0) return;

	if (!SPEHTextMatchesError(text)) {
		// 不是目标对话框：只记一次，便于确认没有误伤网页自己的 JS 弹窗
		static char kLoggedKey;
		if (!objc_getAssociatedObject(dialog, &kLoggedKey)) {
			objc_setAssociatedObject(dialog, &kLoggedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			if (SPEHProbeEnabled()) SPEHLog(@"[sfdialog] 放行（非目标）text=%@", text);
		}
		return;
	}

	objc_setAssociatedObject(dialog, &kSFDialogHandledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	SPEHLog(@"[sfdialog] 精准命中并拆除 class=%@ text=%@ frame=%@", NSStringFromClass([dialog class]), text, NSStringFromCGRect(dialog.frame));

	@try { [dialog removeFromSuperview]; } @catch (NSException *e) { }
	SPEHShowToast(@"网页无法打开");
}

static IMP gOrigSFDialogDidMoveToWindow = NULL;
static IMP gOrigSFDialogLayoutSubviews = NULL;

static void SPEHSFDialogDidMoveToWindowHook(UIView *self, SEL _cmd)
{
	if (gOrigSFDialogDidMoveToWindow) ((void (*)(id, SEL))gOrigSFDialogDidMoveToWindow)(self, _cmd);
	if (!self.window) return;
	// 文本常在挂载后才写入，延迟一次再判
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
	if (!SPEHAlertSuppressEnabled()) { SPEHLog(@"[sfdialog] disabled by prefs"); return; }

	Class cls = NSClassFromString(@"SFDialogView");
	if (!cls) {
		// 兜底：运行时按名字找
		unsigned int count = 0;
		Class *classes = objc_copyClassList(&count);
		for (unsigned int i = 0; i < count; i++) {
			const char *nm = class_getName(classes[i]);
			if (nm && strcmp(nm, "SFDialogView") == 0) { cls = classes[i]; break; }
		}
		free(classes);
	}
	if (!cls) { SPEHLog(@"[sfdialog] SFDialogView 未找到"); return; }

	SPEHPatchInstanceMethod(cls, @selector(didMoveToWindow), (IMP)SPEHSFDialogDidMoveToWindowHook, &gOrigSFDialogDidMoveToWindow);
	SPEHPatchInstanceMethod(cls, @selector(layoutSubviews), (IMP)SPEHSFDialogLayoutSubviewsHook, &gOrigSFDialogLayoutSubviews);

	SPEHLog(@"[sfdialog] hooks didMoveToWindow=%s layoutSubviews=%s",
			gOrigSFDialogDidMoveToWindow ? "ok" : "FAILED",
			gOrigSFDialogLayoutSubviews ? "ok" : "FAILED");
}

// MARK: - 阅读器击杀（白名单精准命中）
//
// 0.2.0 实测确认的三个方法（类名通扫的产物），改为写死白名单：
//   -[_SFReaderController isReaderAvailable]
//   -[_SFWebProcessPlugInReaderEnabledPageController readerHasBeenActivatedRecently]
//   -[WBSReaderAvailabilityCheckResult isReaderAvailable]
// 另外补 _SFReaderController 的其它可用性表达，以及自动阅读器激活管理器的判定。

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
		if (!m) { miss++; continue; }
		if (!SPEHMethodReturnsBool(m)) { miss++; continue; }

		MSHookMessageEx(cls, sel, (IMP)SPEHReturnNOHook, NULL);
		SPEHLog(@"[reader] 精准命中 -[%s %s] -> NO", clsC, selC);
		hit++;
	}

	SPEHLog(@"[reader] 白名单 total=%lu hit=%d miss=%d", (unsigned long)total, hit, miss);

	// 兜底：0.2.0 的通扫保留为可选开关（默认关）
	if (SPEHBoolPref(@"readerDeepScan", NO)) {
		unsigned int count = 0;
		Class *classes = objc_copyClassList(&count);
		int scans = 0;
		for (unsigned int i = 0; i < count; i++) {
			const char *name = class_getName(classes[i]);
			if (!name || !strstr(name, "Reader")) continue;
			unsigned int mcount = 0;
			Method *methods = class_copyMethodList(classes[i], &mcount);
			for (unsigned int j = 0; j < mcount; j++) {
				const char *selC = sel_getName(method_getName(methods[j]));
				if (!selC || strchr(selC, ':')) continue;
				NSString *s = [NSString stringWithUTF8String:selC];
				if (!s) continue;
				if (!([s hasPrefix:@"isReader"] || [s hasPrefix:@"reader"] || [s hasPrefix:@"isArticleAvailable"])) continue;
				if (!SPEHMethodReturnsBool(methods[j])) continue;
				MSHookMessageEx(classes[i], method_getName(methods[j]), (IMP)SPEHReturnNOHook, NULL);
				scans++;
			}
			free(methods);
		}
		free(classes);
		SPEHLog(@"[reader] deepScan 额外命中 %d", scans);
	}
}

// MARK: - 返回不重新加载（bfcache）
//
// 0.3.0 实测：WKPreferences 上不存在任何 *BackForward* setter。
// 0.4.0 追加实测（用户体感）：左滑手势返回有缓存、按钮返回仍重载
//   → 说明页面本身还在内存里，差别只在调用路径：按钮返回额外触发了一次 reload。
//   → 对策：后退窗口期内吞掉 reload/reloadFromOrigin，让导航自己走完。

static void SPEHDumpCacheRelated(id obj, NSString *tag)
{
	if (!obj) return;
	Class cls = object_getClass(obj);
	int depth = 0;
	int printed = 0;
	SPEHLog(@"[bfcache] dump %@ (真实类 %@)", tag, NSStringFromClass(cls));

	while (cls && cls != [NSObject class] && depth < 5) {
		unsigned int n = 0;
		Method *ms = class_copyMethodList(cls, &n);
		for (unsigned int i = 0; i < n; i++) {
			NSString *s = NSStringFromSelector(method_getName(ms[i]));
			if (!s) continue;
			BOOL hit = ([s rangeOfString:@"Back" options:NSCaseInsensitiveSearch].location != NSNotFound ||
						[s rangeOfString:@"Forward" options:NSCaseInsensitiveSearch].location != NSNotFound ||
						[s rangeOfString:@"Cache" options:NSCaseInsensitiveSearch].location != NSNotFound ||
						[s rangeOfString:@"Snapshot" options:NSCaseInsensitiveSearch].location != NSNotFound ||
						[s rangeOfString:@"Restore" options:NSCaseInsensitiveSearch].location != NSNotFound);
			if (!hit) continue;
			if (![s hasSuffix:@":"]) continue;
			SPEHLog(@"[bfcache]   %@ -%@", NSStringFromClass(cls), s);
			printed++;
			if (printed > 80) { free(ms); return; }
		}
		free(ms);
		cls = class_getSuperclass(cls);
		depth++;
	}
	SPEHLog(@"[bfcache] dump %@ 完成，候选 %d 条", tag, printed);
}

static const char *kCacheSetterCandidates[] = {
	"_setBackForwardCacheEnabled:",
	"setBackForwardCacheEnabled:",
	"_setUsesBackForwardCache:",
	"setUsesBackForwardCache:",
	"_setPageCacheEnabled:",
	"setPageCacheEnabled:",
	"_setUsesPageCache:",
	"setUsesPageCache:",
	"_setBackForwardCacheEnabledForTesting:",
};

static int SPEHTryCacheSetters(id obj)
{
	if (!obj) return 0;
	int applied = 0;
	NSUInteger total = sizeof(kCacheSetterCandidates) / sizeof(kCacheSetterCandidates[0]);

	for (NSUInteger i = 0; i < total; i++) {
		SEL sel = sel_getUid(kCacheSetterCandidates[i]);
		if (![obj respondsToSelector:sel]) continue;

		@try {
			((void (*)(id, SEL, BOOL))objc_msgSend)(obj, sel, YES);
			SPEHLog(@"[bfcache] 命中并置 YES: %s", kCacheSetterCandidates[i]);
			applied++;
		} @catch (NSException *e) {
			SPEHLog(@"[bfcache] %s 异常 %@", kCacheSetterCandidates[i], e);
		}
	}

	// KVC 兜底（属性存在但方法名不同时）
	for (NSString *key in @[ @"backForwardCacheEnabled", @"usesBackForwardCache", @"pageCacheEnabled", @"usesPageCache" ]) {
		@try {
			[obj setValue:@YES forKey:key];
			SPEHLog(@"[bfcache] KVC 命中并置 YES: %@", key);
			applied++;
		} @catch (NSException *e) { }
	}

	return applied;
}

static void SPEHEnableBFCache(id prefs)
{
	if (!prefs) return;
	static char kMarker;
	if (objc_getAssociatedObject(prefs, &kMarker)) return;
	objc_setAssociatedObject(prefs, &kMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	int applied = SPEHTryCacheSetters(prefs);
	if (applied == 0) {
		// 同一类只 dump 一次，避免每次 setPreferences 都刷日志、白跑一遍方法遍历
		static char kDumpedMarker;
		NSString *clsName = NSStringFromClass(object_getClass(prefs));
		if (!objc_getAssociatedObject(clsName, &kDumpedMarker)) {
			objc_setAssociatedObject(clsName, &kDumpedMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
			SPEHDumpCacheRelated(prefs, @"preferences");
		}
	}
}

static IMP gOrigSetPreferences = NULL;
static IMP gOrigPreferencesGetter = NULL;
static IMP gOrigSetConfiguration = NULL;

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

// WKWebViewConfiguration 本身也可能带缓存开关
static void SPEHSetConfigurationHook(id self, SEL _cmd, id cfg)
{
	if (gOrigSetConfiguration) ((void (*)(id, SEL, id))gOrigSetConfiguration)(self, _cmd, cfg);
	if (!SPEHBFCacheEnabled() || !cfg) return;

	static char kCfgMarker;
	if (objc_getAssociatedObject(cfg, &kCfgMarker)) return;
	objc_setAssociatedObject(cfg, &kCfgMarker, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

	int applied = SPEHTryCacheSetters(cfg);
	id prefs = nil;
	@try { prefs = [cfg valueForKey:@"preferences"]; } @catch (NSException *e) { }
	if (prefs) applied += SPEHTryCacheSetters(prefs);
	if (applied == 0) SPEHDumpCacheRelated(cfg, @"WKWebViewConfiguration");
}

static void SPEHInstallBackNavigationHooks(void);

static void SPEHInstallBFCacheHooks(void)
{
	if (!SPEHBFCacheEnabled()) { SPEHLog(@"[bfcache] disabled by prefs"); return; }

	Class cfgCls = NSClassFromString(@"WKWebViewConfiguration");
	if (!cfgCls) { SPEHLog(@"[bfcache] WKWebViewConfiguration 未加载"); return; }

	SPEHPatchInstanceMethod(cfgCls, NSSelectorFromString(@"setPreferences:"), (IMP)SPEHSetPreferencesHook, &gOrigSetPreferences);
	SPEHPatchInstanceMethod(cfgCls, NSSelectorFromString(@"preferences"), (IMP)SPEHPreferencesGetterHook, &gOrigPreferencesGetter);

	Class wkCls = NSClassFromString(@"WKWebView");
	SPEHPatchInstanceMethod(wkCls, NSSelectorFromString(@"_setConfiguration:"), (IMP)SPEHSetConfigurationHook, &gOrigSetConfiguration);

	SPEHLog(@"[bfcache] hooks setPreferences=%s preferences=%s _setConfiguration=%s",
			gOrigSetPreferences ? "ok" : "FAILED", gOrigPreferencesGetter ? "ok" : "FAILED",
			gOrigSetConfiguration ? "ok" : "FAILED");

	SPEHInstallBackNavigationHooks();
}

// MARK: - 后退不重载（0.4.0）
//
// 用户实测：左滑手势返回不重载、按钮返回重载 → 差别在调用路径，不是 bfcache。
// 做法：goBack/goForward 打开一个 2 秒窗口，窗口内把 reload / reloadFromOrigin 吞掉。

static NSTimeInterval gBackNavWindowUntil = 0;
static IMP gOrigWKGoBack = NULL;
static IMP gOrigWKGoForward = NULL;
static IMP gOrigWKReload = NULL;
static IMP gOrigWKReloadFromOrigin = NULL;

static NSString *SPEHBackItemURL(id webView)
{
	NSString *url = @"-";
	@try {
		id list = [webView valueForKey:@"backForwardList"];
		if (!list) return url;
		id item = [list valueForKey:@"backItem"];
		if (!item) return url;
		id u = [item valueForKey:@"URL"];
		if ([u isKindOfClass:[NSURL class]]) url = [(NSURL *)u absoluteString] ?: @"-";
	} @catch (NSException *e) { }
	return url;
}

static void SPEHOpenBackWindow(NSString *why, NSString *target)
{
	gBackNavWindowUntil = [NSDate timeIntervalSinceReferenceDate] + 2.0;
	SPEHLog(@"[backnav] 打开窗口 why=%@ target=%@", why, target);
}

static void SPEHWKGoBackHook(id self, SEL _cmd)
{
	SPEHOpenBackWindow(@"goBack", SPEHBackItemURL(self));
	if (gOrigWKGoBack) ((void (*)(id, SEL))gOrigWKGoBack)(self, _cmd);
}

static void SPEHWKGoForwardHook(id self, SEL _cmd)
{
	SPEHOpenBackWindow(@"goForward", @"-");
	if (gOrigWKGoForward) ((void (*)(id, SEL))gOrigWKGoForward)(self, _cmd);
}

static BOOL SPEHShouldSwallowReload(void)
{
	if (!SPEHBoolPref(@"blockReloadOnBack", YES)) return NO;
	return gBackNavWindowUntil > [NSDate timeIntervalSinceReferenceDate];
}

static void SPEHWKReloadHook(id self, SEL _cmd)
{
	if (SPEHShouldSwallowReload()) {
		SPEHLog(@"[backnav] 后退窗口内吞掉 reload，避免重新加载");
		return;
	}
	if (gOrigWKReload) ((void (*)(id, SEL))gOrigWKReload)(self, _cmd);
}

static void SPEHWKReloadFromOriginHook(id self, SEL _cmd)
{
	if (SPEHShouldSwallowReload()) {
		SPEHLog(@"[backnav] 后退窗口内吞掉 reloadFromOrigin，避免重新加载");
		return;
	}
	if (gOrigWKReloadFromOrigin) ((void (*)(id, SEL))gOrigWKReloadFromOrigin)(self, _cmd);
}

static void SPEHInstallBackNavigationHooks(void)
{
	Class wkCls = NSClassFromString(@"WKWebView");
	if (!wkCls) { SPEHLog(@"[backnav] WKWebView 未加载"); return; }

	SPEHPatchInstanceMethod(wkCls, NSSelectorFromString(@"goBack"), (IMP)SPEHWKGoBackHook, &gOrigWKGoBack);
	SPEHPatchInstanceMethod(wkCls, NSSelectorFromString(@"goForward"), (IMP)SPEHWKGoForwardHook, &gOrigWKGoForward);
	SPEHPatchInstanceMethod(wkCls, NSSelectorFromString(@"reload"), (IMP)SPEHWKReloadHook, &gOrigWKReload);
	SPEHPatchInstanceMethod(wkCls, NSSelectorFromString(@"reloadFromOrigin"), (IMP)SPEHWKReloadFromOriginHook, &gOrigWKReloadFromOrigin);

	// Safari 自己的 webview 子类可能 override 这些，逐个补
	NSArray *subclassNames = @[ @"_SFWebView", @"SFWebView" ];
	for (NSString *name in subclassNames) {
		Class sub = NSClassFromString(name);
		if (!sub) continue;
		unsigned int n = 0;
		Method *ms = class_copyMethodList(sub, &n);
		for (unsigned int i = 0; i < n; i++) {
			NSString *s = NSStringFromSelector(method_getName(ms[i]));
			if ([s isEqualToString:@"goBack"]) {
				SPEHPatchInstanceMethod(sub, NSSelectorFromString(s), (IMP)SPEHWKGoBackHook, NULL);
			} else if ([s isEqualToString:@"reload"]) {
				SPEHPatchInstanceMethod(sub, NSSelectorFromString(s), (IMP)SPEHWKReloadHook, NULL);
			} else if ([s isEqualToString:@"reloadFromOrigin"]) {
				SPEHPatchInstanceMethod(sub, NSSelectorFromString(s), (IMP)SPEHWKReloadFromOriginHook, NULL);
			}
		}
		free(ms);
	}

	SPEHLog(@"[backnav] hooks goBack=%s goForward=%s reload=%s reloadFromOrigin=%s",
			gOrigWKGoBack ? "ok" : "FAILED", gOrigWKGoForward ? "ok" : "FAILED",
			gOrigWKReload ? "ok" : "FAILED", gOrigWKReloadFromOrigin ? "ok" : "FAILED");
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
		SPEHInstallSFDialogHooks();
		SPEHInstallReaderHooks();
		SPEHInstallBFCacheHooks();
		SPEHScheduleSearchEngineHookInstall();
	}
}
