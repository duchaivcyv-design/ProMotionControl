Legacy Titanium hook modules retained verbatim for source reference only.

These files are intentionally NOT listed in the active Theos Makefile and are
not compiled or loaded. They contain private framebuffer/window-server/AGX hooks,
thermal/power state overrides, cross-process hooks, or anti-throttle behavior.
Those operations are not a supported way to raise physical display refresh rate
and can cause crashes, overheating, incorrect telemetry, or display instability.

The active release uses Tweak.x + TitaniumCoreBridge.m + the three tier modules.
All display-rate requests go through the shared CADisplayLink pipeline and obey
the actual panel maximum, Low Power Mode, and iOS thermal state.
