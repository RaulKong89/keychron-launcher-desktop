ARCHS = armv7
TARGET = iphone:clang:6.1:6.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = LyricalizerLRCLIB
LyricalizerLRCLIB_FILES = Tweak.xm LRHTTPS.m
LyricalizerLRCLIB_FRAMEWORKS = Foundation UIKit MediaPlayer
LyricalizerLRCLIB_CFLAGS = -Wno-deprecated-declarations -I$(THEOS_PROJECT_DIR)/vendor/mbedtls/include
LyricalizerLRCLIB_LDFLAGS = \
	$(THEOS_PROJECT_DIR)/vendor/mbedtls/lib/libmbedtls.a \
	$(THEOS_PROJECT_DIR)/vendor/mbedtls/lib/libmbedx509.a \
	$(THEOS_PROJECT_DIR)/vendor/mbedtls/lib/libmbedcrypto.a

include $(THEOS_MAKE_PATH)/tweak.mk
