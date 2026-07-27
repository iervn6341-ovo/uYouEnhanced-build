TARGET := iphone:clang:17.5:15.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CaptionIsland

CaptionIsland_FILES = \
	Tweak.xm \
	CISettings.xm \
	CIConstants.m \
	CIModels.m \
	CITextUtilities.m \
	CICaptionParser.m \
	CILyricsAligner.m \
	CIYouTubeInspector.m \
	CILRCLIBProvider.m \
	CIOverlayPresenter.m \
	CICaptionCoordinator.m
CaptionIsland_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
CaptionIsland_FRAMEWORKS = UIKit Foundation QuartzCore Security

include $(THEOS_MAKE_PATH)/tweak.mk
