#!/usr/bin/env bash
# Compile actual UIKit SDL2 and exercise its Apple GL lookup beside MetalANGLE.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
renpy_build=""
host_sdl=""
output="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/aether-renpy-ios-host-gl-probe"
while (($#)); do
    case "$1" in
        --renpy-build) renpy_build="$2"; shift 2 ;;
        --host-sdl-source) host_sdl="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) echo "Usage: $0 --renpy-build PATH --host-sdl-source PATH [--output PATH]" >&2; exit 2 ;;
    esac
done
[[ "$(uname -s)" == Darwin ]] || { echo 'Actual UIKit/Apple GLES requires macOS/Xcode; no substitute API is used.' >&2; exit 2; }
[[ "$(git -C "$host_sdl" rev-parse HEAD)" == 5d249570393f7a37e037abf22cd6012a4cc56a71 ]] || {
    echo 'Expected the actual SDL2.32.10 release commit used by the host port.' >&2; exit 1;
}
archive="$renpy_build/source/MetalANGLE.framework.ios.simulator.zip"
[[ -f "$archive" ]] || { echo "Missing actual simulator MetalANGLE framework: $archive" >&2; exit 1; }
mkdir -p "$output/input" "$output/evidence"
unzip -q -o "$archive" -d "$output/input"
framework="$output/input/MetalANGLE.framework"
arch="$(uname -m)"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun lipo "$framework/MetalANGLE" -verify_arch "$arch"
xcodebuild -version > "$output/evidence/xcode-version.txt"
printf '%s\n' "$sdk" > "$output/evidence/sdk-path.txt"
shasum -a 256 "$archive" > "$output/evidence/framework-archive.sha256"
git -C "$host_sdl" rev-parse HEAD > "$output/evidence/host-sdl-source-sha.txt"
[[ ! -e "$output/host-sdl-source" ]] || { echo 'Use a fresh output directory for this actual source build.' >&2; exit 1; }
cp -R "$host_sdl" "$output/host-sdl-source"
python3 - "$repo_root" "$output" <<'PY'
import pathlib, re, subprocess, sys
repo, out = map(pathlib.Path, sys.argv[1:])
port = repo/'vcpkg/ports/sdl2'
source = out/'host-sdl-source'
section = (port/'portfile.cmake').read_text().split('    PATCHES\n', 1)[1].split('\n)', 1)[0]
names = re.findall(r'^\s+([\w.-]+\.(?:patch|diff))\s*$', section, re.M)
if 'aetherkiri-ios-opengles-isolation.patch' not in names:
    raise SystemExit('Host port does not apply the actual Apple GLES isolation patch')
evidence = out/'evidence/applied-host-sdl-patches'; evidence.mkdir()
for name in names:
    patch = port/name
    subprocess.run(['git', 'apply', '--check', str(patch)], cwd=source, check=True)
    subprocess.run(['git', 'apply', str(patch)], cwd=source, check=True)
    (evidence/name).write_bytes(patch.read_bytes())
    print('Applied actual host SDL port patch:', name)
PY
if ! cmake -S "$output/host-sdl-source" -B "$output/host-sdl-build" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$output/host-sdl-install" \
    -DSDL_STATIC=ON -DSDL_SHARED=OFF -DSDL_TEST=OFF -DSDL_TESTS=OFF \
    -DSDL_VULKAN=OFF -DSDL_METAL=OFF -DSDL_RENDER_METAL=OFF \
    -DSDL_HIDAPI=OFF -DSDL_JOYSTICK=OFF -DSDL_SENSOR=OFF -DSDL_HAPTIC=OFF -DSDL_POWER=OFF \
    > "$output/evidence/host-sdl-configure.log" 2>&1; then
    tail -100 "$output/evidence/host-sdl-configure.log" >&2; exit 1
fi
if ! cmake --build "$output/host-sdl-build" --parallel "$(sysctl -n hw.ncpu)" \
    > "$output/evidence/host-sdl-build.log" 2>&1; then
    tail -100 "$output/evidence/host-sdl-build.log" >&2; exit 1
fi
cmake --install "$output/host-sdl-build" > "$output/evidence/host-sdl-install.log" 2>&1
library="$output/host-sdl-install/lib/libSDL2.a"
[[ -f "$library" ]] || { echo 'Actual host SDL static archive is missing.' >&2; exit 1; }
config="$output/host-sdl-install/include/SDL2/SDL_config.h"
cp "$config" "$output/evidence/SDL_config.h"
grep '^#define SDL_VIDEO_DRIVER_UIKIT 1' "$config"
grep '^#define SDL_VIDEO_OPENGL_ES2 1' "$config"
xcrun nm -a "$library" > "$output/evidence/host-sdl-symbols.txt"
grep '_UIKit_GL_UnloadLibrary' "$output/evidence/host-sdl-symbols.txt"
app="$output/AetherRenPyHostGLProbe.app"
mkdir -p "$app/Frameworks"
cp -R "$framework" "$app/Frameworks/"
embedded="$app/Frameworks/MetalANGLE.framework"
if [[ "$(xcrun lipo "$embedded/MetalANGLE" -archs)" == *" "* ]]; then
    xcrun lipo "$embedded/MetalANGLE" -thin "$arch" -output "$output/MetalANGLE.thin"
    mv "$output/MetalANGLE.thin" "$embedded/MetalANGLE"
