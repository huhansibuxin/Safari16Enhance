// Safari16Enhance - iOS 16 Safari 双功能增强
//
// 功能：
//   1. 自定义搜索引擎注入（默认元宝搜索 so.qq.com），并强制作为默认引擎
//   2. 抑制「Safari 打不开该网页」强制弹窗，降级为底部 toast 轻提示
//   3. 运行时探针：dump 搜索引擎相关类/方法、记录所有被 present 的 Alert 与 alert 级 window
//
// 设计原则：
//   - 所有 hook 前先做类/方法存在性检查，不存在则静默跳过并记日志，绝不崩溃
//   - 探针在后台队列执行，不阻塞主线程、不常驻轮询
//   - 日志强制写入 Safari 自身沙盒容器 Documents（注入 App 的插件只能在此处落盘），
//     多级路径兜底 + 真实写入校验，绝不出现「装了但看不到日志」
//   - 单个功能可通过 preference plist 独立开关

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

#define SPEH_PREF_DOMAIN @"com.huhansibuxin.safari16enhance"
#define SPEH_LOG_NAME    @"Safari16Enhance.log"

// MARK: - 日志（写入 Safari 容器 Documents）

// 确保目录存在，并设置：可被 root 读取、不进 iCloud 备份、锁屏后仍可写
static BOOL SPEHPrepareDirectory(NSString *dir)
{
	if (dir.length == 0) return NO;

	NSFileManager *fm = [NSFileManager defaultManager];
	BOOL isDir = NO;
	if (![fm fileExistsAtPath:dir isDirectory:&isDir]) {
		NSDictionary *attrs = @{
			NSFileProtectionKey : NSFileProtectionCompleteUntilFirstUserAuthentication,
		};
		if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:attrs error:nil]) {
			return NO;
		}
	} else if (!isDir) {
		return NO;
	}

	// 目录级：锁定后仍可写 + 不进备份
	[fm setAttributes:@{ NSFileProtectionKey : NSFileProtectionCompleteUntilFirstUserAuthentication }
			 ofItemAtPath:dir error:nil];
	[[NSURL fileURLWithPath:dir] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];

	// 真实写入校验：只判断目录存在不算数，必须能落一个字节
	NSString *probe = [dir stringByAppendingPathComponent:@".speh_write_test"];
	BOOL ok = [[NSData data] writeToFile:probe atomically:NO] || [[@"1" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:probe atomically:NO];
	if (ok) [fm removeItemAtPath:probe error:nil];
	return ok;
}

// 解析日志目录：优先 Safari 容器 Documents，多级兜底
static NSString *SPEHLogDirectory(void)
{
	static NSString *dir = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSMutableArray *candidates = [NSMutableArray array];

		// ① 注入 App 后的 NSHomeDirectory() 就是 Safari 的数据容器根
		NSString *home = NSHomeDirectory();
		if (home.length) {
			[candidates addObject:[home stringByAppendingPathComponent:@"Documents"]];
		}
		// ② 沙盒目录 API（正常情况下与①同值，防①被越狱环境改写）
		NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		if (docs.count) [candidates addObject:docs.firstObject];
		// ③ 容器内 Library/Caches
		if (home.length) [candidates addObject:[home stringByAppendingPathComponent:@"Library/Caches"]];
		// ④ 容器 tmp（最后兜底，保证有日志可看）
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

		// 限流：每 200 条检查一次，超过 2MB 轮转，避免日志吃满容器（探针会写很多行）
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
	CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(SPEH_PREF_DOMAIN));
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
	CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(SPEH_PREF_DOMAIN));
	if (!v) return def;
	NSString *r = def;
	if (CFGetTypeID(v) == CFStringGetTypeID()) r = [(__bridge NSString *)v copy];
	CFRelease(v);
	return r;
}

// 默认搜索引擎模板：元宝搜索
static NSString *const SPEHDefaultEngineName = @"元宝搜索";
static NSString *const SPEHDefaultEngineURL  = @"https://so.qq.com/isearch?query={searchTerms}";

