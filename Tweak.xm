// Safari16Enhance 0.5.0 - iOS 16 Safari 增强
//
// 实测结论链（每条都来自真机日志，不是推测）：
//   引擎：_SFSearchEngineController + _populateSearchEngines，注入自建引擎可用（0.1.0 起稳定）
//   阅读器：三个真实方法已确认，白名单精准命中有效
//   弹窗：真身是 Safari 自绘的 SFDialogView（挂在 _SFWebView 上），
//        不是 UIAlertController、不走 presentViewController —— 0.4.0 按文本精准拆除，实测生效
//   返回：iOS 16 WKPreferences 无任何 bfcache 开关（已全量 dump 确认），
//        左滑手势返回有缓存、按钮返回重载 → 差别在调用路径
//
// 0.5.0 变更：
//   1. 只保留精准命中：删除 presentViewController / UIAlertController 工厂 /
//      viewWillAppear / viewDidAppear / 全局 UIView didMoveToWindow 等宽泛 hook，
//      全局 view hook 本身也是「返回后滑不动」的重点嫌疑
//   2. 「App 内打开」：网页自绘浮层用 JS 清（只删 fixed/sticky 小文本节点）
//   3. Smart App Banner：删 apple-itunes-app meta + 原生 view 层直接拆除（运行时按类名找）
//   4. 返回后滚动恢复：goBack 后分三个时间点复位 scrollView
//
// 原则：hook 只挂具体类，先查存在性，全部 @try 包裹，绝不让 Safari 崩

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <unistd.h>

#define SPEH_VERSION "0.6.1"

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
static BOOL SPEHDialogKillEnabled(void)    { return SPEHBoolPref(@"suppressErrorAlert", YES); }
static BOOL SPEHReaderKillEnabled(void)    { return SPEHBoolPref(@"killReader", YES); }
static BOOL SPEHOpenInAppKillEnabled(void) { return SPEHBoolPref(@"killOpenInApp", YES); }
static BOOL SPEHBackScrollFixEnabled(void) { return SPEHBoolPref(@"fixBackScroll", YES); }
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

// MARK: - 搜索引擎注入（已验证可用）

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
	SPEHLog(@"[engine] controller=%@ info=%@ populate=%s", NSStringFromClass(gSearchEngineControllerClass),
			NSStringFromClass(gSearchEngineInfoClass), gOrigPopulateSearchEngines ? "ok" : "FAILED");
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
			 "var ms=document.querySelectorAll('meta[name=apple-itunes-app]');"
			 "for(var i=0;i<ms.length;i++){if(ms[i].parentNode)ms[i].parentNode.removeChild(ms[i]);r.m++;}"
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
			if (!SPEHProbeEnabled()) return;
			if (!r || [r isEqualToString:@"meta=0 el=0"]) {
				SPEHLog(@"[openinapp] JS 已执行，本页无可清理浮层/meta");
				return;
			}
			SPEHLog(@"[openinapp] 清理结果 %@", r);
		}];
	} @catch (NSException *e) { }
}

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

static void SPEHInstallSmartAppBannerProbe(void)
{
	// 不做任何 hook，只记录当前策略，避免再次踩同一个坑
	SPEHLog(@"[smartbanner] 原生 hook 已移除（0.6.0 曾因父子类重复 hook 自递归崩溃）");
}

static IMP gOrigWVDidMoveToWindow = NULL;

// 定义在后文的返回缓存模块里，这里先声明
static void SPEHApplyProcessPoolCache(id webView);

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
		SPEHApplyProcessPoolCache(self);
		if (SPEHProbeEnabled()) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
				dispatch_get_main_queue(), ^{
					SPEHDumpBannerCandidates(weakSelf);
				});
		}
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

	SPEHInstallSmartAppBannerProbe();
}

