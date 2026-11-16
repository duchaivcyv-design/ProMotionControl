#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${THEOS:?THEOS is not set. Example: export THEOS=$HOME/theos}"
MAKE_BIN="${MAKE_BIN:-}"
if [[ -z "$MAKE_BIN" ]]; then
    if command -v gmake >/dev/null 2>&1; then
        MAKE_BIN="$(command -v gmake)"
    elif command -v make >/dev/null 2>&1; then
        MAKE_BIN="$(command -v make)"
    else
        echo "GNU make is required (install make; on macOS use gmake)." >&2
        exit 1
    fi
fi
command -v python3 >/dev/null || { echo "python3 is required to validate plist files" >&2; exit 1; }

# Recover a partially stamped source tree if the previous WSL session was stopped.
# Existing .deb files are kept until a newly built package passes all validation.
RECOVERY_DIR="$PWD/.build-recovery"
PM_VERIFY_TMP=""
pm_restore_interrupted_build() {
    if [[ -f "$RECOVERY_DIR/ACTIVE" ]]; then
        local next_version rel
        next_version="$(cat "$RECOVERY_DIR/NEXT_VERSION" 2>/dev/null || true)"
        if [[ -f "$RECOVERY_DIR/FILES" ]]; then
            while IFS= read -r rel; do
                [[ -n "$rel" ]] || continue
                if [[ -f "$RECOVERY_DIR/snapshot/$rel" ]]; then
                    mkdir -p "$(dirname "$rel")"
                    cp -p "$RECOVERY_DIR/snapshot/$rel" "$rel"
                fi
            done < "$RECOVERY_DIR/FILES"
        fi
        if [[ -n "$next_version" && -d packages ]]; then
            find packages -maxdepth 1 -type f -name "*${next_version}*.deb" -delete 2>/dev/null || true
        fi
        rm -rf "$RECOVERY_DIR"
        echo "Recovered source/version after interrupted build; prior packages were preserved."
    elif [[ -d "$RECOVERY_DIR" ]]; then
        rm -rf "$RECOVERY_DIR"
    fi
}
pm_restore_interrupted_build

pm_on_exit() {
    local status=$?
    trap - EXIT
    if [[ -n "${PM_VERIFY_TMP:-}" && -d "$PM_VERIFY_TMP" ]]; then
        rm -rf "$PM_VERIFY_TMP" || true
    fi
    if [[ $status -ne 0 && -f "$RECOVERY_DIR/ACTIVE" ]]; then
        echo "Build failed (exit $status); restoring VERSION/Tweak/control/plists and keeping previous .deb packages." >&2
        pm_restore_interrupted_build || true
    fi
    exit "$status"
}

# Release preflight: standalone ControlApp plus one safe, shared display-link runtime.
if ! grep -Eq '^[[:space:]]*SUBPROJECTS[[:space:]]*=[[:space:]]*ControlApp[[:space:]]*$' Makefile; then
    echo "ERROR: top-level Makefile must build the standalone ControlApp." >&2
    exit 1
fi
if ! grep -Eq '^[[:space:]]*APPLICATION_NAME[[:space:]]*=[[:space:]]*ProMotionControlApp[[:space:]]*$' ControlApp/Makefile; then
    echo "ERROR: ControlApp target is not ProMotionControlApp." >&2
    exit 1
fi
for required in Tweak.x TitaniumCoreBridge.m TitaniumBackgroundContinuity.m \
                TitaniumServerTierSupport.h TitaniumServerFreeEngine.x \
                TitaniumServerPremiumEngine.x TitaniumServerAdminEngine.x \
                ControlApp/Makefile ControlApp/main.m ControlApp/PMAppDelegate.m \
                ControlApp/PMControlViewController.m ControlApp/PMPremiumOptimizationEngine.h \
                ControlApp/PMPremiumOptimizationEngine.m ControlApp/PMPerformanceSuite.h \
                ControlApp/PMPerformanceSuite.m ControlApp/PMLocalBridge.m \
                ControlApp/PMEarthNetworkViewControllers.m ControlApp/Resources/Info.plist \
                layout/DEBIAN/postinst layout/DEBIAN/postrm; do
    if [[ ! -s "$required" ]]; then
        echo "ERROR: required release source missing: $required" >&2
        exit 1
    fi
