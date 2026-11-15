# Safari16Enhance

iOS 16 Safari 双功能增强，roothide 单变体。**独立实现**，不基于 SafariPlus，也不含 SafariX 的任何代码（SafariX 为 0xkuj 的付费闭源插件）。

## 功能

| 功能 | 说明 |
|---|---|
| 拦截「打不开该网页」弹窗 | 按文本精准命中 Safari 自绘的 `SFDialogView` 并拆除，改底部 toast，不再强制点「好」 |
| 拦截顶部 Smart App Banner | 精准 hook `TabDocument`（`setAppBanner:` / `appBanner` / `didFindAppBannerWithContent:` / `setAppSuggestionBanner:isPinned:` / `setStoreBannersAreDisabled:`）与 `BrowserController`（检查完成 / 钉顶 / 移除）共 8 个方法，只按 SEL 判存在，**不做类名通扫** |
| 移除「App 内打开」浮层 | JS 清网页自绘浮层 + MutationObserver 见 `apple-itunes-app` meta 就删 + 捕获阶段拦非 http(s) scheme 点击；`TabDocument -webView:didFinishNavigation:` 每次加载完成补注入 |
| 不弹「打开 App / 继续」卡片 | 让 Safari 拿不到 `WBSAppLink`（hook `WBSAppLink` / `LSAppLink` 共 5 条），微软必应那类「APP 打开 / 浏览器 继续」不再出现 |
| 关闭「阅读器可用」提示 | 白名单精准命中已实测确认的可用性判定，压成 NO |
| 禁用地址栏左右滑动切页 | 掐掉底部胶囊标签栏的横向滚动与 pan，防误触 |
| 运行时探针（默认关闭） | 关闭时日志只记录真正发生的拦截事件；打开后额外输出注入时机、手势类名、AppLink 每次查询等诊断 |

**明确不做的两件事**（都踩过坑）：

1. 不修改已创建 `WKWebView` 的 `configuration` / `userContentController` / `processPool` —— 会导致第三方 Safari 扩展（Userscripts、Dark Night 等）脚本注入失效、权限反复弹窗。
2. 不 hook WebKit 导航决策并手工回调 `decisionHandler` —— 真机 5 份 IPS 证实会造成 PAC 失效 SIGSEGV 闪退。

## 日志位置（重要）

注入 App 的插件不能写 `/var/mobile/Library/Logs`，**必须写 Safari 自身容器**：

```
<MobileSafari 数据容器>/Documents/Safari16Enhance.log
```

启动时日志首几行会打印实际 `NSHomeDirectory()` 与日志绝对路径。落地逻辑：

1. 优先 `NSHomeDirectory()/Documents`
2. 兜底 `NSSearchPathForDirectoriesInDomains(NSDocumentDirectory …)`
3. 再兜底 `Library/Caches`、`tmp`
4. 每个候选目录都会**真实写一个测试文件做写入校验**，通过才用
5. 目录设 `NSFileProtectionCompleteUntilFirstUserAuthentication`（锁屏后仍可写）、排除 iCloud 备份
6. 日志超 2MB 自动轮转为 `.1`

拖日志：

```bash
# 先找容器目录
ssh root@<device> "find /rootfs/private/var/mobile/Containers/Data/Application -maxdepth 3 -name 'Safari16Enhance.log'"
# 再拉
scp root@<device>:/rootfs/private/var/mobile/Containers/Data/Application/<UUID>/Documents/Safari16Enhance.log .
```

## 设置

设置 → Safari 16 增强：总开关 / 弹窗拦截 / App 内打开浮层 / Smart App Banner / 打开 App 卡片 / 阅读器 / 地址栏手势 / 探针。

## 构建

GitHub Actions（`roothide/theos` + iPhoneOS16.5.sdk + roothide scheme），仅出 roothide deb。
