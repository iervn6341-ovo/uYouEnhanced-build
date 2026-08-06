SDK_VERSION ?= 17.5
HOST_DEPLOYMENT_VERSION ?= 17.5
export TARGET = iphone:clang:$(SDK_VERSION):$(HOST_DEPLOYMENT_VERSION)
export ARCHS = arm64

export libcolorpicker_ARCHS = arm64
export libFLEX_ARCHS = arm64
export Alderis_XCODEOPTS = LD_DYLIB_INSTALL_NAME=@rpath/Alderis.framework/Alderis
export Alderis_XCODEFLAGS = DYLIB_INSTALL_NAME_BASE=/Library/Frameworks BUILD_LIBRARY_FOR_DISTRIBUTION=YES ARCHS="$(ARCHS)" IPHONEOS_DEPLOYMENT_TARGET="$(HOST_DEPLOYMENT_VERSION)"
export libcolorpicker_LDFLAGS = -F$(TARGET_PRIVATE_FRAMEWORK_PATH) -install_name @rpath/libcolorpicker.dylib
export ADDITIONAL_CFLAGS = -I$(THEOS_PROJECT_DIR)/Tweaks/RemoteLog -I$(THEOS_PROJECT_DIR)/Tweaks

ifneq ($(JAILBROKEN),1)
export DEBUGFLAG = -ggdb -Wno-unused-command-line-argument -L$(THEOS_OBJ_DIR) -F$(_THEOS_LOCAL_DATA_DIR)/$(THEOS_OBJ_DIR_NAME)/install/Library/Frameworks
MODULES = jailed
endif

ifndef YOUTUBE_VERSION
YOUTUBE_VERSION = 20.44.2
endif
ifndef UYOU_VERSION
UYOU_VERSION = 3.0.4
endif
PACKAGE_NAME = $(TWEAK_NAME)
PACKAGE_VERSION = $(YOUTUBE_VERSION)-$(UYOU_VERSION)

INSTALL_TARGET_PROCESSES = YouTube
TWEAK_NAME = uYouEnhanced
DISPLAY_NAME = YouTube
BUNDLE_ID = com.google.ios.youtube

