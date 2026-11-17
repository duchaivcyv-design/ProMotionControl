# ProMotionControl: low-memory, reproducible Theos build configuration.
DEBUG = 0
FINALPACKAGE = 1

# Device architectures supported by the tweak. Keep the standalone app arm64-only.
ARCHS = arm64 arm64e

# Use an SDK installed in the current Theos tree. The local machine previously
# reported that iPhoneOS16.5.sdk was missing; deployment target stays iOS 15.0.
TARGET ?= iphone:clang:latest:15.0
PACKAGE_SCHEME ?= rootless

ifeq ($(PACKAGE_SCHEME),rootless)
THEOS_PACKAGE_SCHEME = rootless
else ifeq ($(PACKAGE_SCHEME),rootful)
# Rootful is Theos' default package layout; leave THEOS_PACKAGE_SCHEME unset.
else
$(error PACKAGE_SCHEME must be rootless or rootful)
endif

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ProMotionControl
ProMotionControl_FILES = Tweak.x TitaniumCoreBridge.m TitaniumBackgroundContinuity.m TitaniumServerFreeEngine.x TitaniumServerPremiumEngine.x TitaniumServerAdminEngine.x Reference/*.x

# IOKit is required — Tweak.x's PMOpenMainFramebuffer / PMAttemptDriverOverride
# call IOObjectRelease() and IOServiceGetMatchingService(kIOMasterPortDefault, ...)
# directly. Both are real IOKit framework symbols; the dlopen() path only resolves
# IOMobileFramebuffer private entry points via dlsym. Link-time resolution is needed
# for _IOObjectRelease and _kIOMasterPortDefault or the link step fails.
ProMotionControl_FRAMEWORKS = Foundation UIKit QuartzCore AVFoundation IOKit

# -Wno-error prevents ordinary warnings from stopping a release build, while
# preserving warnings. Do not suppress implicit function declarations: missing
# prototypes should be fixed instead of hidden, since they can cause runtime faults.
ProMotionControl_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-error -Wno-unused-parameter -Wno-unused-variable -Wno-deprecated-declarations -Wno-nullability-completeness -g0

# Undefined dynamic lookup is opt-in only; enabling it globally can conceal
# missing symbols and defer failures until runtime. Use ALLOW_DYNAMIC_LOOKUP=1
# only for symbols deliberately resolved at runtime and validated by the code.
ifeq ($(ALLOW_DYNAMIC_LOOKUP),1)
ProMotionControl_LDFLAGS += -undefined dynamic_lookup
endif

SUBPROJECTS = ControlApp
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
