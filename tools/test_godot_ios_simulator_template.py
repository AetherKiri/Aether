#!/usr/bin/env python3
"""Check real official template archives and LLVM-produced Apple objects.

This is archive/preset acceptance, not a Godot engine build or gameplay test.
On Darwin the universal archive checks use real Xcode lipo and SDK compilers.
"""
import argparse
import configparser
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

import build_godot_ios_simulator_template as helper


def rejected(action):
    try:
        action()
    except ValueError:
        return
    raise AssertionError("An incompatible real archive/template was accepted")


def config(path):
    result = configparser.ConfigParser(interpolation=None)
    result.read(path)
    return {section: dict(result[section]) for section in result.sections()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, required=True,
                        help="The genuine official Godot4.7.2 ios.zip")
    parser.add_argument("--clang", default=shutil.which("clang"))
    parser.add_argument("--ar", default=shutil.which("llvm-ar"))
    args = parser.parse_args()
    require = helper.require
    require(args.template.is_file(), "A real official template is required")
    actual = helper.verify_template(args.template, "x86_64")
    require(all(item["slices"][0]["architecture"] == "x86_64" and len(item["slices"]) == 1
                for item in actual.values()), "This acceptance starts with the original x64-only release template")
    rejected(lambda: helper.verify_template(args.template, "arm64"))
    with tempfile.TemporaryDirectory(prefix="godot-real-archive-acceptance-") as temporary:
        root = Path(temporary)
        source = root / "object.c"
        source.write_text("int archive_platform_acceptance(void) { return 7; }\n")
        archives = {}
        for name, target, sdk in (("sim-arm64", "arm64-apple-ios14.0-simulator", "iphonesimulator"),
                                  ("device-arm64", "arm64-apple-ios14.0", "iphoneos"),
                                  ("sim-x86_64", "x86_64-apple-ios14.0-simulator", "iphonesimulator")):
            obj, archive = root / (name + ".o"), root / (name + ".a")
            if sys.platform == "darwin":
                sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
                compiler = ["xcrun", "--sdk", sdk, "clang", "-isysroot", sdk_path]
                archiver = ["xcrun", "ar"]
            else:
                require(args.clang and args.ar, "Real LLVM clang and llvm-ar are required")
                compiler, archiver = [args.clang], [args.ar, "--format=darwin"]
            subprocess.run([*compiler, "-target", target, "-c", source, "-o", obj], check=True)
            subprocess.run([*archiver, "rcs", archive, obj], check=True)
            archives[name] = archive
        require(helper.archive_identity(archives["sim-arm64"])[0] ==
                {"architecture": "arm64", "objects": 1, "platform": 7}, "Actual arm64 Simulator object rejected")
        require(helper.archive_identity(archives["sim-x86_64"])[0] ==
                {"architecture": "x86_64", "objects": 1, "platform": 7}, "Actual x64 Simulator object rejected")
        rejected(lambda: helper.archive_identity(archives["device-arm64"]))
        with zipfile.ZipFile(args.template) as template:
            # The actual device archive must never pass the Simulator gate,
            # despite matching CPU and truthful device plist metadata.
            path = root / "official-camera-device.a"
            path.write_bytes(template.read("libgodot_camera.ios.debug.xcframework/ios-arm64/libgodot_camera.a"))
            rejected(lambda: helper.archive_identity(path))
            # Exercise the real ZIP writer on the genuine full release template;
            # retain every untouched archive/metadata byte and input ZIP itself.
            camera = root / "official-camera-simulator.a"
            camera.write_bytes(template.read(helper.member("libgodot_camera")))
            copy = root / "roundtrip-ios.zip"
            original_digest = helper.digest(args.template)
            helper.replace_template_archives(template, copy, {helper.member("libgodot_camera"): camera})
            require(helper.verify_template(copy, "x86_64") == actual, "Actual ZIP roundtrip changed real libraries")
            require(helper.digest(args.template) == original_digest, "Official input ZIP was modified")
        universal = "not_run (Linux has no Apple lipo)"
        if sys.platform == "darwin":
            fat = root / "real-universal.a"
            subprocess.run(["xcrun", "lipo", "-create", archives["sim-arm64"], archives["sim-x86_64"],
                            "-output", fat], check=True)
            require({item["architecture"] for item in helper.archive_identity(fat)} == {"arm64", "x86_64"},
                    "Real lipo archive identities rejected")
            wrong = root / "device-in-universal.a"
            subprocess.run(["xcrun", "lipo", "-create", archives["device-arm64"], archives["sim-x86_64"],
                            "-output", wrong], check=True)
            rejected(lambda: helper.archive_identity(wrong))
            universal = "passed (real Xcode lipo/SDK objects)"
        presets = Path(__file__).resolve().parents[1] / "apps/godot_app/export_presets.cfg"
        before = config(presets)
        output = root / "scoped-export.cfg"
        for name, section in (("iOS Simulator Debug", "preset.11.options"),
                              ("iOS Simulator x64 Debug", "preset.12.options"),
                              ("iOS Debug", "preset.1.options")):
            helper.patch_preset(presets, output, name, args.template, "debug")
            after = config(output)
            expected = {key: dict(value) for key, value in before.items()}
            expected[section]["custom_template/debug"] = json.dumps(str(args.template.resolve()))
            require(after == expected, "Custom template changed another preset or option")
        rejected(lambda: helper.patch_preset(presets, output, "Android Debug", args.template, "debug"))
    print(json.dumps({"status": "passed", "official_template_sha256": helper.digest(args.template),
                      "official_archives": actual, "device_slice_rejected": True,
                      "real_template_roundtrip": "all_untouched_member_hashes_identical",
                      "real_universal_archive": universal, "godot_engine_build": "not_run", "gameplay": "not_run"}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