static BOOL SPEHEnabled(void)              { return SPEHBoolPref(@"enabled", YES); }
static BOOL SPEHEngineEnabled(void)        { return SPEHBoolPref(@"customEngineEnabled", YES); }
static BOOL SPEHAlertSuppressEnabled(void) { return SPEHBoolPref(@"suppressErrorAlert", YES); }
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

// 轻量 toast：不新建 window、不抢 key window，仅临时加一层 label
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

static void SPEHPatchInstanceMethod(Class cls, SEL sel, IMP newImp, IMP *outOld)
{
	if (!cls) { SPEHLog(@"[hook] class nil for %@", NSStringFromSelector(sel)); return; }
	Method m = class_getInstanceMethod(cls, sel);
	if (!m) { SPEHLog(@"[hook] missing -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel)); return; }
	MSHookMessageEx(cls, sel, newImp, outOld);
	SPEHLog(@"[hook] ok -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
}

// MARK: - 探针

static void SPEHDumpMethodList(Class cls, NSUInteger limit)
{
	if (!cls) return;
	unsigned int count = 0;
	Method *methods = class_copyMethodList(cls, &count);
	SPEHLog(@"[probe] class %@ (%u methods)", NSStringFromClass(cls), count);
	for (unsigned int i = 0; i < count && i < limit; i++) {
		SPEHLog(@"[probe]    - %@  types=%s", NSStringFromSelector(method_getName(methods[i])), method_getTypeEncoding(methods[i]));
	}
	free(methods);
}

// 在后台队列扫描一遍所有类名，找出包含关键字的类并 dump
static void SPEHProbeScanClasses(void)
{
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
		NSArray *needles = @[ @"SearchEngine", @"SearchProvider", @"StartPage" ];
		unsigned int count = 0;
		Class *classes = objc_copyClassList(&count);
		NSMutableDictionary *hits = [NSMutableDictionary dictionary];

		for (unsigned int i = 0; i < count; i++) {
			const char *name = class_getName(classes[i]);
			if (!name) continue;
			NSString *className = [NSString stringWithUTF8String:name];
			if (!className) continue;
			for (NSString *needle in needles) {
				if ([className rangeOfString:needle].location != NSNotFound) {
					hits[className] = needle;
					break;
				}
			}
		}
		free(classes);

		SPEHLog(@"[probe] ===== search-engine related classes: %lu =====", (unsigned long)hits.count);
		for (NSString *className in [hits.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
			Class cls = NSClassFromString(className);
			SPEHLog(@"[probe] %@%@", className, cls ? @"" : @" (not resolvable)");
			if (cls) SPEHDumpMethodList(cls, 40);
		}
		SPEHLog(@"[probe] ===== end =====");
	});
}

// MARK: - 搜索引擎注入

// 仅用于向编译器声明初始化签名，真实实现由 Safari 私有类在运行时提供
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
	if (!infoCls) {
		SPEHLog(@"[engine] SearchEngineInfo 类不存在，无法构造引擎");
		return nil;
	}

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
		// 用协议声明让 ARC 正确识别 init 族的所有权语义（+1 返回）
		engine = [(id<SPEHEngineInfoInit>)[infoCls alloc] initWithDictionary:dict usingContext:controller];
	} else if ([infoCls respondsToSelector:legacySel]) {
		typedef id (*LegacyFn)(id, SEL, id, id);
		engine = ((LegacyFn)objc_msgSend)(infoCls, legacySel, dict, controller);
	}

	SPEHLog(@"[engine] built engine=%@ name=%@ url=%@", engine, SPEHEngineName(), urlTemplate);
	return engine;
}