// MARK: - 拦截跳转 App Store
//
// 老板要求：任何网站都不允许跳 App Store。
// 网页跳 App Store 只有两种形态：
//   ① itms / itms-apps / itms-appss / itms-services 这些 scheme
//   ② apps.apple.com / itunes.apple.com / testflight.apple.com 这些苹果域名
// 拦截点：进程内 UIApplication.openURL 系列 + LaunchServices 兜底。
// 正常网页 https 一律放行，不碰任何非苹果域。

static BOOL SPEHAppStoreKillEnabled(void) { return SPEHBoolPref(@"blockAppStore", YES); }

static BOOL SPEHURLTargetsAppStore(NSURL *url)
{
	if (!url) return NO;
	@try {
		NSString *scheme = url.scheme.lowercaseString ?: @"";
		if ([scheme hasPrefix:@"itms"]) return YES;
		NSString *host = url.host.lowercaseString ?: @"";
		if (host.length) {
			if ([host hasSuffix:@"apps.apple.com"] ||
				[host hasSuffix:@"itunes.apple.com"] ||
				[host hasSuffix:@"testflight.apple.com"]) return YES;
		}
	} @catch (NSException *e) { }
	return NO;
}

static IMP gOrigOpenURLOptions = NULL;
static IMP gOrigOpenURL = NULL;
static IMP gOrigLSWorkspaceOpen = NULL;

static void SPEHOpenURLOptionsHook(id self, SEL _cmd, NSURL *url, NSDictionary *options, id completion)
{
	if (SPEHAppStoreKillEnabled() && SPEHURLTargetsAppStore(url)) {
		SPEHLog(@"[appstore] 拦截跳转 %@", url.absoluteString);
		SPEHShowToast(@"已拦截跳转 App Store");
		if (completion) {
			void (^cb)(BOOL) = completion;
			@try { cb(NO); } @catch (NSException *e) { }
		}
		return;
	}
	if (gOrigOpenURLOptions) {
		((void (*)(id, SEL, NSURL *, NSDictionary *, id))gOrigOpenURLOptions)(self, _cmd, url, options, completion);
	}
}

static BOOL SPEHOpenURLHook(id self, SEL _cmd, NSURL *url)
{
	if (SPEHAppStoreKillEnabled() && SPEHURLTargetsAppStore(url)) {
		SPEHLog(@"[appstore] 拦截跳转(legacy) %@", url.absoluteString);
		SPEHShowToast(@"已拦截跳转 App Store");
		return NO;
	}
	if (gOrigOpenURL) return ((BOOL (*)(id, SEL, NSURL *))gOrigOpenURL)(self, _cmd, url);
	return NO;
}

static BOOL SPEHLSWorkspaceOpenHook(id self, SEL _cmd, NSURL *url, NSDictionary *options)
{
	if (SPEHAppStoreKillEnabled() && SPEHURLTargetsAppStore(url)) {
		SPEHLog(@"[appstore] 拦截 LaunchServices %@", url.absoluteString);
		return NO;
	}
	if (gOrigLSWorkspaceOpen) {
		return ((BOOL (*)(id, SEL, NSURL *, NSDictionary *))gOrigLSWorkspaceOpen)(self, _cmd, url, options);
	}
	return NO;
}

static void SPEHInstallAppStoreHooks(void)
{
	if (!SPEHAppStoreKillEnabled()) { SPEHLog(@"[appstore] disabled by prefs"); return; }

	SPEHPatchInstanceMethod([UIApplication class],
		NSSelectorFromString(@"openURL:options:completionHandler:"),
		(IMP)SPEHOpenURLOptionsHook, &gOrigOpenURLOptions);
	SPEHPatchInstanceMethod([UIApplication class],
		NSSelectorFromString(@"openURL:"),
		(IMP)SPEHOpenURLHook, &gOrigOpenURL);

	Class lsCls = NSClassFromString(@"LSApplicationWorkspace");
	if (lsCls) {
		SPEHPatchInstanceMethod(lsCls, NSSelectorFromString(@"openURL:withOptions:"),
			(IMP)SPEHLSWorkspaceOpenHook, &gOrigLSWorkspaceOpen);
	}

	SPEHLog(@"[appstore] hooks optionsHandler=%s legacyOpenURL=%s launchservices=%s",
			gOrigOpenURLOptions ? "ok" : "FAILED",
			gOrigOpenURL ? "ok" : "FAILED",
			gOrigLSWorkspaceOpen ? "ok" : "missing");
}

