#!/usr/bin/env bash
# Builds and runs a genuine MetalANGLE/GLES probe in an isolated iOS Simulator.
# Requires a cloud macOS runner with Xcode and a downloaded simulator runtime.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
renpy_build=""
output="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/aether-renpy-ios-egl-probe"
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
app="$output/AetherRenPyEGLProbe.app"
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
<key>CFBundleIdentifier</key><string>org.aetherkiri.renpy-egl-probe</string>
<key>CFBundleExecutable</key><string>AetherRenPyEGLProbe</string>
<key>CFBundleName</key><string>Aether RenPy EGL Probe</string>
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
    -Wall -Wextra -Werror -I"$framework/Headers" \
    -c "$repo_root/tools/renpy_ios_egl_probe/egl_probe.c" -o "$output/egl_probe.o"
xcrun --sdk iphonesimulator clang -target "$arch-apple-ios15.0-simulator" -isysroot "$sdk" \
    -Wall -Wextra -Werror -Wno-deprecated-declarations -fobjc-arc \
    -I"$framework/Headers" -F"$(dirname "$framework")" \
    "$repo_root/tools/renpy_ios_egl_probe/main.m" "$output/egl_probe.o" \
    -framework MetalANGLE -framework UIKit -framework Foundation -framework QuartzCore \
    -Wl,-rpath,@executable_path/Frameworks -o "$app/AetherRenPyEGLProbe"
codesign --force --sign - "$app"
xcrun otool -L "$app/AetherRenPyEGLProbe" > "$output/evidence/app-linked-libraries.txt"
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
udid="$(xcrun simctl create "Aether RenPy EGL probe ${GITHUB_RUN_ID:-$$}" "$device_type" "$runtime")"
cleanup() {
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$udid" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app"
xcrun simctl launch --terminate-running-process "$udid" org.aetherkiri.renpy-egl-probe | tee "$output/evidence/simulator-launch.txt"
container="$(xcrun simctl get_app_container "$udid" org.aetherkiri.renpy-egl-probe data)"
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
report = json.loads(pathlib.Path(sys.argv[1]).read_text())
print(json.dumps(report, indent=2))
required = ('passed', 'pbuffer_created', 'readback_verified', 'host_context_restored', 'resume_verified', 'no_extra_uiwindow')
if not all(report.get(k) for k in required):
    raise SystemExit('Actual iOS EGL/GLES probe failed; this is not gameplay acceptance.')
print('Actual iOS EGL/GLES pbuffer probe passed; Ren\'Py gameplay remains unverified.')
PY