done
python3 - <<'SAFE_RELEASE_PREFLIGHT'
import plistlib, re
from pathlib import Path

root_make = Path('Makefile').read_text(errors='replace')
app_make = Path('ControlApp/Makefile').read_text(errors='replace')
info_path = Path('ControlApp/Resources/Info.plist')
with info_path.open('rb') as f:
    info = plistlib.load(f)
assert info.get('CFBundleIdentifier') == 'com.dell.promotioncontrol.app'
assert info.get('CFBundleExecutable') == 'ProMotionControlApp'
assert info.get('CFBundlePackageType') == 'APPL'
assert info.get('CADisableMinimumFrameDurationOnPhone') is True
assert 'PMControlViewController.m' in app_make and 'PMPremiumOptimizationEngine.m' in app_make
assert 'PMPerformanceSuite.m' in app_make and 'PMEarthNetworkViewControllers.m' in app_make
assert 'MapKit' in app_make and 'CoreLocation' in app_make

# Only the single core display pipeline and the three tier policy modules are active.
active_sources = re.search(r'(?m)^ProMotionControl_FILES\s*=\s*(.*)$', root_make)
assert active_sources, 'Missing ProMotionControl_FILES'
active = active_sources.group(1)
for filename in ['TitaniumServerFreeEngine.x', 'TitaniumServerPremiumEngine.x',
                'TitaniumServerAdminEngine.x', 'TitaniumCoreBridge.m']:
    assert filename in active, f'{filename} is not compiled'
for filename in ['TitaniumUltimateDeepEngine.x', 'TitaniumApexSupremeUltimateEngine.x',
                 'TitaniumHardwareOverdriveGuard.x', 'TitaniumCrossAppBypassEngine.x',
                 'TitaniumThermalBatteryGuardian.x', 'TitaniumAbsoluteAntiThrottleEngine.x']:
    assert filename not in active, f'unsafe/duplicate legacy engine still compiled: {filename}'
    assert (Path('Reference-Not-Built') / filename).is_file(), f'original reference not preserved: {filename}'

# No private driver, render-server, AGX, false thermal, false capability, or RT-priority hooks in active runtime.
tweak = Path('Tweak.x').read_text(errors='replace')
bridge = Path('TitaniumCoreBridge.m').read_text(errors='replace')
free = Path('TitaniumServerFreeEngine.x').read_text(errors='replace')
premium = Path('TitaniumServerPremiumEngine.x').read_text(errors='replace')
admin = Path('TitaniumServerAdminEngine.x').read_text(errors='replace')
for name, source in [('Tweak.x', tweak), ('TitaniumCoreBridge.m', bridge),
                     ('FREE', free), ('PREMIUM', premium), ('ADMIN', admin)]:
    for forbidden in ['%hook IOMobileFramebufferClient', '%hook IOMobileFramebuffer',
                      '%hook CAWindowServerDisplay', '%hook AGXAccelerator',
                      'setDisplaySyncEnabled:', 'setCFProperty:', 'setPowerState:',
                      'setPerfState:', 'pthread_setschedparam', 'SCHED_FIFO']:
        assert forbidden not in source, f'{name} contains unsupported hardware/system hook: {forbidden}'
assert '%hook CADisplayLink' in tweak, 'Shared CADisplayLink runtime hook missing'
assert 'PMRateRangeForActiveServer' in tweak and 'PMGetTargetHz' in tweak and 'PMGetTargetFPS' in tweak
assert 'PMThermalTargetCap' in tweak and 'maximumFramesPerSecond' in tweak
assert 'isLowPowerModeEnabled' in tweak and 'NSProcessInfoThermalStateSerious' in tweak
assert 'THREAD_AFFINITY_POLICY' not in bridge and 'SCHED_FIFO' not in bridge
assert '%hook UIScreen' not in premium and '%hook UIScreen' not in admin
assert 'CAWindowServerDisplay' not in admin and 'IOMobileFramebuffer' not in admin
assert 'CAMetalLayer' not in admin

# Exact mode affects the lock only; it cannot skip native panel, Low Power or thermal limits.
cap_start = tweak.index('static NSInteger PMThermalTargetCap(')
cap_end = tweak.index('typedef struct {', cap_start)
cap = tweak[cap_start:cap_end]
assert 'maximumFramesPerSecond' in cap and 'isLowPowerModeEnabled' in cap
assert 'NSProcessInfoThermalStateSerious' in cap and 'PMExactRateEnforcementEnabled' not in cap
resolve_start = tweak.index('static TitaniumHardwareTarget Titanium_ResolveHardwareTarget(')
resolve_end = tweak.index('// Premium Tier-4 integration point', resolve_start)
resolve = tweak[resolve_start:resolve_end]
assert 'target.hardwareMaximum' in resolve and 'target.effectiveHz = MIN' in resolve
engine = Path('ControlApp/PMPremiumOptimizationEngine.m').read_text(errors='replace')
assert 'MIN(hardwareMaximum, requestedHz)' in engine
assert 'ExactRateEnforcement changes cadence locking, not hardware safety boundaries.' in engine
assert 'if (exactRate) {\n        return MIN(244.0' not in engine

# Per-tier maintenance cadence: 1x / 2x / 10x compared with FREE, not hardware clock multipliers.
assert 'kTitaniumFreeSentinelInterval = 1.0' in free
assert 'kTitaniumPremiumSentinelInterval = 0.5' in premium
assert 'kTitaniumAdminSentinelInterval = 0.10' in admin
assert 'kTitaniumAdminMemoryTickEvery = 200' in admin
assert 'kTitaniumAdminKeepAliveCap = 1800.0' in admin
assert 'case 2: return 0.10;' in tweak and 'case 1: return 0.50;' in tweak and 'default: return 1.00;' in tweak

# The obsolete dashboard line and fake capability switches must not return.
controller = Path('ControlApp/PMControlViewController.m').read_text(errors='replace')
for retired in ['dashboardPanelTruthLabel', 'PMPanelHardwareMaximumHz', 'PMActiveUnlockLevelLabel',
                'PANEL %ld Hz', 'PremiumUnlockReportedMaximumFPS',
                'AdminPixelClockDeclarationEnabled', 'AdminDisplaySyncControlEnabled',
                'AdminUnlockReportedMaximumFPS']:
    assert retired not in controller, f'retired panel/driver UI item remains: {retired}'
assert 'Khóa đúng đang bật' not in controller
assert 'Quảng bá mức Hz đã chọn cho app' not in controller
assert 'AdvertiseSelectedRateToApps' not in controller
assert 'thử tắt displaySync và dùng 3 drawable' not in controller
assert 'FramebufferOnly Optimization' not in controller

# Installer path: use dpkg-managed bundle path; never recursively search every app container.
postinst = Path('layout/DEBIAN/postinst').read_text(errors='replace')
assert 'dpkg-query -L com.dell.promotioncontrol' in postinst
assert 'uicache' in postinst and '.com.dell.promotioncontrol.installation-id' in postinst
assert 'find "$rootdir"' not in postinst
assert Path('layout/DEBIAN/postrm').is_file()

# Strict tweak filter: only the exact ControlApp bundle receives the dylib.
with Path('ProMotionControl.plist').open('rb') as f:
    filter_root = plistlib.load(f).get('Filter', {})
assert filter_root.get('Bundles') == ['com.dell.promotioncontrol.app']
assert not filter_root.get('Classes', [])

# Numeric bundle version is stamped by the build script; source must define one runtime token.
assert re.search(r'(?m)^#define PM_BUILD_VERSION @"[0-9]+\.[0-9]+\.[0-9]+t"$', tweak)
print('Verified: panel status line removed; single device-safe FPS/Hz pipeline; FREE/PREMIUM/ADMIN cadence; no private driver or thermal-bypass hooks in active build; fast dpkg-path app registration.')
SAFE_RELEASE_PREFLIGHT

# Ensure Debian maintainer scripts remain executable in the staged package.
chmod 755 "$0" layout/DEBIAN/postinst layout/DEBIAN/postrm

VERSION_FILE="VERSION"
CURRENT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$CURRENT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+t$ ]]; then
    echo "Invalid VERSION: $CURRENT_VERSION" >&2
    exit 1
fi

# Exact version may be requested for reproducible release builds; otherwise retain auto-increment.
# The version stamping remains transactional: failed builds restore the original source metadata.
if [[ -n "${BUILD_VERSION_OVERRIDE:-}" ]]; then
    if [[ ! "$BUILD_VERSION_OVERRIDE" =~ ^[0-9]+\.[0-9]+\.[0-9]+t$ ]]; then
        echo "Invalid BUILD_VERSION_OVERRIDE: $BUILD_VERSION_OVERRIDE" >&2
        exit 1
    fi
    VERSION="$BUILD_VERSION_OVERRIDE"
