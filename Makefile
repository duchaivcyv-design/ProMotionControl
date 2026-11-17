# ============================================================================
# ProMotionControl — Theos Makefile (8.4.4t)
# Low-memory, reproducible build. Matches the 6-file runtime that ships after
# 8.4.3t: Tweak.xm + TitaniumSettingsAPI.x + Deep + Overdrive + Supreme +
# AntiThrottle. Header TitaniumSettingsAPI.h stays on disk for AntiThrottle's
# #import only — every other file now inlines its own externs (per 8.4.1t /
# 8.4.2t / 8.4.3t).
# ============================================================================
DEBUG = 0
FINALPACKAGE = 1

# Device architectures supported by the tweak. Standalone app is arm64-only;
# the dylib ships both so an arm64e process (system helpers) can load it if
# the filter is ever widened.
ARCHS = arm64 arm64e

# Deployment target stays iOS 15.0 — 8.x runtime guards use @available(iOS 15)
# for CAFrameRateRange and other modern APIs.
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

ProMotionControl_FILES = Tweak.x \
                         TitaniumUltimateDeepEngine.x \
                         TitaniumHardwareOverdriveGuard.x \
                         TitaniumApexSupremeUltimateEngine.x \
                         TitaniumAbsoluteAntiThrottleEngine.x

# AVFoundation: AVAudioSession hook in Overdrive.
# QuartzCore: CADisplayLink / CAWindowServerDisplay / CADisplay / CAAnimation.
# Foundation + UIKit: NSProcessInfo / UIScreen / UIView / UIWindow / NSURLCache.
# IOKit is resolved at runtime via dlopen in Tweak.xm — not link-time.
ProMotionControl_FRAMEWORKS = Foundation UIKit QuartzCore AVFoundation

# -Wno-error prevents ordinary warnings from stopping a release build while
# preserving warnings. Do not suppress implicit function declarations: missing
# prototypes should be fixed instead of hidden, since they can cause runtime
# faults. -I$(THEOS_PROJECT_DIR) so TitaniumAbsoluteAntiThrottleEngine.x can
# #import "TitaniumSettingsAPI.h" from the project root.
ProMotionControl_CFLAGS = -fobjc-arc \
                          -I$(THEOS_PROJECT_DIR) \
                          -Wall -Wextra -Wno-error \
                          -Wno-unused-parameter -Wno-unused-variable \
                          -Wno-deprecated-declarations \
                          -Wno-nullability-completeness \
                          -g0

# Undefined dynamic lookup is opt-in only; enabling it globally can conceal
# missing symbols and defer failures until runtime. Use ALLOW_DYNAMIC_LOOKUP=1
# only for symbols deliberately resolved at runtime and validated by the code.
# The 8.x build does NOT need it: PM_ExportMasterRate / PM_ExportMasterEnabled
# are defined in Tweak.xm, every other bridge symbol is defined in
# TitaniumSettingsAPI.x. All externs resolve at link.
ifeq ($(ALLOW_DYNAMIC_LOOKUP),1)
ProMotionControl_LDFLAGS += -undefined dynamic_lookup
endif

SUBPROJECTS = ControlApp
include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk
