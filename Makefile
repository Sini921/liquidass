# build for a real device then: make package ARCHS="arm64 arm64e" TARGET="iphone:clang:latest:14.0" FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless/rootful/roothide

export TARGET := simulator:clang:latest:14.0
export ARCHS := x86_64
export GO_EASY_ON_ME=1

include $(THEOS)/makefiles/common.mk
include ./locatesim.mk

TWEAK_NAME = liquidass
liquidass_FILES = Tweak.x Hooks/FolderIcon.x Hooks/AppIcons.x Hooks/ContextMenu.x Hooks/Dock.x Hooks/FolderOpen.x Hooks/Lockscreen/Common.x Hooks/Lockscreen/Notifications.x Hooks/Lockscreen/QuickActions.x Hooks/AppLibrary.x Hooks/Widgets.x
liquidass_CFLAGS = -fobjc-arc
liquidass_FRAMEWORKS = UIKit MetalKit

include $(THEOS)/makefiles/tweak.mk
SUBPROJECTS += LiquidAssPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk

.PHONY: sim remove

sim:: all
	@rm -f /opt/simject/$(TWEAK_NAME).dylib
	@cp -v .theos/obj/iphone_simulator/debug/$(TWEAK_NAME).dylib /opt/simject
	@cp -v $(PWD)/$(TWEAK_NAME).plist /opt/simject
	@mkdir -p /opt/simject/PreferenceLoader/Preferences
	@mkdir -p /opt/simject/PreferenceBundles
	@rm -rf /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle
	@cp -vR .theos/obj/iphone_simulator/debug/LiquidAssPrefs.bundle /opt/simject/PreferenceBundles/
	@APP_NAME=$$(sed -n 's/^"prefs.app_name" = "\(.*\)";/\1/p' $(PWD)/LiquidAssPrefs/Resources/Localizable.strings | head -n 1); \
	cp -v $(PWD)/LiquidAssPrefs/Resources/entry.plist /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist; \
	/usr/libexec/PlistBuddy -c "Set :entry:label $$APP_NAME" /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist; \
	/usr/libexec/PlistBuddy -c "Set :entry:label $$APP_NAME" /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle/entry.plist

before-package::
	@APP_NAME=$$(sed -n 's/^"prefs.app_name" = "\(.*\)";/\1/p' $(PWD)/LiquidAssPrefs/Resources/Localizable.strings | head -n 1); \
	if [ -f "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/LiquidAssPrefs.plist" ]; then \
		/usr/libexec/PlistBuddy -c "Set :entry:label $$APP_NAME" "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/LiquidAssPrefs.plist"; \
	fi; \
	if [ -f "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LiquidAssPrefs.bundle/entry.plist" ]; then \
		/usr/libexec/PlistBuddy -c "Set :entry:label $$APP_NAME" "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/LiquidAssPrefs.bundle/entry.plist"; \
	fi

remove::
	@rm -f /opt/simject/$(TWEAK_NAME).dylib /opt/simject/$(TWEAK_NAME).plist
	@[ ! -d /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle ] || rm -rf /opt/simject/PreferenceBundles/LiquidAssPrefs.bundle
	@[ ! -f /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist ] || rm -f /opt/simject/PreferenceLoader/Preferences/LiquidAssPrefs.plist