else
    VERSION="$(python3 - "$CURRENT_VERSION" <<'PYVER'
import re, sys
m = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)t', sys.argv[1])
if not m:
    raise SystemExit('Invalid version format')
major, minor, patch = map(int, m.groups())
if patch >= 99:
    minor += 1
    patch = 0
    if minor >= 100:
        major += 1
        minor = 0
else:
    patch += 1
print(f'{major}.{minor}.{patch}t')
PYVER
)"
fi
# Snapshot every file this script stamps before modifying it. The ACTIVE marker is
# written last so an interrupted snapshot is never mistaken for a build in progress.
mkdir -p "$RECOVERY_DIR/snapshot"
: > "$RECOVERY_DIR/FILES"
pm_snapshot_file() {
    local rel="$1"
    [[ -f "$rel" ]] || return 0
    if ! grep -Fxq "$rel" "$RECOVERY_DIR/FILES"; then
        mkdir -p "$RECOVERY_DIR/snapshot/$(dirname "$rel")"
        cp -p "$rel" "$RECOVERY_DIR/snapshot/$rel"
        printf '%s\n' "$rel" >> "$RECOVERY_DIR/FILES"
    fi
}
for rel in VERSION Tweak.x control README-build.txt; do pm_snapshot_file "$rel"; done
while IFS= read -r plist_path; do
    plist_path="${plist_path#./}"
    [[ "$plist_path" == .build-recovery/* || "$plist_path" == .theos/* || "$plist_path" == packages/* ]] && continue
    pm_snapshot_file "$plist_path"
done < <(find . -path './.build-recovery' -prune -o -path './.theos' -prune -o -path './packages' -prune -o -type f -name '*.plist' -print)
printf '%s\n' "$CURRENT_VERSION" > "$RECOVERY_DIR/PREVIOUS_VERSION"
printf '%s\n' "$VERSION" > "$RECOVERY_DIR/NEXT_VERSION"
touch "$RECOVERY_DIR/ACTIVE"
trap pm_on_exit EXIT

printf '%s\n' "$VERSION" > "$VERSION_FILE"
APP_VERSION="${VERSION%t}"

# Stamp the actual Logos source before invoking Theos so runtime diagnostics
# carry the same version as the Debian package and standalone app.
python3 - "$VERSION" <<'PYTWEAK'
import re, sys
from pathlib import Path
version = sys.argv[1]
p = Path("Tweak.x")
text = p.read_text(encoding="utf-8")
pattern = r'(?m)^#define PM_BUILD_VERSION @"[^"]+"$'
text2, count = re.subn(pattern, f'#define PM_BUILD_VERSION @"{version}"', text)
assert count == 1, f"Expected one PM_BUILD_VERSION marker in Tweak.x, found {count}"
p.write_text(text2, encoding="utf-8")
print(f"Stamped Tweak.x runtime version: {version}")
PYTWEAK

python3 - "$VERSION" "$APP_VERSION" <<'PY'
import plistlib, re, sys
from pathlib import Path
version, app_version = sys.argv[1:3]

def stamp_obj(obj):
    if isinstance(obj, dict):
        return {k: stamp_obj(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [stamp_obj(v) for v in obj]
    if isinstance(obj, str):
        return re.sub(r'\b\d+\.\d+\.\d+t\b', version, obj)
    return obj

for p in Path('.').rglob('*.plist'):
    if '.theos' in p.parts or 'packages' in p.parts or '.build-recovery' in p.parts:
        continue
    with p.open('rb') as f:
        obj = plistlib.load(f)
    obj = stamp_obj(obj)
    if p.as_posix().endswith('ControlApp/Resources/Info.plist'):
        # iOS bundle versions must be numeric, while the Debian package suffix is 't'.
        obj['CFBundleVersion'] = app_version
        obj['CFBundleShortVersionString'] = app_version
    with p.open('wb') as f:
        plistlib.dump(obj, f, fmt=plistlib.FMT_XML, sort_keys=False)

# Only update the Debian Version field and current-version note. Rewriting every
# version-shaped string would corrupt historical release notes and source comments.
control_path = Path("control")
control_text = control_path.read_text(encoding="utf-8")
control_text, control_count = re.subn(r"(?m)^Version:\s*.*$", f"Version: {version}", control_text)
assert control_count == 1, f"Expected one Version field in control, found {control_count}"
control_path.write_text(control_text, encoding="utf-8")

readme_path = Path("README-build.txt")
readme_text = readme_path.read_text(encoding="utf-8")
readme_text, readme_count = re.subn(
    r"(?m)^Current source package version:.*$",
    f"Current source package version: {version} (stamped in Tweak.x during this build).",
    readme_text,
)
if readme_count == 0:
    readme_text += f"\nCurrent source package version: {version} (stamped in Tweak.x during this build).\n"
readme_path.write_text(readme_text, encoding="utf-8")
print(f"Building ProMotion Control package {version} (iOS app version {app_version})")
PY
if ! grep -Fq "#define PM_BUILD_VERSION @\"$VERSION\"" Tweak.x; then
    echo "ERROR: Tweak.x runtime version does not match package VERSION=$VERSION" >&2
    exit 1
fi

# Preserve non-package files; remove only old .deb outputs so they cannot be
# mistaken for the artifact from this build.
mkdir -p packages
find packages -maxdepth 1 -type f -name "*${VERSION}*.deb" -delete

# Memory-conscious WSL mode: preserve incremental objects by default.
# Set CLEAN_OBJECTS=1 only when intentionally rebuilding from scratch.
if [[ "${CLEAN_OBJECTS:-0}" == "1" ]]; then
    echo "CLEAN_OBJECTS=1: removing generated objects"
    rm -rf .theos/obj
else
    echo "Keeping existing build objects for incremental, lower-memory builds."
fi

# Avoid the broken aggregate clean target by default. Opt in only when required.
if [[ "${CLEAN_BEFORE_BUILD:-0}" == "1" ]]; then
    echo "CLEAN_BEFORE_BUILD=1: running explicit clean"
    "$MAKE_BIN" -j1 clean
else
    echo "Skipping make clean to avoid the ControlApp rm -rf empty-target failure."
fi

# WSL_LOW_MEMORY_BUILD: serial make + no debug symbols; avoid full clean by default.
BUILD_LOG="${BUILD_LOG:-$PWD/build-last.log}"
# Use one job and avoid make -B, which needlessly forces every target to rebuild.
MAKEFLAGS=-j1 "$MAKE_BIN" -j1 DEBUG=0 package FINALPACKAGE=1 2>&1 | tee "$BUILD_LOG"

printf '\nBuilt packages:\n'
shopt -s nullglob
packages=(packages/*"$VERSION"*.deb)
if ((${#packages[@]} == 0)); then
    echo "Build finished without producing a .deb package." >&2
    exit 1
fi
for deb in "${packages[@]}"; do
    printf '%s\n' "$deb"
    if command -v dpkg-deb >/dev/null; then
        package_version="$(dpkg-deb -f "$deb" Package Version Architecture)"
        printf '%s\n' "$package_version"
        if ! dpkg-deb --info "$deb" >/dev/null; then
            echo "Invalid Debian package: $deb" >&2
            exit 1
        fi
        if [[ "$package_version" != *"$VERSION"* ]]; then
            echo "Package metadata version does not match $VERSION: $deb" >&2
            exit 1
        fi
        tmp_verify="$(mktemp -d)"
        PM_VERIFY_TMP="$tmp_verify"
        dpkg-deb -x "$deb" "$tmp_verify/root"
        dpkg-deb -e "$deb" "$tmp_verify/control"
        app_dir="$(find "$tmp_verify/root" -type d -path '*/Applications/ProMotionControl.app' -print -quit)"
        if [[ -z "$app_dir" ]]; then
            echo "Standalone app bundle missing from package: $deb" >&2
            echo "This package is not safe to install; expected ProMotionControl.app." >&2
            exit 1
        fi
        if find "$tmp_verify/root" -iname '*ProMotionControlPrefs*' -print -quit | grep -q .; then
            echo "Unexpected legacy Preferences bundle found in package: $deb" >&2
            exit 1
        fi
        tweak_dylib="$(find "$tmp_verify/root" -type f -name 'ProMotionControl.dylib' -print -quit)"
        if [[ -z "$tweak_dylib" ]]; then
            echo "Compiled ProMotionControl.dylib is missing from package: $deb" >&2
            exit 1
        fi
        if ! grep -aFq "$VERSION" "$tweak_dylib"; then
            echo "Compiled tweak does not contain stamped build version $VERSION: $tweak_dylib" >&2
            exit 1
        fi
        if ! grep -aFq "PMControlTweakRuntimeMarker" "$tweak_dylib"; then
            echo "Compiled tweak is missing the Premium runtime-presence marker: $tweak_dylib" >&2
            exit 1
        fi
        if ! grep -aFq "PMControlTweakInstallationID" "$tweak_dylib"; then
            echo "Compiled tweak is missing the per-install Premium identity export: $tweak_dylib" >&2
            exit 1
        fi
        python3 - "$app_dir" "$tmp_verify/control" <<'PYVERIFY'
import os, plistlib, re, sys
from pathlib import Path
app = Path(sys.argv[1])
control = Path(sys.argv[2])
info_path = app / "Info.plist"
exe = app / "ProMotionControlApp"
assert info_path.is_file(), f"Missing app Info.plist: {info_path}"
assert exe.is_file() and os.access(exe, os.X_OK), f"Missing/non-executable app binary: {exe}"
assert b"PMControlTweakRuntimeMarker" in exe.read_bytes(), "App binary missing tweak-presence lookup"
assert b"PMControlTweakInstallationID" in exe.read_bytes(), "App binary missing tweak-install identity lookup"
assert not (app / "ProMotionControlApp.dpkg-tmp").exists(), "Temporary dpkg executable found in app bundle"
with info_path.open("rb") as f:
    info = plistlib.load(f)
assert info.get("CFBundleIdentifier") == "com.dell.promotioncontrol.app", "Wrong app bundle ID"
assert info.get("CFBundleExecutable") == "ProMotionControlApp", "Wrong executable key"
assert info.get("CFBundlePackageType") == "APPL", "Wrong bundle package type"
assert info.get("CFBundleDisplayName") == "ProMotion Control", "Wrong app display name"
assert re.fullmatch(r"[0-9]+(\.[0-9]+){0,2}", str(info.get("CFBundleVersion", ""))), "CFBundleVersion must be numeric"
assert re.fullmatch(r"[0-9]+(\.[0-9]+){0,2}", str(info.get("CFBundleShortVersionString", ""))), "CFBundleShortVersionString must be numeric"
expected_icons = {
    "AppIcon60x60@2x.png": (120, 120),
    "AppIcon60x60@3x.png": (180, 180),
    "AppIcon76x76@2x.png": (152, 152),
}
for name, expected_size in expected_icons.items():
    icon = app / name
    assert icon.is_file() and icon.stat().st_size > 0, f"Missing app icon: {icon}"
    with icon.open("rb") as f:
        header = f.read(24)
    assert header[:8] == b"\x89PNG\r\n\x1a\n", f"App icon isn't a PNG: {name}"
    width = int.from_bytes(header[16:20], "big")
    height = int.from_bytes(header[20:24], "big")
    assert (width, height) == expected_size, f"Unexpected dimensions for {name}: {(width, height)}"
postinst = control / "postinst"
assert postinst.is_file() and os.access(postinst, os.X_OK), "Missing executable package postinst"
assert "uicache" in postinst.read_text(errors="replace"), "postinst doesn't register app icon"
assert ".com.dell.promotioncontrol.installation-id" in postinst.read_text(errors="replace"), "postinst doesn't create install identity"
postrm = control / "postrm"
assert postrm.is_file() and os.access(postrm, os.X_OK), "Missing executable package postrm"
postinst_text = postinst.read_text(errors="replace")
postrm_text = postrm.read_text(errors="replace")
assert "pm-backup-owned" in postinst_text and "pm-created" in postinst_text, "postinst missing Filza backup ownership tracking"
assert "pm-backup-owned" in postrm_text and "pm-created" in postrm_text, "postrm missing safe Filza restore/remove lifecycle"
print("Verified standalone app bundle, numeric iOS bundle version, icons, uicache and Filza backup/restore scripts.")
PYVERIFY
        rm -rf "$tmp_verify"
        PM_VERIFY_TMP=""
    fi
done

# Commit only after all checks pass. Keep old package files in the same folder
# for manual rollback; current build artifacts are the ones containing $VERSION.
rm -rf "$RECOVERY_DIR"
trap - EXIT
