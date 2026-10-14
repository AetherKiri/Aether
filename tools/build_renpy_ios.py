#!/usr/bin/env python3
"""Build the native Ren'Py iOS framework and its optional UIKit integration test.

Inputs are the unmodified official 8.5.3 SDK/Renios ZIP, greenlet 3.5.6 source,
and matching CPython 3.12.8 headers/config. All modifications happen in output.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import zipfile

REPO = Path(__file__).resolve().parents[1]
LIBRARIES = ("renpython", "renpy", "python3.12", "assimp", "avformat", "avcodec",
             "swscale", "swresample", "avutil", "SDL2_image", "SDL2", "avif", "aom",
             "yuv", "turbojpeg", "png16", "webp", "sharpyuv", "harfbuzz", "brotlidec",
             "brotlicommon", "fribidi", "freetype", "ffi", "ssl", "crypto", "lzma", "bz2", "z")
SDL_ADAPTER_SYMBOLS = ("CreateWindow", "GL_CreateContext", "DestroyWindow", "GetWindowFlags",
                       "GetWindowSize", "GetKeyboardFocus", "ShowWindow", "RaiseWindow",
                       "SetWindowSize", "SetWindowFullscreen", "GL_GetProcAddress")
FRAMEWORKS = ("MetalANGLE", "UIKit", "Foundation", "CoreMotion", "GameController",
              "AVFoundation", "AudioToolbox", "CoreAudio", "CoreGraphics", "CoreVideo",
              "OpenGLES", "QuartzCore", "Security", "SystemConfiguration", "Metal", "StoreKit")


def run(command):
    subprocess.run(list(map(str, command)), check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--renios", type=Path, required=True)
    parser.add_argument("--greenlet-source", type=Path, required=True)
    parser.add_argument("--python-include", type=Path, required=True)
    parser.add_argument("--python-config", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", action="store_true")
    parser.add_argument("--arch", choices=("arm64", "x86_64"), default="arm64")
    parser.add_argument("--smoke-app", action="store_true")
    args = parser.parse_args()
    if args.device and args.arch != "arm64":
        parser.error("iOS devices require arm64")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    sdk = args.sdk.resolve()
    if "8.5.3.26051504" not in (sdk / "renpy/vc_version.py").read_text():
        parser.error("Use the matching Ren'Py 8.5.3 SDK")
    spec = importlib.util.spec_from_file_location("renpy_copy", REPO / "apps/godot_app/renpy_runtime/host.py")
    copy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(copy)
    def clone(source, target):
        copy.copy_file(Path(source), Path(target))
        return target
    libraries = output / "link-inputs"
    libraries.mkdir(exist_ok=True)
    platform = "release" if args.device else "debug"
    with zipfile.ZipFile(args.renios) as archive:
        for name in LIBRARIES:
            original = output / ("lib" + name + ".fat.a")
            original.write_bytes(archive.read(f"renios/prototype/prebuilt/{platform}/lib{name}.a"))
            target = libraries / ("lib" + name + ".a")
            # Official release archives are thin; simulator archives are fat.
            archs = subprocess.check_output(["xcrun", "lipo", "-archs", str(original)], text=True).split()
            if len(archs) == 1:
                if archs != [args.arch]:
                    parser.error(f"Wrong architecture in {name}: {archs}")
                original.replace(target)
            else:
                run(["xcrun", "lipo", "-thin", args.arch, original, "-output", target])
                original.unlink()
            if name == "SDL2":
                data = target.read_bytes()
                for symbol in set(re.findall(rb"_OBJC_CLASS_\$_(SDL\w+)", data)):
                    data = data.replace(symbol + b"\0", b"RNP" + symbol[3:] + b"\0")
                for symbol in SDL_ADAPTER_SYMBOLS:
                    data = data.replace(("_SDL_" + symbol).encode() + b"\0", ("_RNP_" + symbol).encode() + b"\0")
                target.write_bytes(data)
                run(["xcrun", "ranlib", target])
        angle_name = "ios-arm64_armv7" if args.device else "ios-arm64_i386_x86_64-simulator"
        prefix = f"renios/prototype/Frameworks/MetalANGLE.xcframework/{angle_name}/MetalANGLE.framework/"
        angle = output / "Frameworks/MetalANGLE.framework"
        for member in archive.namelist():
            if member.startswith(prefix) and not member.endswith("/"):
                relative = Path(member[len(prefix):])
                if relative.is_absolute() or ".." in relative.parts:
                    raise ValueError("Invalid framework ZIP path")
                target = angle / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(member))
        prototype_sources = {}
        for name in ("Log.m", "VideoPlayer.m", "IAPHelper.m"):
            source = output / name
            source.write_bytes(archive.read("renios/prototype/" + name))
            prototype_sources[name] = source
    target = f"{args.arch}-apple-ios13.0" + ("" if args.device else "-simulator")
    apple_sdk = "iphoneos" if args.device else "iphonesimulator"
    sdkroot = subprocess.check_output(["xcrun", "--sdk", apple_sdk, "--show-sdk-path"], text=True).strip()
    compiler = ["xcrun", "clang++", "-target", target, "-isysroot", sdkroot, "-O2"]
    greenlet = args.greenlet_source.resolve()
    run(compiler + ["-std=c++11", "-fvisibility=hidden", "-I" + str(args.python_include.resolve()),
        "-I" + str(args.python_config.resolve()), "-c", greenlet / "src/greenlet/greenlet.cpp", "-o", output / "greenlet.o"])
    objects = [output / "greenlet.o"]
    for name, source in {"adapter": REPO / "bridge/renpy_runtime/ios_sdl_adapter.mm", **prototype_sources}.items():
        obj = output / (name + ".o")
        run(compiler + ["-fobjc-arc", "-fmodules", "-fmodules-cache-path=" + str(output / "modules"), "-c", source, "-o", obj])
        objects.append(obj)
    framework = output / "Frameworks/AetherRenpy.framework"
    framework.mkdir(parents=True, exist_ok=True)
    (framework / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"org.aether.renpy.runtime",
        "CFBundleName":"AetherRenpy", "CFBundleExecutable":"AetherRenpy", "CFBundlePackageType":"FMWK",
        "CFBundleVersion":"8.5.3", "CFBundleShortVersionString":"8.5.3", "MinimumOSVersion":"13.0",
        "CFBundleSupportedPlatforms":["iPhoneOS" if args.device else "iPhoneSimulator"]}))
    link = compiler + ["-dynamiclib", "-install_name", "@rpath/AetherRenpy.framework/AetherRenpy", "-Wl,-rpath,@loader_path/..",
        "-o", framework / "AetherRenpy", *objects, "-L" + str(libraries), "-F" + str(output / "Frameworks")]
    link += ["-l" + name for name in LIBRARIES]
    for name in FRAMEWORKS:
        link += ["-framework", name]
    run(link + ["-liconv", "-lresolv", "-lc++"])
    runtime = output / "renpy-runtime"
    for name in ("renpy", "lib/python3.12"):
        shutil.copytree(sdk / name, runtime / name, copy_function=clone, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("__pycache__"))
    for name in ("renpy.py", "LICENSE.txt"):
        destination = runtime / name
        if destination.exists(): destination.unlink()
        clone(sdk / name, destination)
    shutil.copytree(greenlet / "src/greenlet", runtime / "lib/python3.12/site-packages/greenlet", copy_function=clone,
                    dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__", "tests", "*.c", "*.cpp", "*.h", "platform"))
    notices = runtime / "licenses/greenlet"
    notices.mkdir(parents=True, exist_ok=True)
    for name in ("LICENSE", "LICENSE.PSF"):
        shutil.copy2(greenlet / name, notices / name)
    (runtime / "AETHER_NATIVE_SDK.txt").write_text(
        "Ren'Py 8.5.3.26051504, Python 3.12.8, greenlet 3.5.6. Native iOS embedding.\n"
        "SDK SDL Objective-C names isolated; selected SDL window entry points adapted.\n"
        "Sources: https://github.com/renpy/renpy https://github.com/renpy/renpy-build https://github.com/python-greenlet/greenlet\n"
        "Rebuild and relink with tools/build_renpy_ios.py and bridge/renpy_runtime/ios_sdl_adapter.mm.\n")
    if args.smoke_app:
        app = output / "RenpyNativeSmoke.app"
        app.mkdir(exist_ok=True)
        for name in ("Frameworks", "renpy-runtime"):
            shutil.copytree(output / name, app / name, copy_function=clone, dirs_exist_ok=True)
        for name in ("host.py", "overlay.rpy", "embedded.py"):
            shutil.copy2(REPO / "apps/godot_app/renpy_runtime" / name, app / name)
        shutil.copytree(REPO / "tests/fixtures/renpy_host", app / "fixture", copy_function=clone, dirs_exist_ok=True)
        shutil.copy2(sdk / "sdk-fonts/SourceHanSansLite.ttf", app / "fixture/game/probe.ttf")
        shutil.copy2(sdk / "sdk-fonts/SourceHanSansLite.ttf", app / "font.ttf")
        (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"org.aether.tests.renpy.ios",
            "CFBundleName":"Aether Renpy Native Test", "CFBundleExecutable":"RenpyNativeSmoke", "CFBundlePackageType":"APPL",
            "CFBundleVersion":"1", "CFBundleShortVersionString":"1.0", "MinimumOSVersion":"13.0", "UIDeviceFamily":[1, 2],
            "UIRequiresFullScreen":True, "UIApplicationSupportsIndirectInputEvents":True,
            "UISupportedInterfaceOrientations":["UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]}))
        run(compiler + ["-fobjc-arc", "-std=c++17", "-I" + str(REPO / "bridge/godot_extension/src"),
            REPO / "tests/renpy_mobile/ios_host_smoke.mm", REPO / "bridge/godot_extension/src/renpy_native_ios.mm",
            "-o", app / "RenpyNativeSmoke", "-framework", "UIKit", "-framework", "Foundation", "-framework", "QuartzCore", "-framework", "CoreGraphics",
            "-Wl,-rpath,@executable_path/Frameworks"])
        for name in (app / "Frameworks").glob("*.framework"):
            run(["codesign", "--force", "--sign", "-", name])
        run(["codesign", "--force", "--sign", "-", app])
    print(output)


if __name__ == "__main__":
    main()
