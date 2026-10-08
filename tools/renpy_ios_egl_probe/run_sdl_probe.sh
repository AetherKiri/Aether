#!/usr/bin/env bash
# Builds patched upstream SDL2, then runs its real offscreen EGL/GLES path in iOS Simulator.
# Requires a cloud macOS runner with Xcode and a downloaded simulator runtime.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
renpy_build=""
output="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/aether-renpy-ios-sdl-probe"
framework=""
while (($#)); do
    case "$1" in
        --renpy-build) renpy_build="$2"; shift 2 ;;
        --framework) framework="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) echo "Usage: $0 --renpy-build PATH [--framework PATH] [--output PATH]" >&2; exit 2 ;;
    esac
done
[[ "$(uname -s)" == Darwin ]] || { echo 'This real iOS Simulator probe requires macOS/Xcode; no simulation fallback is provided.' >&2; exit 2; }
mkdir -p "$output/input" "$output/evidence"
if [[ -z "$framework" ]]; then
    archive="$renpy_build/source/MetalANGLE.framework.ios.simulator.zip"
    [[ -f "$archive" ]] || { echo "Missing pinned Ren'Py simulator framework: $archive" >&2; exit 1; }
    unzip -q -o "$archive" -d "$output/input"
    framework="$output/input/MetalANGLE.framework"
    shasum -a 256 "$archive" > "$output/evidence/framework-archive.sha256"
fi
[[ -f "$framework/MetalANGLE" ]] || { echo "Invalid MetalANGLE framework: $framework" >&2; exit 1; }
arch="$(uname -m)"
xcrun lipo "$framework/MetalANGLE" -verify_arch "$arch"
xcrun lipo "$framework/MetalANGLE" -archs > "$output/evidence/framework-architectures.txt"
xcodebuild -version > "$output/evidence/xcode-version.txt"
xcrun --sdk iphonesimulator --show-sdk-path > "$output/evidence/sdk-path.txt"
# Build the actual SDL source used by Ren'Py, with every upstream patch and
# both real mobile offscreen patches. No framework or SDL API is simulated.
[[ -f "$renpy_build/source/SDL2-2.0.20.tar.gz" ]] || { echo 'Missing pinned SDL2 source archive.' >&2; exit 1; }
command -v autoconf >/dev/null || { echo 'The cloud runner needs autoconf to regenerate the patched SDL configure.' >&2; exit 1; }
mkdir -p "$output/sdl-source" "$output/sdl-build" "$output/sdl-install"
tar xzf "$renpy_build/source/SDL2-2.0.20.tar.gz" -C "$output/sdl-source"
python3 - "$repo_root" "$renpy_build" "$output" <<'PY'
import pathlib, subprocess, sys
repo, upstream, out = map(pathlib.Path, sys.argv[1:])
patches = {p.name: p.read_bytes() for p in (upstream/'patches/SDL2-2.0.20').iterdir()
           if p.suffix in ('.diff', '.patch')}
# Extract the real new SDL patches from the reviewable renpy-build patches.
# They add files; reject edits to existing files instead of approximating them.
for name in ('0004-android-offscreen-renderer.patch', '0006-ios-offscreen-renderer.patch'):
    lines = (repo/'bridge/renpy_runtime/mobile_launcher/patches/native'/name).read_text().splitlines(True)
    for start, line in enumerate(lines):
        if not line.startswith('diff --git a/patches/SDL2-2.0.20/'):
            continue
        end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith('diff --git ')), len(lines))
        section = lines[start:end]
        if 'new file mode 100644\n' not in section:
            raise SystemExit('Expected a real added SDL patch file: ' + name)
        filename = line.split()[3].removeprefix('b/patches/SDL2-2.0.20/')
        # Outer +++ metadata precedes its first hunk. Inside that hunk every
        # added line belongs to the new patch, including nested +++ headers.
        # Dropping those headers happens to work with GNU patch's git-name
        # inference but BSD patch cannot create the new Objective-C file.
        first_hunk = next(i for i, l in enumerate(section) if l.startswith('@@ '))
        body = ''.join(l[1:] for l in section[first_hunk + 1:] if l.startswith('+'))
        patches[filename] = body.encode()
evidence = out/'evidence/applied-sdl-patches'; evidence.mkdir(exist_ok=True)
for name, body in sorted(patches.items()):
    (evidence/name).write_bytes(body)
    p = subprocess.run(['patch', '--batch', '-p1'], input=body,
                       cwd=out/'sdl-source/SDL2-2.0.20', stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if p.returncode:
        sys.stderr.buffer.write(p.stdout)
        raise SystemExit('Actual upstream SDL patch failed: ' + name)
print('Applied every pinned upstream SDL patch plus mobile EGL pbuffer patches.')
PY
sdl_source="$output/sdl-source/SDL2-2.0.20"
if ! (cd "$sdl_source" && ./autogen.sh) > "$output/evidence/sdl-autogen.log" 2>&1; then
    tail -80 "$output/evidence/sdl-autogen.log" >&2
    exit 1
fi
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
if [[ "$arch" == arm64 ]]; then sdl_host=arm-ios-darwin21; else sdl_host=x86_64-ios-darwin21; fi
if ! (
    set -e
    cd "$output/sdl-build"
    CC="$(xcrun --sdk iphonesimulator --find clang)" \
    CFLAGS="-target $arch-apple-ios15.0-simulator -isysroot $sdk -O1 -fobjc-arc -DSDL_MAIN_HANDLED -DMETALANGLE -I$framework/Headers -F$(dirname "$framework")" \
    CPPFLAGS="-I$framework/Headers -DMETALANGLE" \
    LDFLAGS="-target $arch-apple-ios15.0-simulator -isysroot $sdk -F$(dirname "$framework") -framework MetalANGLE" \
    ac_cv_header_libunwind_h=no \
    "$sdl_source/configure" --host="$sdl_host" --disable-shared --prefix="$output/sdl-install" \
        --enable-video-offscreen --disable-video-x11 --disable-video-wayland \
        --disable-render-metal --disable-video-vulkan --disable-video-kmsdrm \
        --disable-hidapi --disable-joystick --disable-sensor --disable-power --disable-haptic || exit $?
    make -j"$(sysctl -n hw.ncpu)" || exit $?
    make install || exit $?
) > "$output/evidence/sdl-build.log" 2>&1; then
    tail -100 "$output/evidence/sdl-build.log" >&2
    exit 1
fi
cp "$output/sdl-build/include/SDL_config.h" "$output/evidence/SDL_config.h"
grep '^#define SDL_VIDEO_OPENGL_EGL 1' "$output/evidence/SDL_config.h"
grep '^#define SDL_VIDEO_DRIVER_OFFSCREEN 1' "$output/evidence/SDL_config.h"
if grep '^#define SDL_VIDEO_DRIVER_UIKIT 1' "$output/evidence/SDL_config.h"; then
    echo 'Embedded SDL must not compile its process-global UIKit classes.' >&2
    exit 1
fi
xcrun nm -a "$output/sdl-install/lib/libSDL2.a" > "$output/evidence/sdl-symbols.txt"
python3 - "$output/evidence/sdl-symbols.txt" <<'PY'
import pathlib, re, sys
symbols = pathlib.Path(sys.argv[1]).read_text()
collisions = re.findall(r'OBJC_CLASS_\$_SDL\w+\b', symbols)
if collisions:
    raise SystemExit('RenPy SDL still defines host-conflicting Objective-C classes: ' + ', '.join(sorted(set(collisions))))
if 'OBJC_CLASS_$_AetherRenpySDLInterruptionListener' not in symbols:
    raise SystemExit('Expected the real retained CoreAudio implementation with its isolated Objective-C listener.')
print('Actual SDL archive excludes UIKit classes and preserves renamed CoreAudio listener.')
PY
xcrun lipo "$output/sdl-install/lib/libSDL2.a" -archs > "$output/evidence/sdl-architectures.txt"
app="$output/AetherRenPySDLProbe.app"
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
<key>CFBundleIdentifier</key><string>org.aetherkiri.renpy-sdl-probe</string>
<key>CFBundleExecutable</key><string>AetherRenPySDLProbe</string>
<key>CFBundleName</key><string>Aether RenPy SDL Probe</string>
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
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator clang -target "$arch-apple-ios15.0-simulator" -isysroot "$sdk" \
    -Wall -Wextra -Werror -I"$framework/Headers" -I"$output/sdl-install/include/SDL2" \
    -c "$repo_root/tools/renpy_ios_egl_probe/sdl_probe.c" -o "$output/egl_probe.o"
xcrun --sdk iphonesimulator clang -target "$arch-apple-ios15.0-simulator" -isysroot "$sdk" \
    -Wall -Wextra -Werror -Wno-deprecated-declarations -fobjc-arc \
    -I"$framework/Headers" -F"$(dirname "$framework")" \
    "$repo_root/tools/renpy_ios_egl_probe/main.m" "$output/egl_probe.o" "$output/sdl-install/lib/libSDL2.a" \
    -framework MetalANGLE -framework UIKit -framework Foundation -framework QuartzCore \
    -framework CoreFoundation -framework CoreAudio -framework AudioToolbox -framework AVFoundation \
    -framework CoreGraphics -framework CoreMotion -framework GameController -framework Metal -framework OpenGLES -liconv \
    -Wl,-rpath,@executable_path/Frameworks -o "$app/AetherRenPySDLProbe"
codesign --force --sign - "$app"
xcrun otool -L "$app/AetherRenPySDLProbe" > "$output/evidence/app-linked-libraries.txt"
xcrun simctl list runtimes --json > "$output/evidence/simulator-runtimes.json"
xcrun simctl list devicetypes --json > "$output/evidence/simulator-device-types.json"
read -r runtime device_type < <(python3 - "$output/evidence" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
available = [r for r in json.loads((p/'simulator-runtimes.json').read_text())['runtimes']
             if r.get('isAvailable') and '.iOS-' in r['identifier']]
if not available:
    raise SystemExit('No available iOS Simulator runtime; install one with Xcode on this cloud runner.')
runtime = max(available, key=lambda r: tuple(int(i) for i in r['version'].split('.')))
devices = json.loads((p/'simulator-device-types.json').read_text())['devicetypes']
for name in ('iPhone 13', 'iPhone 14', 'iPhone 15', 'iPhone 16'):
    device = next((d for d in devices if d['name'] == name), None)
    if device:
        print(runtime['identifier'], device['identifier'])
        break
else:
    raise SystemExit('No supported recent iPhone Simulator device type was found.')
PY
)
udid="$(xcrun simctl create "Aether RenPy SDL probe ${GITHUB_RUN_ID:-$$}" "$device_type" "$runtime")"
cleanup() {
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app"
xcrun simctl launch --terminate-running-process "$udid" org.aetherkiri.renpy-sdl-probe | tee "$output/evidence/simulator-launch.txt"
container="$(xcrun simctl get_app_container "$udid" org.aetherkiri.renpy-sdl-probe data)"
for ((attempt=0; attempt<90; ++attempt)); do
    if [[ -f "$container/Documents/egl-probe.json" ]]; then break; fi
    sleep 1
done
if [[ ! -f "$container/Documents/egl-probe.json" ]]; then
    xcrun simctl spawn "$udid" log show --last 3m --style compact > "$output/evidence/simulator-system.log" 2>&1 || true
    echo 'Probe did not produce a report; inspect launch/system logs for dyld or Metal failures.' >&2
    exit 1
fi
cp "$container/Documents/egl-probe."* "$output/evidence/"
xcrun simctl io "$udid" screenshot "$output/evidence/simulator-screen.png"
python3 - "$output/evidence/egl-probe.json" <<'PY'
import json, pathlib, sys
report_path = pathlib.Path(sys.argv[1])
report = json.loads(report_path.read_text())
report['probe'] = 'patched SDL2.0.20 offscreen MetalANGLE EGL pbuffer'
report['source_version'] = 'SDL2.0.20'
report['assertions'] = ['SDL_Init video driver=offscreen', 'SDL_CreateWindow EGL pbuffer',
                        'SDL_GL_CreateContext', 'actual GLES pixels', 'host context preserved',
                        'resume produces new pixels', 'SDL pointer down/up and UTF-8 text delivery',
                        'no additional UIWindow']
report_path.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
required = ('passed', 'pbuffer_created', 'readback_verified', 'host_context_restored', 'resume_verified', 'no_extra_uiwindow')
if not all(report.get(k) for k in required):
    raise SystemExit('Actual iOS EGL/GLES probe failed; this is not gameplay acceptance.')
print('Actual patched SDL iOS offscreen/GLES, pointer and UTF-8 event probe passed; Ren\'Py gameplay remains unverified.')
PY