static void SPEHPopulateSearchEnginesHook(id self, SEL _cmd)
{
	if (gOrigPopulateSearchEngines) {
		((void (*)(id, SEL))gOrigPopulateSearchEngines)(self, _cmd);
	}

	if (!SPEHEngineEnabled()) return;

	if (!gCustomSearchEngine) {
		gCustomSearchEngine = SPEHCreateCustomSearchEngine(self);
	}
	if (!gCustomSearchEngine) return;

	// 兼容两种存储方式：KVC 取 _searchEngines / engines
	@try {
		id engines = nil;
		@try { engines = [self valueForKey:@"_searchEngines"]; } @catch (NSException *e) { }
		if (!engines) {
			@try { engines = [self valueForKey:@"engines"]; } @catch (NSException *e) { }
		}

		if ([engines isKindOfClass:[NSMutableArray class]]) {
			NSMutableArray *arr = (NSMutableArray *)engines;
			BOOL exists = NO;
			for (id e in arr) {
				if (e == gCustomSearchEngine) { exists = YES; break; }
			}
			if (!exists) {
				[arr addObject:gCustomSearchEngine];
				SPEHLog(@"[engine] appended to mutable array, total=%lu", (unsigned long)arr.count);
			}
		} else if ([engines isKindOfClass:[NSArray class]]) {
			NSArray *arr = (NSArray *)engines;
			if (![arr containsObject:gCustomSearchEngine]) {
				NSArray *newArr = [arr arrayByAddingObject:gCustomSearchEngine];
				@try { [self setValue:newArr forKey:@"_searchEngines"]; } @catch (NSException *e) { }
				@try { [self setValue:newArr forKey:@"engines"]; } @catch (NSException *e) { }
				SPEHLog(@"[engine] replaced immutable array, total=%lu", (unsigned long)newArr.count);
			}
		} else {
			SPEHLog(@"[engine] 未找到引擎数组，engines=%@", engines);
		}
	} @catch (NSException *e) {
		SPEHLog(@"[engine] populate exception: %@", e);
	}
}

static id SPEHDefaultSearchEngineHook(id self, SEL _cmd)
{
	if (SPEHEngineEnabled() && gCustomSearchEngine) {
		return gCustomSearchEngine;
	}
	if (gOrigDefaultSearchEngine) {
		return ((id (*)(id, SEL))gOrigDefaultSearchEngine)(self, _cmd);
	}
	return nil;
}

static id SPEHDefaultSearchEngineIfPopulatedHook(id self, SEL _cmd)
{
	if (SPEHEngineEnabled() && gCustomSearchEngine) {
		return gCustomSearchEngine;
	}
	if (gOrigDefaultSearchEngineIfPopulated) {
		return ((id (*)(id, SEL))gOrigDefaultSearchEngineIfPopulated)(self, _cmd);
	}
	return nil;
}

static void SPEHInstallSearchEngineHooks(void)
{
	gSearchEngineControllerClass = NSClassFromString(@"SearchEngineController") ?: NSClassFromString(@"_SFSearchEngineController");
	gSearchEngineInfoClass = NSClassFromString(@"SearchEngineInfo") ?: NSClassFromString(@"_SFSearchEngineInfo");

	if (!gSearchEngineControllerClass) {
		SPEHLog(@"[engine] SearchEngineController 未加载，重试第 %d 次", gEngineRetryCount);
		return;
	}

	SPEHLog(@"[engine] controller=%@ info=%@", NSStringFromClass(gSearchEngineControllerClass), NSStringFromClass(gSearchEngineInfoClass));

	// populate 方法名在不同版本可能不同，逐个尝试
	NSArray *populateNames = @[ @"_populateSearchEngines", @"populateSearchEngines", @"_updateSearchEngines" ];
	BOOL hookedPopulate = NO;
	for (NSString *name in populateNames) {
		SEL sel = NSSelectorFromString(name);
		if (class_getInstanceMethod(gSearchEngineControllerClass, sel)) {
			SPEHPatchInstanceMethod(gSearchEngineControllerClass, sel, (IMP)SPEHPopulateSearchEnginesHook, &gOrigPopulateSearchEngines);
			hookedPopulate = YES;
			break;
		}
	}
	if (!hookedPopulate) {
		SPEHLog(@"[engine] 未找到 populate 方法，dump 方法列表：");
		SPEHDumpMethodList(gSearchEngineControllerClass, 80);
	}

	SPEHPatchInstanceMethod(gSearchEngineControllerClass, @selector(defaultSearchEngine), (IMP)SPEHDefaultSearchEngineHook, &gOrigDefaultSearchEngine);
	SPEHPatchInstanceMethod(gSearchEngineControllerClass, @selector(defaultSearchEngineIfPopulated), (IMP)SPEHDefaultSearchEngineIfPopulatedHook, &gOrigDefaultSearchEngineIfPopulated);

	gEngineHooked = YES;
}

