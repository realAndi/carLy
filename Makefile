TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
THEOS_PACKAGE_SCHEME := rootless
INSTALL_TARGET_PROCESSES := CarPlayTemplateUIHost Music Spotify

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := carLy
carLy_FILES := $(shell find Tweak -name '*.m' -o -name '*.x' | sort)
carLy_CFLAGS := -fobjc-arc -Wall -Werror -Wno-unused-function -ITweak -ITweak/Private -DCL_VERSION=\"$(THEOS_PACKAGE_BASE_VERSION)\"
carLy_FRAMEWORKS := UIKit CoreGraphics
carLy_LIBRARIES := sqlite3

SUBPROJECTS := Prefs

include $(THEOS)/makefiles/tweak.mk
include $(THEOS)/makefiles/aggregate.mk