$(TWEAK_NAME)_FILES := $(wildcard Sources/*.xm) $(wildcard Sources/*.x) $(wildcard Sources/*.m)
$(TWEAK_NAME)_FRAMEWORKS = UIKit Foundation AVFoundation AVKit Photos Accelerate CoreMotion GameController VideoToolbox Security
$(TWEAK_NAME)_LIBRARIES = bz2 c++ iconv z
$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-but-set-variable -DTWEAK_VERSION=\"$(PACKAGE_VERSION)\"
$(TWEAK_NAME)_INJECT_DYLIBS = \
    Tweaks/uYou/Library/MobileSubstrate/DynamicLibraries/uYou.dylib \
    $(THEOS_OBJ_DIR)/libFLEX.dylib \
    $(THEOS_OBJ_DIR)/iSponsorBlock.dylib \
    $(THEOS_OBJ_DIR)/YTABConfig.dylib \
    $(THEOS_OBJ_DIR)/YTIcons.dylib \
    $(THEOS_OBJ_DIR)/YouGroupSettings.dylib \
    $(THEOS_OBJ_DIR)/CaptionIsland.dylib \
    $(THEOS_OBJ_DIR)/YouLoop.dylib \
    $(THEOS_OBJ_DIR)/YouMute.dylib \
    $(THEOS_OBJ_DIR)/YouPiP.dylib \
    $(THEOS_OBJ_DIR)/YouQuality.dylib \
    $(THEOS_OBJ_DIR)/YouSlider.dylib \
    $(THEOS_OBJ_DIR)/YouSpeed.dylib \
    $(THEOS_OBJ_DIR)/YouTimeStamp.dylib \
    $(THEOS_OBJ_DIR)/YouTubeDislikesReturn.dylib \
    $(THEOS_OBJ_DIR)/DontEatMyContent.dylib \
    $(THEOS_OBJ_DIR)/YTHoldForSpeed.dylib \
    $(THEOS_OBJ_DIR)/YTUHD.dylib \
    $(THEOS_OBJ_DIR)/YTVideoOverlay.dylib \
    $(THEOS_OBJ_DIR)/YTweaks.dylib

$(TWEAK_NAME)_EMBED_LIBRARIES = $(THEOS_OBJ_DIR)/libcolorpicker.dylib
$(TWEAK_NAME)_EMBED_FRAMEWORKS = $(_THEOS_LOCAL_DATA_DIR)/$(THEOS_OBJ_DIR_NAME)/install_Alderis.xcarchive/Products/var/jb/Library/Frameworks/Alderis.framework
CAPTION_ISLAND_WIDGET_APPEX = $(_THEOS_LOCAL_DATA_DIR)/obj/CaptionIslandWidget/CaptionIslandWidget.appex
CAPTION_ISLAND_CONTINUED_TASK_ID = $(BUNDLE_ID).captionisland.background-captions.*
GENERATED_EXTENSIONS_DIR = $(_THEOS_LOCAL_DATA_DIR)/generated-extensions
INCLUDE_OPENYOUTUBE ?= 0
STATIC_EXTENSION_NAMES := $(notdir $(wildcard Extensions/*.appex))
ifneq ($(INCLUDE_OPENYOUTUBE),1)
STATIC_EXTENSION_NAMES := $(filter-out OpenYoutubeSafariExtension.appex,$(STATIC_EXTENSION_NAMES))
endif
GENERATED_EXTENSION_APPEXS = $(addprefix $(GENERATED_EXTENSIONS_DIR)/,$(STATIC_EXTENSION_NAMES))
$(TWEAK_NAME)_EMBED_BUNDLES = $(wildcard Bundles/*.bundle) $(wildcard Tweaks/CaptionIsland/Assets/*.bundle)
$(TWEAK_NAME)_EMBED_EXTENSIONS = $(GENERATED_EXTENSION_APPEXS) $(CAPTION_ISLAND_WIDGET_APPEX)

include $(THEOS)/makefiles/common.mk
ifneq ($(JAILBROKEN),1)
SUBPROJECTS += Tweaks/Alderis Tweaks/DontEatMyContent Tweaks/FLEXing/libflex Tweaks/iSponsorBlock Tweaks/Return-YouTube-Dislikes Tweaks/YTABConfig Tweaks/YouGroupSettings Tweaks/CaptionIsland Tweaks/CaptionIslandWidget Tweaks/YTIcons Tweaks/YouLoop Tweaks/YouMute Tweaks/YouPiP Tweaks/YouQuality Tweaks/YouSlider Tweaks/YouSpeed Tweaks/YouTimeStamp Tweaks/YTHoldForSpeed Tweaks/YTUHD Tweaks/YTVideoOverlay Tweaks/YTweaks
include $(THEOS_MAKE_PATH)/aggregate.mk
endif
include $(THEOS_MAKE_PATH)/tweak.mk

REMOVE_EXTENSIONS = 1
CODESIGN_IPA = 0

UYOU_PATH = Tweaks/uYou
UYOU_DEB = $(UYOU_PATH)/com.miro.uyou_$(UYOU_VERSION)_iphoneos-arm.deb
UYOU_DYLIB = $(UYOU_PATH)/Library/MobileSubstrate/DynamicLibraries/uYou.dylib
UYOU_BUNDLE = $(UYOU_PATH)/Library/Application\ Support/uYouBundle.bundle
internal-clean::
	@rm -rf $(UYOU_PATH)/*
	@rm -rf "$(_THEOS_LOCAL_DATA_DIR)/generated-extensions"

ifneq ($(JAILBROKEN),1)
before-all::
	@rm -rf "$(GENERATED_EXTENSIONS_DIR)"
	@mkdir -p "$(GENERATED_EXTENSIONS_DIR)"
	@set -e; for name in $(STATIC_EXTENSION_NAMES); do \
		extension="Extensions/$$name"; \
		cp -R "$$extension" "$(GENERATED_EXTENSIONS_DIR)/$$name"; \
	done
before-all::
	@if [[ -f "$(IPA)/Info.plist" ]]; then \
		plutil -replace NSSupportsLiveActivities -bool YES "$(IPA)/Info.plist" 2>/dev/null || \
		plutil -insert NSSupportsLiveActivities -bool YES "$(IPA)/Info.plist"; \
		plutil -replace MinimumOSVersion -string "$(HOST_DEPLOYMENT_VERSION)" "$(IPA)/Info.plist" 2>/dev/null || \
		plutil -insert MinimumOSVersion -string "$(HOST_DEPLOYMENT_VERSION)" "$(IPA)/Info.plist"; \
		/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$(IPA)/Info.plist" 2>/dev/null || :; \
		/usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity:NSAllowsArbitraryLoadsForMedia" "$(IPA)/Info.plist" 2>/dev/null || :; \
		/usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity:NSAllowsArbitraryLoadsInWebContent" "$(IPA)/Info.plist" 2>/dev/null || :; \
		/usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity:NSAllowsLocalNetworking" "$(IPA)/Info.plist" 2>/dev/null || :; \
		/usr/libexec/PlistBuddy -c "Set :NSAppTransportSecurity:NSAllowsArbitraryLoads true" "$(IPA)/Info.plist" 2>/dev/null || \
		/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$(IPA)/Info.plist"; \
		/usr/libexec/PlistBuddy -c "Add :BGTaskSchedulerPermittedIdentifiers array" "$(IPA)/Info.plist" 2>/dev/null || :; \
		if ! /usr/libexec/PlistBuddy -c "Print :BGTaskSchedulerPermittedIdentifiers" "$(IPA)/Info.plist" 2>/dev/null | grep -Fq "$(CAPTION_ISLAND_CONTINUED_TASK_ID)"; then \
			/usr/libexec/PlistBuddy -c "Add :BGTaskSchedulerPermittedIdentifiers: string $(CAPTION_ISLAND_CONTINUED_TASK_ID)" "$(IPA)/Info.plist"; \
		fi; \
		if ! /usr/libexec/PlistBuddy -c "Print :UIBackgroundModes" "$(IPA)/Info.plist" 2>/dev/null | grep -qw audio; then \
			/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes array" "$(IPA)/Info.plist" 2>/dev/null || :; \
			/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes: string audio" "$(IPA)/Info.plist"; \
		fi; \
	fi
before-all::
	@if [[ ! -f $(UYOU_DEB) ]]; then \
		rm -rf $(UYOU_PATH)/*; \
		$(PRINT_FORMAT_BLUE) "Downloading uYou"; \
	fi
before-all::
	@if [[ ! -f $(UYOU_DEB) ]]; then \
 		curl -s -L "https://www.dropbox.com/scl/fi/01vvu5lm8nkkicrznku9v/com.miro.uyou_$(UYOU_VERSION)_iphoneos-arm.deb?rlkey=efgz7po8kqqvha8doplk1s3ky&dl=1" -o $(UYOU_DEB); \
 	fi; \
	if [[ ! -f $(UYOU_DYLIB) || ! -d $(UYOU_BUNDLE) ]]; then \
		tar -xf Tweaks/uYou/com.miro.uyou_$(UYOU_VERSION)_iphoneos-arm.deb -C Tweaks/uYou; tar -xf Tweaks/uYou/data.tar* -C Tweaks/uYou; \
		if [[ ! -f $(UYOU_DYLIB) || ! -d $(UYOU_BUNDLE) ]]; then \
			$(PRINT_FORMAT_ERROR) "Failed to extract uYou"; exit 1; \
		fi; \
	fi;
before-package::
	@test -f "$(IPA)/Info.plist"
	@bash Sources/prepare-alternate-icons.sh "$(IPA)" "Localizations/uYouPlus.bundle/AppIcons"
	@plutil -replace NSSupportsLiveActivities -bool YES "$(IPA)/Info.plist" 2>/dev/null || \
		plutil -insert NSSupportsLiveActivities -bool YES "$(IPA)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" "$(IPA)/Info.plist" 2>/dev/null || :
	@/usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity:NSAllowsArbitraryLoadsForMedia" "$(IPA)/Info.plist" 2>/dev/null || :
	@/usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity:NSAllowsArbitraryLoadsInWebContent" "$(IPA)/Info.plist" 2>/dev/null || :
	@/usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity:NSAllowsLocalNetworking" "$(IPA)/Info.plist" 2>/dev/null || :
	@/usr/libexec/PlistBuddy -c "Set :NSAppTransportSecurity:NSAllowsArbitraryLoads true" "$(IPA)/Info.plist" 2>/dev/null || \
		/usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$(IPA)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Add :BGTaskSchedulerPermittedIdentifiers array" "$(IPA)/Info.plist" 2>/dev/null || :
	@if ! /usr/libexec/PlistBuddy -c "Print :BGTaskSchedulerPermittedIdentifiers" "$(IPA)/Info.plist" 2>/dev/null | grep -Fq "$(CAPTION_ISLAND_CONTINUED_TASK_ID)"; then \
		/usr/libexec/PlistBuddy -c "Add :BGTaskSchedulerPermittedIdentifiers: string $(CAPTION_ISLAND_CONTINUED_TASK_ID)" "$(IPA)/Info.plist"; \
	fi
	@if ! /usr/libexec/PlistBuddy -c "Print :UIBackgroundModes" "$(IPA)/Info.plist" 2>/dev/null | grep -qw audio; then \
		/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes array" "$(IPA)/Info.plist" 2>/dev/null || :; \
		/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes: string audio" "$(IPA)/Info.plist"; \
	fi
	@test -f "$(CAPTION_ISLAND_WIDGET_APPEX)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID).CaptionIslandWidget" "$(CAPTION_ISLAND_WIDGET_APPEX)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(YOUTUBE_VERSION)" "$(CAPTION_ISLAND_WIDGET_APPEX)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(YOUTUBE_VERSION)" "$(CAPTION_ISLAND_WIDGET_APPEX)/Info.plist"
	@plutil -replace NSSupportsLiveActivities -bool YES "$(CAPTION_ISLAND_WIDGET_APPEX)/Info.plist" 2>/dev/null || \
		plutil -insert NSSupportsLiveActivities -bool YES "$(CAPTION_ISLAND_WIDGET_APPEX)/Info.plist"
	@set -e; for appex in $(GENERATED_EXTENSION_APPEXS); do \
		plist="$$appex/Info.plist"; \
		old_id=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$$plist"); \
		suffix=$${old_id#com.google.ios.youtube}; \
		test "$$suffix" != "$$old_id"; \
		/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)$$suffix" "$$plist"; \
		plutil -replace MinimumOSVersion -string "$(HOST_DEPLOYMENT_VERSION)" "$$plist" 2>/dev/null || \
		plutil -insert MinimumOSVersion -string "$(HOST_DEPLOYMENT_VERSION)" "$$plist"; \
	done
else
before-package::
	@mkdir -p $(THEOS_STAGING_DIR)/Library/Application\ Support; cp -r Localizations/uYouPlus.bundle $(THEOS_STAGING_DIR)/Library/Application\ Support/
endif