// Safari 启动时 SafariServices 可能尚未加载，做有限次重试
static void SPEHScheduleSearchEngineHookInstall(void)
{
	if (gEngineHooked) return;
	if (gEngineRetryCount >= 12) {
		SPEHLog(@"[engine] 重试上限已到，放弃安装搜索引擎 hook");
		return;
	}
	gEngineRetryCount++;

	SPEHInstallSearchEngineHooks();
	if (!gEngineHooked) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			SPEHScheduleSearchEngineHookInstall();
		});
	}
}

// MARK: - 弹窗抑制

static IMP gOrigPresentViewController = NULL;

static BOOL SPEHIsTargetErrorAlert(UIAlertController *alert)
{
	NSString *title = alert.title ?: @"";
	NSString *message = alert.message ?: @"";
	NSString *combined = [title stringByAppendingString:message];

	NSArray *keywords = @[
		@"打不开该网页", @"打不开这个网页", @"无法打开该网页", @"无法打开这个网页",
		@"打不开网页", @"网址无效", @"地址无效",
		@"cannot open the page", @"can't open the page", @"cannot be opened",
		@"address is invalid", @"the URL is invalid"
	];

	for (NSString *kw in keywords) {
		if ([combined rangeOfString:kw options:NSCaseInsensitiveSearch].location != NSNotFound) {
			return YES;
		}
	}
	return NO;
}

static void SPEHPresentViewControllerHook(UIViewController *self, SEL _cmd, UIViewController *vc, BOOL animated, void (^completion)(void))
{
	if (SPEHAlertSuppressEnabled() && [vc isKindOfClass:[UIAlertController class]]) {
		UIAlertController *alert = (UIAlertController *)vc;
		SPEHLog(@"[alert] present by <%@> title=%@ message=%@", NSStringFromClass([self class]), alert.title, alert.message);

		if (SPEHIsTargetErrorAlert(alert)) {
			SPEHLog(@"[alert] SUPPRESSED: %@", alert.title);
			NSString *toast = alert.title.length ? alert.title : @"网页无法打开";
			if (alert.message.length && alert.message.length <= 24) {
				toast = [toast stringByAppendingFormat:@" · %@", alert.message];
			}
			SPEHShowToast(toast);
			if (completion) completion();
			return;
		}
	}

	if (gOrigPresentViewController) {
		((void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))gOrigPresentViewController)(self, _cmd, vc, animated, completion);
	}
}

static void SPEHInstallAlertHooks(void)
{
	SPEHPatchInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:), (IMP)SPEHPresentViewControllerHook, &gOrigPresentViewController);

	// 探针：记录所有进入 alert 级别的 window，用于确认弹窗真实呈现路径
	[[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification
													  object:nil
													   queue:[NSOperationQueue mainQueue]
												  usingBlock:^(NSNotification *note) {
		UIWindow *w = note.object;
		if ([w isKindOfClass:[UIWindow class]] && w.windowLevel >= UIWindowLevelAlert) {
			SPEHLog(@"[probe] alert-level window visible: %@ level=%.0f class=%@", w, w.windowLevel, NSStringFromClass([w class]));
		}
	}];
}

// MARK: - 入口

%ctor
{
	@autoreleasepool {
		if (!SPEHEnabled()) return;

		SPEHLog(@"==============================================");
		SPEHLog(@"Safari16Enhance 0.1.0 loaded, pid=%d", getpid());
		SPEHLog(@"container home = %@", NSHomeDirectory());
		SPEHLog(@"log file        = %@", SPEHLogPath());
		SPEHLog(@"engine enabled=%d name=%@ url=%@", SPEHEngineEnabled(), SPEHEngineName(), SPEHEngineURL());
		SPEHLog(@"alert suppress=%d probe=%d", SPEHAlertSuppressEnabled(), SPEHProbeEnabled());

		SPEHInstallAlertHooks();

		if (SPEHProbeEnabled()) {
			// 延后扫描，避免和 Safari 启动争抢 CPU
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				SPEHProbeScanClasses();
			});
		}

		SPEHScheduleSearchEngineHookInstall();
	}
}
