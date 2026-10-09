#!/usr/bin/env python3
"""Test real iPhoneOS archive identity and Godot's scoped device PCK profile.

Godot source builds, signing and phone gameplay are not performed by this test.
"""
import argparse
import configparser
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

import build_godot_ios_device_template as device
import build_godot_ios_simulator_template as common

REPO = Path(__file__).resolve().parents[1]


def rejected(action):
    try:
        action()
    except ValueError:
        return
    raise AssertionError("An incompatible real device archive was accepted")


def config(path):
    result = configparser.ConfigParser(interpolation=None)
    result.read(path)
    return {section: dict(result[section]) for section in result.sections()}


def run(arguments, environment, log):
    result = subprocess.run(list(map(str, arguments)), env=environment, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text(result.stdout)
    common.require(result.returncode == 0, f"Actual command failed ({result.returncode}): {log}\n{result.stdout[-3000:]}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, required=True, help="Genuine official Godot4.7.2 ios.zip")
    parser.add_argument("--godot", type=Path, required=True, help="Genuine Godot4.7.2 editor")
    parser.add_argument("--clang", default=shutil.which("clang"))
    parser.add_argument("--ar", default=shutil.which("llvm-ar"))
    parser.add_argument("--nm", default=shutil.which("llvm-nm"))
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    root = (args.output_dir or Path(tempfile.mkdtemp(prefix="godot-real-device-acceptance-"))).resolve()
    root.mkdir(parents=True, exist_ok=True)
    require = common.require
    actual = device.verify_template(args.template)
    require(all(item["slices"] == [{"architecture": "arm64", "objects": item["slices"][0]["objects"], "platform": 2}]
                for item in actual.values()), "Original device archive identity mismatch")
    with tempfile.TemporaryDirectory(prefix="godot-real-device-objects-") as temporary:
        work = Path(temporary)
        source = work / "object.c"
        source.write_text("int archive_platform_acceptance(void) { return 2; }\n")
        for label, target, sdk, expected in (("device", "arm64-apple-ios14.0", "iphoneos", 2),
                                            ("simulator", "arm64-apple-ios14.0-simulator", "iphonesimulator", 7)):
            obj, archive = work / (label + ".o"), work / (label + ".a")
            if sys.platform == "darwin":
                sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
                compiler, archiver = ["xcrun", "--sdk", sdk, "clang", "-isysroot", sdk_path], ["xcrun", "ar"]
            else:
                require(args.clang and args.ar, "Real LLVM clang/llvm-ar are required")
                compiler, archiver = [args.clang], [args.ar, "--format=darwin"]
            subprocess.run([*compiler, "-target", target, "-c", source, "-o", obj], check=True)
            subprocess.run([*archiver, "rcs", archive, obj], check=True)
            require(common.archive_identity(archive, expected_platform=expected)[0]["platform"] == expected,
                    "Real LLVM object platform mismatch")
            rejected(lambda: common.archive_identity(archive, expected_platform=7 if expected == 2 else 2))
            common.reject_sdl_symbols(archive, nm=None if sys.platform == "darwin" else args.nm)
        # The real official device engine's strong SDL3 symbols trigger the
        # collision even though its platform and CPU metadata are valid.
        require(sys.platform == "darwin" or args.nm, "Existing real LLVM nm is required on Linux")
        rejected(lambda: device.verify_template(args.template, require_sdl_free=True,
                                               nm=None if sys.platform == "darwin" else args.nm))
        with zipfile.ZipFile(args.template) as template:
            camera = work / "original-device-camera.a"
            camera.write_bytes(template.read(device.member("libgodot_camera")))
            copy = work / "roundtrip-device-ios.zip"
            original_digest = common.digest(args.template)
            allowed = {device.member(library) for library in common.LIBRARIES}
            common.replace_template_archives(template, copy, {device.member("libgodot_camera"): camera}, allowed_members=allowed)
            require(device.verify_template(copy) == actual, "Real device template roundtrip changed archive payloads")
            require(common.digest(args.template) == original_digest, "Official input ZIP changed")
            rejected(lambda: common.replace_template_archives(template, work / "invalid.zip",
                     {common.member("libgodot_camera"): camera}, allowed_members=allowed))
    project = root / "project"
    project.mkdir(exist_ok=True)
    original_project = REPO / "apps/godot_app/project.godot"
    original_presets = REPO / "apps/godot_app/export_presets.cfg"
    original_text = original_project.read_text()
    rendering = original_text[original_text.index("[rendering]"):]
    source_project = root / "original-project.godot"
    source_project.write_text("config_version=5\n\n" + rendering)
    shutil.copy2(REPO / "tools/godot_ios_device_template/profile_acceptance.gd", project / "profile_acceptance.gd")
    device.patch_device_profile(original_presets, project / "export_presets.cfg", source_project,
                                project / "project.godot", args.template)
    before, after = config(original_presets), config(project / "export_presets.cfg")
    expected = {key: dict(value) for key, value in before.items()}
    expected["preset.1"]["custom_features"] = json.dumps(device.FEATURE)
    expected["preset.1.options"]["custom_template/debug"] = json.dumps(str(args.template.resolve()))
    require(after == expected, "Device profile altered an unrelated preset or option")
    new_rendering = (project / "project.godot").read_text()
    require(new_rendering.replace('renderer/rendering_method.' + device.FEATURE + '="gl_compatibility"\n', '')
            == source_project.read_text(), "Device profile altered the ordinary renderer configuration")
    environment = dict(os.environ)
    environment.pop("GODOT_EDITOR_CUSTOM_FEATURES", None)
    for name in ("CACHE", "CONFIG", "DATA"):
        environment["XDG_" + name + "_HOME"] = str(root / name.lower())
    version = run([args.godot, "--version"], environment, root / "version.log")
    require("4.7.2.stable.official.ed1daf0bf" in version, "Actual editor does not match the pinned Godot source")
    environment["EXPECT_RENPY_DEVICE_PROFILE"] = "0"
    run([args.godot, "--headless", "--path", project, "--script", project / "profile_acceptance.gd"],
        environment, root / "ordinary-settings.log")
    pck = root / "device-profile.pck"
    run([args.godot, "--headless", "--path", project, "--export-pack", "iOS Debug", pck], environment, root / "pack.log")
    environment["EXPECT_RENPY_DEVICE_PROFILE"] = "1"
    run([args.godot, "--headless", "--path", project, "--main-pack", pck, "--script", "res://profile_acceptance.gd"],
        environment, root / "packed-settings.log")
    report = {"status": "passed", "official_template_sha256": common.digest(args.template), "official_archives": actual,
              "cross_platform_objects_rejected": True, "real_template_roundtrip": "all_untouched_member_hashes_identical",
              "real_godot_pck_profile": "passed", "ordinary_renderer_unchanged": True,
              "official_sdl3_collision_rejected": True,
              "godot_device_source_build": "not_run", "device_gameplay": "not_run", "signing": "not_run"}
    (root / "evidence.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
