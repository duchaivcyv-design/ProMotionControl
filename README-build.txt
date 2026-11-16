ProMotion Control — Dark Tab UI (auto-increment version)

What's changed
- Standalone /Applications/ProMotionControl.app (rootless package placement is handled by Theos).
- Four-tab dark UI: Trang chủ, Ứng dụng, Nâng cao, Chẩn đoán. Cài đặt chung is opened from Trang chủ.
- Approved neon monogram icon in all configured iPhone/iPad icon sizes.
- App manager has search + filters for all discovered apps, saved profiles, and enabled profiles.
- Best-effort app enumeration runs on a background queue; after five seconds the UI still offers saved profiles and manual Bundle ID entry.
- Opening an app from the catalog creates a safe, disabled profile if one does not already exist.
- The in-app Cài đặt chung page provides a structured overview and can reset global settings while preserving per-app profiles.
- Package postinst tries LaunchServices/uicache registration via both /Applications and /var/jb/Applications paths, then performs a full uicache refresh as a fallback.
- Removes the old PreferenceLoader registration and does not package a PreferenceBundle. The controls are in ProMotion Control, not in iOS Settings.
- Removes the unnecessary preferenceloader dependency from the package metadata.

Build
- Set THEOS to your Theos install; Makefiles select the newest SDK available in that install and keep iOS 15.0 as the minimum deployment target.
- Run ./build-ubuntu.sh from this directory (macOS is recommended for the modern rootless arm64e tweak ABI).
- Or push the repository and run the GitHub Actions workflow: Build ProMotion Control (four-tab UI; arm64+arm64e tweak).
- CI checks the package has the app bundle, executable, numeric bundle versions, icon files, postinst registration script and arm64 app slice, plus arm64 and arm64e tweak slices.

Important
- This source has not been built with Theos/Xcode in this environment and has not been device-tested. Treat it as a prototype until the workflow succeeds and the app launches on-device.
- If the Home Screen icon does not appear after installation, inspect /tmp/ProMotionControl-postinst.log first. Confirm the app bundle exists under /var/jb/Applications/ProMotionControl.app or /Applications/ProMotionControl.app. If it does, run a one-time uicache rescan for that app path and review the command output; do not reinstall repeatedly before checking the log.
- The standalone app uses Foundation/CFPreferences and checks same-process read-back. That does not prove the injected tweak can read the same domain in another sandboxed process; the Diagnostics tab calls this out. This prototype deliberately does not use private entitlements or bypass sandboxing.
- Installed-app discovery calls LaunchServices dynamically as a best-effort feature; if unavailable or restricted, the list falls back to saved profiles/manual Bundle ID.
- Per-app Hz/FPS still requires the tweak to be loaded and a compatible CADisplayLink path. This UI does not bypass loader policy, iOS access controls, or hardware limits, and does not fake the hardware maximum.

Version 5.7.51t adds the opt-in OverrideBlockedApps runtime switch. It applies only where the tweak is loaded and CADisplayLink range APIs are supported.


5.7.51t: full-card route touch handling and explicit CADisplayLink frame-pacing re-apply. Real device refresh ceilings and thermal constraints remain enforced. No arbitrary private sandbox entitlement is injected.


5.7.51t: automatic local thermal governor; see CHANGES-5.7.51t-auto-thermal-governor.txt.


UI update (next build 5.7.51t): main navigation has five tabs: Trang chủ, Ứng dụng, Thông số, Giới thiệu, Cài đặt. About includes authors Nguyễn Minh Hải, Taojb, the TikTok @nguyenminhhai_2012 link and tappable Link Bio / Discord HTTPS links.


5.7.51t diagnostics helper: The Diagnostics page can copy a user-approved runtime report and open ChatGPT. The user must review and paste it manually. No API key is embedded. This feature is source-only until built and tested on device.


5.7.51t icon-registration recovery
- Replace the project folder as a clean source tree; copying over an old folder can leave stale layout artifacts.
- postinst prefers logical /var/jb/Applications and /Applications paths, then resolves RootHide physical paths.
- uicache registration is tried against canonical paths first and falls back to the resolved path and a full rescan.
- postinst logs to /tmp/ProMotionControl-postinst.log, never unregisters unrelated apps, and does not leave dpkg half-configured solely because uicache failed.
- The build verifier must confirm Applications/ProMotionControl.app is in the .deb and no legacy Preferences bundle is packaged.


ProMotion Control 5.7.51t — Home Screen icon recovery

This source keeps the standalone ControlApp target and preserves the RP icon and bundle ID.
The build script increments VERSION from 5.7.51t to 5.7.51t on the next build and verifies that
packages/*.deb contains Applications/ProMotionControl.app, Info.plist, executable ProMotionControlApp,
and icon PNGs before installation.

postinst now validates the exact app bundle, repairs a leftover ProMotionControlApp.dpkg-tmp only when
the expected executable is missing, removes a targeted stale LaunchServices entry for this app, then
re-registers the validated bundle with uicache and refreshes the icon cache. It never unregisters other apps.
Detailed install logs are written to /tmp/ProMotionControl-postinst.log on the device.

Important: a source ZIP cannot guarantee an icon on every jailbreak without a real build/install test.
If the Home Screen icon remains missing, inspect the postinst log and verify the .deb contains the standalone
app bundle. Do not repeatedly install packages before checking that evidence.


5.7.51t: Overview Check runs for 15 seconds and checks runtime/metadata/device values; Safe Cleanup is limited to this app sandbox caches and temporary files. It cannot clean global RAM or other apps data.

5.7.53t: English/Vietnamese app UI selection, dark/light theme, and broader UIKit animation-lock hooks. Runtime rate requests still respect physical display/iOS limitations.


5.7.64t Safe Runtime Recovery: runtime changes are deferred until an eligible app is active when SafeRecovery is enabled. If repeated CADisplayLink exceptions occur, runtime intervention is disabled for that process. This is best-effort, not a guarantee against all crash/respring causes.

5.7.72t Runtime option activation: AdaptiveFPS, ThermalGuard, StutterFix, and AppStabilityFix now have explicit runtime behavior; animation/charging policies refresh when shared preferences change, and diagnostics include the option snapshot loaded by each eligible process. The option snapshot is not a measurement of actual FPS or proof that every setting affects every app.


5.7.73t note: this release adds a scoped CAFrameRateRangeMake hook and a guarded legacy frameInterval path, plus a thermal hysteresis governor. Thermal safety remains controlled by iOS; the tweak only caps its own requested frame rate and never disables system throttling. Compile with Theos and validate on-device before installing.


Version 5.7.75t thermal target hold: if the battery-pack IORegistry sensor is readable and >=39 C, the tweak-local Thermal Guard does not reduce the configured FPS request; iOS thermal management remains active and can still throttle. Sensor values are cached for 10 seconds. BackgroundReduction restores original CADisplayLink settings in the background; it does not force-quit user apps. Logos %orig fallback calls were moved outside @catch blocks to avoid parser issues. Full Theos/device validation remains required.


5.7.90t notes: the filter targets common UI/render classes and a pre-Logos guard limits hook installation to recognized installed .app executables. Advertised rate remains a software value; native hardware maximum is recorded separately.


5.7.91t layer diagnostics note: runtime reporting now includes selected/requested/native rate path status. This does not perform kernel driver writes or bypass sandbox/RootHide. See LAYERED-RATE-PATH-NOTES-5.7.91t.txt.


Current source package version: 5.8.82t (stamped in Tweak.x during this build).
For an exact 5.8.85t package build, run BUILD_VERSION_OVERRIDE=5.8.85t ./run-build-ubuntu.sh.
The override controls version stamping only; all normal source compatibility and safety checks remain enabled.

5.7.99t source note: fixes per-app IOKit diagnostic persistence and stamps the version in Tweak.x/runtime diagnostics during build. The build script verifies that package metadata and the compiled dylib agree. IOKit access is read-only; real Theos build and on-device test remain required.

Logos compile fix: custom `%ctor` now calls `%init;` to initialize the implicit `_ungrouped` hooks before initializing named runtime groups. `build-ubuntu.sh` verifies this invariant before building.

Compile note (Integrated v2 compile fix): Makefile suppresses unused-parameter warnings
from deliberately overridden Logos hook arguments, while other -Werror checks remain active.
Tweak.x declares the CALayer selectors for message-send type checking; these declarations
do not guarantee runtime selector availability.


5.8.11t native-animation restoration and retired animation-lock removal
- Tweak.x includes a chained NSUncaughtExceptionHandler and best-effort append logging to /var/mobile/Library/Preferences/com.promotioncontrol.crash.log, with a sandbox-safe temporary-directory fallback.
- PM_SAFE_TRY is limited to optional Objective-C diagnostics/initialization. Existing host-method %orig calls are not blindly swallowed.
- This is diagnostic containment, not 100% crash prevention. Objective-C exception handlers cannot recover from all memory faults, signals, watchdog terminations, jetsam, or native failures. Real Theos compilation and on-device testing remain required.


5.8.12t power/thermal integration notes
- Keeps the existing RAM-cached preference pipeline, native-display maximum checks, iOS thermal-state governor, low-battery request cap and opt-in charging-idle render-load reduction.
- Battery monitoring is restored to its previous state in @finally if reading battery level raises an Objective-C exception. Battery-state changes now queue a fresh display-policy evaluation.
- Native iOS thermal protection, Low Power Mode, and original UIKit/Core Animation animation behavior remain authoritative. No private thermal-daemon hooks, thermal-level spoofing, charger-current overrides, or CATransaction animation-disabling hooks were added.
- This is source-only until Theos compiles the package and it is validated on an actual device.


5.8.13t Multi-Layer SafeShield integration
- Reuses the existing RAM-cached Filza compatibility reader, CADisplayLink pacing and native hardware cap, guarded/opt-in CAMetalLayer policy, ReplayKit/capture-state handling, thermal governor, and chained exception diagnostics. Duplicate hook implementations are deliberately not added.
- Native UIKit/Core Animation animation behavior remains restored; no animation-lock option or CATransaction setDisableActions hook is introduced.
- The sample SBHWidgetViewController hook is not installed: this tweak intentionally excludes SpringBoard, and the supplied viewDidLoad example calls %orig twice. Private SpringBoard injection is outside this release's supported scope.
- Private ProcessState/ThermalMonitor hooks, fake thermal levels, forced Low Power Mode overrides, and global V-Sync disabling are omitted; iOS retains thermal/power control and physical display limits.
- The exception handler records diagnostic information only; it does not guarantee prevention of crashes. This remains source-only until a real Theos build and device test succeed.


5.8.14t Null-Safety / Multi-Layer Shield refinement
- Added synchronized swapping of the shared preference snapshot so runtime hook threads do not observe a partially replaced dictionary.
- Hardened named-domain preference reads and boolean/integer parsing against nil, wrong object types, malformed strings, and Objective-C exceptions.
- Kept the existing single Logos initialization path, native display-cap limits, original iOS animations, and iOS-owned thermal protections. No duplicate CADisplayLink/UIScreen/CAMetalLayer hooks were added.
- Objective-C exception diagnostics are best-effort only; this is not a 100% crash-proof guarantee and does not catch SIGSEGV, memory corruption, or every C++/system exception.
- Source version 5.8.14t; the next successful Ubuntu/WSL build stamps 5.8.15t. Theos compilation and real-device validation remain required.


5.8.50t Premium persistence / FREE fallback
- A successful Premium unlock is remembered against the current tweak installation identity. The app can resume the selected protected mode without prompting again while that install identity remains valid.
- Removing/purging the tweak removes its installation identity; reinstall creates a new random identity, so the old authorization no longer matches. FREE remains available at all times.
- The local password is a UI gate, not secure remote authentication. Tweak presence markers do not initialize Logos hooks or change the emergency isolation guard.

5.8.51t ADMIN server profile
- Added FREE / PREMIUM / ADMIN server selection to the Home dashboard. ADMIN inherits the existing Premium authorization; it is not iOS root/admin access and no second admin password is implemented.
- Added PMUltimatePowerEngine. It requests a CADisplayLink cadence bounded by the physical display maximum and capped at 120; iOS retains final scheduling and thermal/power policy.
- Added ADMIN-only app-local switches for render scheduling, touch delivery in app-owned scroll views, faster scroll deceleration, scroll indicator visibility, and opt-in rasterization for tagged static opaque views.
- All modified scroll and layer settings are restored when switching modes, suspending the engine, or leaving the app. View traversal is bounded to 4096 items.
- SCHED_FIFO priority changes, global gesture mutations, thermal/battery-throttling bypasses, arbitrary root shell execution, and cross-app hooks are not enabled. Tweak.x remains in emergency injection isolation.
- This is source-only until Theos compilation and device testing complete. No 2x performance gain is guaranteed or claimed.

5.8.52t SERVER CONTROL TOUCH FIX
- The Home SERVER selector uses three independent UIButton hit targets (FREE, PREMIUM, ADMIN) instead of a nested UISegmentedControl.
- Each button has a 46pt minimum height and an explicit TouchUpInside callback.
- If the injected tweak runtime marker is unavailable, protected-server selection now shows an explanation instead of silently reverting to FREE.
- Cancelled or failed authentication returns the visible server selection to FREE; successful activation updates the selection and rebuilds the dashboard.
- Source VERSION is 5.8.51t and auto-increments to 5.8.52t on the next successful build.


5.8.53t ADMIN local bridge + thermal-load control
- Added PMLocalBridge as an optional client for a separately installed root-owned AF_UNIX daemon.
- The client accepts only status, thermal_reduce, and thermal_resume; verifies the socket file and root peer, applies bounded I/O timeouts, and runs off the main thread.
- No privileged daemon or arbitrary command executor is included. If the socket is absent, the bridge fails closed and local Admin thermal protection continues.
- Admin thermal governor requests at most 60 Hz for the auxiliary display-link at Fair pressure, stops it for Serious/Critical or Low Power Mode, and backs off CPU telemetry sampling.
- iOS thermal management remains authoritative; no attempt is made to defeat thermal throttling or change brightness.

5.8.59t three-server rate pipeline (source baseline 5.8.58t): FREE, PREMIUM and ADMIN now resolve preset/custom Hz and FPS independently. ADMIN carries maximum Hz and preferred FPS through Nexus/PowerRefresh. Values remain requests bounded by the physical panel and iOS policy. The exact ControlApp-only injection filter remains unchanged; third-party app injection is not enabled. See CHANGES-5.8.59t-three-server-rate-pipeline.md.


Release safety/performance notes (5.8.83t build):
- Dashboard's PANEL/KHÓA/CHỌN status line has been removed.
- Hz/FPS settings remain saved separately; active requests are clamped to the native panel, Low Power Mode, and real thermal state.
- FREE sentinel cadence: 1.0 s (1x). PREMIUM: 0.5 s (2x maintenance checks). ADMIN: 0.1 s (10x maintenance checks). These are reassert/check intervals, not 2x/10x hardware performance claims.
- ADMIN memory inspection remains about every 20 seconds; background task requests are capped at 30 minutes and remain subject to iOS expiration.
- Sileo/Zebra postinst now resolves the app through fixed rootless aliases and dpkg-query, avoiding a recursive scan of all application containers.
- Private framebuffer, render-server, AGX, anti-throttle and cross-app modules are retained under Reference-Not-Built and excluded from the release binary.


5.8.83t panel-truth / tier cadence refinement
- Removed the obsolete PANEL/KHÓA/CHỌN dashboard status line and the nonfunctional "Advertise Selected Rate to Apps" UI control.
- FREE/PREMIUM/ADMIN rate requests use one shared CADisplayLink path and are clamped to the real display maximum and iOS Low Power/thermal policy.
- Tier sentinel cadence is FREE=1.0 s, PREMIUM=0.5 s (2x checks), ADMIN=0.1 s (10x checks). These values only describe maintenance/reassert frequency, not CPU/GPU speed.
- PREMIUM no longer claims to spoof UIScreen.maximumFramesPerSecond. CoreBridge no longer describes CPU core pinning; iOS owns CPU scheduling.
- The package postinst avoids a recursive app-container scan and resolves the app through known rootless aliases plus dpkg-query.
- Legacy private-driver, fake-mode, thermal-bypass and cross-process modules are preserved verbatim under Reference-Not-Built and are not compiled.
