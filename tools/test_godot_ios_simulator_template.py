#!/usr/bin/env python3
"""Check real official template archives and LLVM-produced Apple objects.

This is archive/preset acceptance, not a Godot engine build or gameplay test.
On Darwin the universal archive checks use real Xcode lipo and SDK compilers.
"""
import argparse
import configparser
import copy as copy_module
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
    parser.add_argument("--nm", default=shutil.which("llvm-nm"))
    args = parser.parse_args()
    require = helper.require
    require(args.template.is_file(), "A real official template is required")
    actual = helper.verify_template(args.template, "x86_64")
    require(all(item["slices"][0]["architecture"] == "x86_64" and len(item["slices"]) == 1
                for item in actual.values()), "This acceptance starts with the original x64-only release template")
    rejected(lambda: helper.verify_template(args.template, "arm64"))
    # Pure key checks use actual official ZIP/LLVM inputs. They do not claim a
    # Darwin toolchain identity or manufacture successful source-build evidence.
    native_identity = {"source_sha": helper.SOURCE_SHA, "build_flags": list(helper.BUILD_FLAGS),
                       "input_template_sha256": helper.digest(args.template)}
    if args.clang:
        native_identity["compiler_sha256"] = helper.digest(args.clang)
    key = helper.cache_key(native_identity)
    require(key == helper.cache_key(dict(reversed(list(native_identity.items())))), "Cache key depends on dictionary order")
    for name in native_identity:
        changed = dict(native_identity)
        changed[name] = "different input"
        require(key != helper.cache_key(changed), "Cache key did not change for " + name)
    for incomplete in ({}, {"status": "building"}, {"status": "failed"}, {"status": "built_and_verified"}):
        rejected(lambda: helper.verify_cache_metadata(incomplete, native_identity, helper.digest(args.template)))
    if sys.platform != "darwin":
        rejected(lambda: helper.cache_identity(args.template))
        rejected(lambda: helper.verify_cached_libraries(args.template, args.template))
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
        llvm_nm = args.nm or (str(Path(args.ar).with_name("llvm-nm")) if args.ar else None)
        if sys.platform != "darwin":
            require(llvm_nm and Path(llvm_nm).is_file(), "A genuine LLVM nm is required for the SDL collision gate")
        helper.reject_sdl_symbols(archives["sim-arm64"], nm=llvm_nm if sys.platform != "darwin" else None)
        sdl_source, sdl_object, sdl_archive = [root / name for name in ("sdl.c", "sdl.o", "sdl.a")]
        sdl_source.write_text("int SDL_Init(void) { return 0; }\n")
        subprocess.run([*compiler, "-target", "arm64-apple-ios14.0-simulator", "-c", sdl_source, "-o", sdl_object], check=True)
        subprocess.run([*archiver, "rcs", sdl_archive, sdl_object], check=True)
        helper.archive_identity(sdl_archive)
        rejected(lambda: helper.reject_sdl_symbols(sdl_archive, nm=llvm_nm if sys.platform != "darwin" else None))
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
            unchanged = helper.unchanged_member_hashes(args.template, copy)
            require(len(unchanged) == len(template.namelist()) - len(helper.LIBRARIES), "Incomplete untouched-member proof")
            mutated = root / "changed-official-member.zip"
            selected = "libgodot.ios.debug.xcframework/Info.plist"
            with zipfile.ZipFile(mutated, "w") as destination:
                destination.comment = template.comment
                for info in template.infolist():
                    with template.open(info) as src, destination.open(copy_module.copy(info), "w") as dest:
                        shutil.copyfileobj(src, dest)
                        if info.filename == selected:
                            dest.write(b"\n")
            rejected(lambda: helper.unchanged_member_hashes(args.template, mutated))
            duplicate = root / "duplicate-member.zip"
            with zipfile.ZipFile(duplicate, "w") as destination:
                destination.writestr(selected, template.read(selected))
                destination.writestr(selected, template.read(selected))
            rejected(lambda: helper.unchanged_member_hashes(args.template, duplicate))
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
            rejected(lambda: helper.verify_cached_libraries(args.template, args.template))
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
                      "cache_key_input_changes": "passed (real inputs; no fabricated Darwin identity)",
                      "incomplete_cache_evidence_rejected": True, "changed_or_duplicate_cached_member_rejected": True,
                      "real_arm64_sdl_collision_rejected": True,
                      "cached_source_build_acceptance": "not_run (no newly built genuine cached engine supplied)",
                      "real_universal_archive": universal, "godot_engine_build": "not_run", "gameplay": "not_run"}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
