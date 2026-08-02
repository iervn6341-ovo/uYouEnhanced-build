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
	CIContinuedProcessingController.m \
	CIPlaybackState.m \
	CIConstants.m \
	CILanguagePriorityViewController.m \
	CIModels.m \
	CICaptionTiming.m \
	CIVideoEligibility.m \
	CIVideoOverrides.m \
	CITextUtilities.m \
	CICaptionParser.m \
	CILyricsAligner.m \
	CIYouTubeInspector.m \
	CILRCLIBProvider.m \
	CILogStore.m \
	CIProcessDiagnostics.m \
	CILogViewController.m \
	CIActivityPresenter.m \
	CICaptionCoordinator.m \
	CIActivityBridge.swift \
	Shared/CICaptionActivityAttributes.swift
CaptionIsland_CFLAGS = -fobjc-arc
CaptionIsland_FRAMEWORKS = UIKit Foundation QuartzCore ActivityKit MediaPlayer AVKit BackgroundTasks
CaptionIsland_SWIFT_VERSION = 5

include $(THEOS_MAKE_PATH)/tweak.mk
