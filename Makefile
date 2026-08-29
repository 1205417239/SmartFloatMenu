ARCHS = arm64
TARGET = iphone:clang:latest:14.0
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SmartFloatMenu

SmartFloatMenu_FILES = Tweak.xm
SmartFloatMenu_CFLAGS = -fobjc-arc
SmartFloatMenu_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
