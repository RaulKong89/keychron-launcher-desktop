ARCHS = armv7
TARGET = iphone:clang:9.3:6.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BottomMicRedirect
BottomMicRedirect_FILES = Tweak.xm
BottomMicRedirect_FRAMEWORKS = AudioToolbox
BottomMicRedirect_LIBRARIES = substrate
BottomMicRedirect_CFLAGS = -Wall -Wextra

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
