DEBUG = 0
FINALPACKAGE = 1
ARCHS = arm64
TARGET = iphone:clang:latest:15.0
PACKAGE_SCHEME ?= rootless

ifeq ($(PACKAGE_SCHEME),rootless)
THEOS_PACKAGE_SCHEME = rootless
else ifeq ($(PACKAGE_SCHEME),rootful)
# Rootful is Theos' default package layout; leave THEOS_PACKAGE_SCHEME unset.
else
$(error PACKAGE_SCHEME must be rootless or rootful)
endif

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = ProMotionControlApp
ProMotionControlApp_BUNDLE_NAME = ProMotionControl
ProMotionControlApp_FILES = main.m PMAppDelegate.m PMControlViewController.m PMPremiumOptimizationEngine.m PMPerformanceSuite.m PMLocalBridge.m PMEarthNetworkViewControllers.m
ProMotionControlApp_FRAMEWORKS = UIKit Foundation QuartzCore Metal Network SystemConfiguration CoreLocation MapKit
# Match the tweak's warning policy while retaining compiler diagnostics.
ProMotionControlApp_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-error -Wno-unused-parameter -Wno-unused-variable -Wno-deprecated-declarations -Wno-nullability-completeness -g0
ProMotionControlApp_ARCHS = arm64
ProMotionControlApp_INSTALL_PATH = /Applications
ProMotionControlApp_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk
