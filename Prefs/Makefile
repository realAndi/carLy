include $(THEOS)/makefiles/common.mk

BUNDLE_NAME := carLyPrefs
carLyPrefs_FILES := $(wildcard *.m)
carLyPrefs_INSTALL_PATH := /Library/PreferenceBundles
# -I../Tweak: only for two header-only files shared with the tweak — Tweak/Util/CLPrefsKeys.h
# (pure #define key/domain/Darwin notification constants) and Tweak/UI/CLLayoutGeometry.h (the
# layout arithmetic the preview draws with). Nothing here links against any Tweak/*.m
# implementation file or includes any other Tweak header.
carLyPrefs_CFLAGS := -fobjc-arc -Wall -Werror -I../Tweak
carLyPrefs_FRAMEWORKS := UIKit UniformTypeIdentifiers
# The SDK ships no stub for the private Preferences.framework; resolve its symbols at load time.
carLyPrefs_LDFLAGS := -Wl,-undefined,dynamic_lookup

include $(THEOS)/makefiles/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/carLyPrefs.plist$(ECHO_END)
