export THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

# 一个工程两个 tweak 目标（一个 deb 装两个 dylib，各带自己的 Filter，互不干扰）：
#   Safari16Enhance.dylib → MobileSafari（弹窗/浮层/地址栏）
#   ChatSwipe.dylib       → 微信 / QQ / Telegram / 抖音（输入框左滑清空、右滑粘贴、键盘三按钮）
TWEAK_NAME = Safari16Enhance ChatSwipe

Safari16Enhance_FILES = Tweak.xm
Safari16Enhance_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-but-set-variable
Safari16Enhance_FRAMEWORKS = UIKit Foundation

ChatSwipe_FILES = ChatSwipe.xm
ChatSwipe_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable -Wno-unused-but-set-variable
ChatSwipe_FRAMEWORKS = UIKit Foundation

# SPEH_NO_LOG=1 make package —— 编译期彻底剥离日志（无队列、无文件、无日志字符串），两个 tweak 同时生效
ifneq ($(SPEH_NO_LOG),)
Safari16Enhance_CFLAGS += -DSPEH_NO_LOG
ChatSwipe_CFLAGS += -DSPEH_NO_LOG
endif

include $(THEOS_MAKE_PATH)/tweak.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp prefs/Safari16Enhance.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/Safari16Enhance.plist$(ECHO_END)

after-install::
	install.exec "killall -9 MobileSafari || true"
