SDK_VERSION ?= 17.5
# A command-line TARGET from the host build must never lower the widget below
# ActivityKit's deployment floor.
override TARGET := iphone:clang:$(SDK_VERSION):16.1
ARCHS = arm64
THEOS_OBJ_DIR_NAME = obj/CaptionIslandWidget

include $(THEOS)/makefiles/common.mk

APPEX_NAME = CaptionIslandWidget

CaptionIslandWidget_FILES = \
	CaptionIslandWidget.swift \
	../CaptionIsland/Shared/CICaptionActivityAttributes.swift
CaptionIslandWidget_FRAMEWORKS = Foundation SwiftUI WidgetKit ActivityKit
CaptionIslandWidget_SWIFT_VERSION = 5
CaptionIslandWidget_INSTALL = 0
CaptionIslandWidget_APP_EXTENSION_SAFE_API = 1
CaptionIslandWidget_APP_EXTENSION_SAFE = 1

include $(THEOS_MAKE_PATH)/appex.mk
