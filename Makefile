export THEOS_PACKAGE_SCHEME = roothide

TARGET := iphone:clang:16.5:15.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Safari16Enhance

Safari16Enhance_FILES = Tweak.xm
Safari16Enhance_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-but-set-variable
# SPEH_NO_LOG=1 make package —— 编译期彻底剥离日志（无队列、无文件、无日志字符串）
ifneq ($(SPEH_NO_LOG),)
Safari16Enhance_CFLAGS += -DSPEH_NO_LOG
endif
Safari16Enhance_FRAMEWORKS = UIKit Foundation WebKit

include $(THEOS_MAKE_PATH)/tweak.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp prefs/Safari16Enhance.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/Safari16Enhance.plist$(ECHO_END)

after-install::
	install.exec "killall -9 MobileSafari || true"