fi
codesign --force --sign - "$embedded"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.aetherkiri.renpy-host-gl-probe</string>
<key>CFBundleExecutable</key><string>AetherRenPyHostGLProbe</string>
<key>CFBundleName</key><string>Aether RenPy Host GL Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneSimulator</string></array>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>MinimumOSVersion</key><string>15.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
<key>UILaunchScreen</key><dict/>
<key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
</dict></plist>
PLIST
xcrun --sdk iphonesimulator clang -target "$arch-apple-ios15.0-simulator" -isysroot "$sdk" \
    -Wall -Wextra -Werror -I"$framework/Headers" \
    -c "$repo_root/tools/renpy_ios_egl_probe/egl_probe.c" -o "$output/egl_probe.o"
# Intentionally load both GL implementations in this process. Host SDL must
# select Apple by its concrete handle even though global GLES symbols coexist.
xcrun --sdk iphonesimulator clang -target "$arch-apple-ios15.0-simulator" -isysroot "$sdk" \
    -Wall -Wextra -Werror -Wno-deprecated-declarations -fobjc-arc \
    -I"$output/host-sdl-install/include/SDL2" -F"$(dirname "$framework")" \
    "$repo_root/tools/renpy_ios_egl_probe/host_gl_probe.m" "$output/egl_probe.o" "$library" \
    -framework MetalANGLE -framework OpenGLES -framework UIKit -framework Foundation \
    -framework CoreGraphics -framework CoreVideo -framework QuartzCore -framework CoreFoundation \
    -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework CoreMotion \
    -framework GameController -framework CoreHaptics -framework Metal -framework MetalKit -liconv \
    -Wl,-rpath,@executable_path/Frameworks -o "$app/AetherRenPyHostGLProbe"
codesign --force --sign - "$app"
xcrun otool -L "$app/AetherRenPyHostGLProbe" > "$output/evidence/app-linked-libraries.txt"
xcrun simctl list runtimes --json > "$output/evidence/simulator-runtimes.json"
xcrun simctl list devicetypes --json > "$output/evidence/simulator-device-types.json"
read -r runtime device_type < <(python3 - "$output/evidence" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
available = [r for r in json.loads((p/'simulator-runtimes.json').read_text())['runtimes']
             if r.get('isAvailable') and '.iOS-' in r['identifier']]
if not available:
    raise SystemExit('The cloud runner has no actual iOS Simulator runtime')
runtime = max(available, key=lambda r: tuple(int(i) for i in r['version'].split('.')))
devices = json.loads((p/'simulator-device-types.json').read_text())['devicetypes']
for name in ('iPhone 13', 'iPhone 14', 'iPhone 15', 'iPhone 16'):
    device = next((d for d in devices if d['name'] == name), None)
    if device:
        print(runtime['identifier'], device['identifier']); break
else:
    raise SystemExit('No supported iPhone Simulator device type')
PY
)
udid="$(xcrun simctl create "Aether RenPy host GL probe ${GITHUB_RUN_ID:-$$}" "$device_type" "$runtime")"
cleanup() {
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app"
xcrun simctl launch --terminate-running-process "$udid" org.aetherkiri.renpy-host-gl-probe | tee "$output/evidence/simulator-launch.txt"
container="$(xcrun simctl get_app_container "$udid" org.aetherkiri.renpy-host-gl-probe data)"
for ((attempt=0; attempt<90; ++attempt)); do
    if [[ -f "$container/Documents/host-gl-probe.json" ]]; then break; fi
    sleep 1
done
if [[ ! -f "$container/Documents/host-gl-probe.json" ]]; then
    xcrun simctl spawn "$udid" log show --last 3m --style compact > "$output/evidence/simulator-system.log" 2>&1 || true
    echo 'Actual UIKit/GL probe produced no report; inspect its crash/dyld/Metal evidence.' >&2; exit 1
fi
cp "$container/Documents/host-gl-probe."* "$output/evidence/"
xcrun simctl io "$udid" screenshot "$output/evidence/simulator-screen.png"
python3 - "$output/evidence/host-gl-probe.json" <<'PY'
import json, pathlib, sys
report = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(json.dumps(report, indent=2))
required = ('passed', 'apple_provenance_verified', 'apple_readback_verified',
            'metalangle_readback_verified', 'apple_context_preserved', 'apple_pixels_preserved',
            'apple_resume_verified', 'load_unload_verified', 'video_reinitialization_verified', 'no_extra_uiwindow')
if not all(report.get(k) for k in required):
    raise SystemExit('Actual UIKit SDL / Apple GLES / MetalANGLE isolation failed')
if report.get('sdl_version') != '2.32.10':
    raise SystemExit('Probe did not use the actual host SDL2.32.10')
if report.get('apple_gles_client_version') != 3 or report.get('metalangle_gles_client_version') != 3:
    raise SystemExit('Probe did not render with both actual Apple and MetalANGLE GLES3 contexts')
print('Actual UIKit SDL selects Apple GLES; independent real GPU pixels and GL lifecycle passed. RenPy gameplay remains unverified.')
PY