// MARK: - 返回缓存：WKProcessPool 原生接口探针
//
// 0.3.0 已全量 dump 证实：WKPreferences / WKWebViewConfiguration 上没有任何
// BackForward / PageCache 开关。iOS 16 唯一还可能存在原生接口的地方是
// WKProcessPool（底层 WebProcessPool 才有 back/forward cache 容量控制）。
// 这里做定向查找 + 全量 dump，命中就置值，没命中说明也没有。

static void SPEHDumpProcessPoolCacheSpis(void)
{
	Class poolCls = NSClassFromString(@"WKProcessPool");
	if (!poolCls) { SPEHLog(@"[bfcache] WKProcessPool 未加载"); return; }

	NSMutableArray *hits = [NSMutableArray array];
	for (int pass = 0; pass < 2; pass++) {
		Class c = pass == 0 ? poolCls : NSClassFromString(@"_WKProcessPoolConfiguration");
		if (!c) continue;
		unsigned int n = 0;
		Method *ms = class_copyMethodList(c, &n);
		for (unsigned int i = 0; i < n; i++) {
			const char *nm = sel_getName(method_getName(ms[i]));
			if (strstr(nm, "BackForward") || strstr(nm, "PageCache") || strstr(nm, "CacheCapacity")) {
				[hits addObject:[NSString stringWithFormat:@"%s>%s", class_getName(c), nm]];
			}
		}
		free(ms);
	}
	SPEHLog(@"[bfcache] WKProcessPool 候选 %lu 条: %@",
			(unsigned long)hits.count, hits.count ? [hits componentsJoinedByString:@", "] : @"(无)");
}

static int SPEHTryProcessPoolCacheSetters(id pool)
{
	if (!pool) return 0;
	NSArray *names = @[
		@"_setBackForwardCacheEnabled:", @"_setUsesBackForwardCache:",
		@"_setPageCacheEnabled:", @"_setUsesPageCache:",
		@"_setBackForwardCacheCapacity:", @"_setPageCacheCapacity:", @"_setBackForwardCapacity:"
	];
	int applied = 0;
	for (NSString *nm in names) {
		SEL sel = NSSelectorFromString(nm);
		if (![pool respondsToSelector:sel]) continue;
		@try {
			if ([nm rangeOfString:@"Capacity"].location != NSNotFound) {
				((void (*)(id, SEL, unsigned long))objc_msgSend)(pool, sel, (unsigned long)16);
			} else {
				((void (*)(id, SEL, BOOL))objc_msgSend)(pool, sel, YES);
			}
			SPEHLog(@"[bfcache] WKProcessPool %@ 已置值", nm);
			applied++;
		} @catch (NSException *e) { }
	}
	return applied;
}

