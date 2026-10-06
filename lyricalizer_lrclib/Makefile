ARCHS = armv7
TARGET = iphone:clang:9.3:6.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LyricalizerLRCLIB
LyricalizerLRCLIB_FILES = Tweak.xm
LyricalizerLRCLIB_FRAMEWORKS = Foundation UIKit MediaPlayer
LyricalizerLRCLIB_CFLAGS = -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
