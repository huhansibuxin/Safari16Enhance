# Safari16Enhance

iOS 16 Safari 双功能增强，roothide 单变体。**独立实现**，不基于 SafariPlus，也不含 SafariX 的任何代码（SafariX 为 0xkuj 的付费闭源插件）。

## 功能

| 功能 | 说明 |
|---|---|
| 自定义默认搜索引擎 | 注入自建 `SearchEngineInfo`，并强制 `defaultSearchEngine` 返回它。默认 **元宝搜索** `https://so.qq.com/isearch?query={searchTerms}`（免登录可用） |
| 拦截「打不开该网页」弹窗 | hook `-[UIViewController presentViewController:animated:completion:]`，命中错误文案即丢弃，改底部 toast，不再强制点「好」 |
| 运行时探针（可关） | dump 搜索引擎相关类/方法、记录每次弹窗的文案与发起类，用于 iOS 版本适配 |

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

设置 → Safari 16 增强：总开关 / 搜索引擎开关 / 名称 / URL 模板 / 弹窗拦截 / 探针。

## 构建

GitHub Actions（`roothide/theos` + iPhoneOS16.5.sdk + roothide scheme），仅出 roothide deb。
