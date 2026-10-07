ARCHS = armv7
TARGET = iphone:clang:6.1:6.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LyricalizerLRCLIB
LyricalizerLRCLIB_FILES = Tweak.xm LRHTTPS.m
LyricalizerLRCLIB_FRAMEWORKS = Foundation UIKit MediaPlayer
LyricalizerLRCLIB_CFLAGS = -Wno-deprecated-declarations -I$(THEOS_PROJECT_DIR)/vendor/mbedtls/include
LyricalizerLRCLIB_LDFLAGS = $(wildcard $(THEOS_PROJECT_DIR)/vendor/mbedtls/obj/*.o)

include $(THEOS_MAKE_PATH)/tweak.mk
