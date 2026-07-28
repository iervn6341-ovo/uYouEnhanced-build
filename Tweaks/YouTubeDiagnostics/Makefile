SDK_VERSION ?= 17.5
HOST_DEPLOYMENT_VERSION ?= 17.5
TARGET := iphone:clang:$(SDK_VERSION):$(HOST_DEPLOYMENT_VERSION)
ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YouTubeDiagnostics

YouTubeDiagnostics_FILES = \
	Tweak.xm \
	YTDSettings.xm \
	YTDLogStore.m \
	YTDUnifiedLogCollector.m \
	YTDiagnosticsViewController.m
YouTubeDiagnostics_CFLAGS = -fobjc-arc
YouTubeDiagnostics_FRAMEWORKS = UIKit Foundation OSLog

include $(THEOS_MAKE_PATH)/tweak.mk
