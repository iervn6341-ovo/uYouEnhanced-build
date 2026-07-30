SDK_VERSION ?= 17.5
HOST_DEPLOYMENT_VERSION ?= 17.5
TARGET := iphone:clang:$(SDK_VERSION):$(HOST_DEPLOYMENT_VERSION)
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CaptionIsland

CaptionIsland_FILES = \
	Tweak.xm \
	CISettings.xm \
	CIBackgroundPlaybackMonitor.m \
	CIPlaybackState.m \
	CIConstants.m \
	CIModels.m \
	CIVideoEligibility.m \
	CITextUtilities.m \
	CICaptionParser.m \
	CILyricsAligner.m \
	CIYouTubeInspector.m \
	CILRCLIBProvider.m \
	CILogStore.m \
	CILogViewController.m \
	CIActivityPresenter.m \
	CICaptionCoordinator.m \
	CIActivityBridge.swift \
	CIActivityPushClient.swift \
	Shared/CICaptionActivityAttributes.swift
CaptionIsland_CFLAGS = -fobjc-arc
CaptionIsland_FRAMEWORKS = UIKit Foundation QuartzCore Security ActivityKit MediaPlayer AVKit
CaptionIsland_SWIFT_VERSION = 5

include $(THEOS_MAKE_PATH)/tweak.mk
