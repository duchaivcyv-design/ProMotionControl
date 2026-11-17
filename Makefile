# ProMotionControl: low-memory, reproducible Theos build configuration.
DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

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

# Explicit file list — NO wildcards. Theos has a known bug when wildcarding .x
# files inside subdirectories (creates .x.m in one path, tries to compile from
# another). Every .x file must live at the project root.
ProMotionControl_FILES = Tweak.x \
                         TitaniumCoreBridge.m \
                         TitaniumBackgroundContinuity.m \
                         TitaniumServerFreeEngine.x \
                         TitaniumServerPremiumEngine.x \
                         TitaniumServerAdminEngine.x \
                         TitaniumServerTierSupreme.x \
                         TitaniumUltimateDeepEngine.x \
                         TitaniumHardwareOverdriveGuard.x \
                         TitaniumApexSupremeUltimateEngine.x \
                         TitaniumAbsoluteAntiThrottleEngine.x \
                         TitaniumThermalBatteryGuardian.x \
                         TitaniumCrossAppBypassEngine.x

ProMotionControl_FRAMEWORKS = Foundation UIKit QuartzCore AVFoundation IOKit

ProMotionControl_CFLAGS = -fobjc-arc -Wall -Wextra -Wno-error -Wno-unused-parameter -Wno-unused-variable -Wno-deprecated-declarations -Wno-nullability-completeness -g0

ifeq ($(ALLOW_DYNAMIC_LOOKUP),1)
ProMotionControl_LDFLAGS += -undefined dynamic_lookup
endif

SUBPROJECTS = ControlApp
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