static void SPEHApplyProcessPoolCache(id webView)
{
	if (!webView) return;
	@try {
		id cfg = [webView valueForKey:@"configuration"];
		id pool = cfg ? [cfg valueForKey:@"processPool"] : nil;
		if (!pool) return;
		static char kDone;
		if (objc_getAssociatedObject(pool, &kDone)) return;
		objc_setAssociatedObject(pool, &kDone, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

		int n = SPEHTryProcessPoolCacheSetters(pool);
		SPEHDumpProcessPoolCacheSpis();
		SPEHLog(@"[bfcache] processPool 原生接口命中 %d 条（0=确认不存在）", n);
	} @catch (NSException *e) { }
}

// MARK: - 返回后滚动恢复
//
// 老板实测：返回上一页后，页面前几次上/下滑完全不响应，加载完也要滑几下才生效。
// 日志取证（0.5.0）：goBack 后 0.3/0.9/1.8s 检查 scrollEnabled 与 pan 全部是 YES，
// 一条「复位」都没打 → 不是原生被禁用，而是页面 JS 残留滚动锁（元宝搜索是 SPA，
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

static NSString *SPEHBackTouchJS(void)
{
	static NSString *js = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		js = @"(function(){try{var d=document,de=d.documentElement,b=d.body,n=0,u=0;"
			 "function fix(e){if(!e)return;var cs=getComputedStyle(e);"
			 "if(cs.overflow==='hidden'){e.style.overflow='';n++;}"
			 "if(cs.touchAction==='none'){e.style.touchAction='';n++;}"
			 "if(cs.webkitOverflowScrolling==='auto'){}"
			 "}"
			 "fix(de);fix(b);"
			 "var kids=d.querySelectorAll('body > div, body > section');"
			 "for(var i=0;i<kids.length&&i<80;i++){var e=kids[i];var cs=getComputedStyle(e);"
			 "if(cs.position!=='fixed')continue;"
			 "var h=parseFloat(cs.height)||0,w=parseFloat(cs.width)||0;"
			 "if(h>=window.innerHeight*0.9&&w>=window.innerWidth*0.9&&parseFloat(cs.opacity)<0.2)"
			 "{e.style.display='none';u++;}}"
			 "try{window.scrollBy(0,1);window.scrollBy(0,-1);}catch(e2){}"
			 "return 'unlock='+n+' covered='+u;}catch(err){return 'ERR';}})()";
	});
	return js;
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

static void SPEHApplyBackTouchJS(id webView, NSString *tag)
{
	if (!webView || !SPEHBackScrollFixEnabled()) return;
	@try {
		[(id<SPEHWebViewJS>)webView evaluateJavaScript:SPEHBackTouchJS()
			completionHandler:^(id result, NSError *error) {
				if (error) return;
				NSString *r = [result isKindOfClass:[NSString class]] ? (NSString *)result : nil;
				if (!r || [r isEqualToString:@"unlock=0 covered=0"]) return;
				SPEHLog(@"[backscroll] %@ 页面滚动锁复位 %@", tag, r);
			}];
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
	NSArray *jsDelays = @[ @0.35, @1.10 ];
	for (NSNumber *d in delays) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			SPEHResetScroll(weakSelf, [NSString stringWithFormat:@"goBack+%@s", d]);
		});
	}
	for (NSNumber *d in jsDelays) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			SPEHApplyBackTouchJS(weakSelf, [NSString stringWithFormat:@"goBack+%@s", d]);
		});
	}
	if (SPEHProbeEnabled()) SPEHLog(@"[backnav] goBack 打开 2.5s 后退窗口（吞 reload + 复位滚动锁）");
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
	SPEHLog(@"[urlswipe] hook addGestureRecognizer=%s", gOrigAddGesture ? "ok" : "FAILED");
}

// MARK: - 入口

%ctor
{
	@autoreleasepool {
		if (!SPEHEnabled()) return;

		SPEHLog(@"==============================================");
		SPEHLog(@"Safari16Enhance " SPEH_VERSION " loaded, pid=%d", getpid());
		SPEHLog(@"log file = %@", SPEHLogPath());
		SPEHLog(@"engine=%d(%@) dialog=%d reader=%d openinapp=%d backscroll=%d appstore=%d probe=%d",
				SPEHEngineEnabled(), SPEHEngineName(), SPEHDialogKillEnabled(), SPEHReaderKillEnabled(),
				SPEHOpenInAppKillEnabled(), SPEHBackScrollFixEnabled(), SPEHAppStoreKillEnabled(), SPEHProbeEnabled());

		SPEHInstallSFDialogHooks();
		SPEHInstallReaderHooks();
		SPEHInstallOpenInAppHooks();
		SPEHInstallBackScrollHooks();
		SPEHInstallAppStoreHooks();
		SPEHInstallURLBarSwipeHooks();
		SPEHScheduleSearchEngineHookInstall();
	}
}
