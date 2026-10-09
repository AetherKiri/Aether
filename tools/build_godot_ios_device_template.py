#!/usr/bin/env python3
"""Build a real Godot 4.7.2 GLES iPhoneOS debug template for Ren'Py.

Only device/debug engine and camera archives change. No signing identity,
device execution, replacement SDK or license acceptance is performed here.
"""
import argparse
import configparser
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import zipfile

import build_godot_ios_simulator_template as common

FEATURE = "renpy_ios_device_gles"
DEVICE = "ios-arm64"
BUILD_FLAGS = ("platform=ios", "target=template_debug", "arch=arm64",
               "ios_simulator=no", "vulkan=no", "metal=no", "opengl3=yes",
               "generate_bundle=no", "sdl=no")


def member(library):
    return f"{library}.ios.debug.xcframework/{DEVICE}/{library}.a"


def verify_template(template, exported=None, require_sdl_free=False, nm=None):
    result = {}
    with zipfile.ZipFile(template) as source, tempfile.TemporaryDirectory(prefix="godot-device-verify-") as work:
        common.require(len(source.namelist()) == len(set(source.namelist())), "Duplicate template ZIP members")
        for library, suffix in common.LIBRARIES.items():
            framework = f"{library}.ios.debug.xcframework"
            metadata = plistlib.loads(source.read(f"{framework}/Info.plist"))
            candidates = [entry for entry in metadata["AvailableLibraries"]
                          if entry.get("LibraryIdentifier") == DEVICE]
            common.require(len(candidates) == 1, f"Missing or ambiguous device metadata: {framework}")
            info = candidates[0]
            common.require(info.get("SupportedPlatform") == "ios" and not info.get("SupportedPlatformVariant")
                           and info.get("LibraryPath") == f"{library}.a"
                           and info.get("SupportedArchitectures") == ["arm64"], f"Invalid device metadata: {framework}")
            path = Path(work) / (library + ".a")
            with source.open(member(library)) as src, path.open("wb") as dest:
                shutil.copyfileobj(src, dest)
            identities = common.archive_identity(path, expected_platform=2)
            common.require(len(identities) == 1 and identities[0]["architecture"] == "arm64", "Device archive must be thin arm64")
            if require_sdl_free:
                common.reject_sdl_symbols(path, nm=nm)
            library_digest = common.digest(path)
            if exported:
                actual_path = Path(exported) / f"Aether{suffix}.xcframework/{DEVICE}/{library}.a"
                if not suffix or actual_path.exists():
                    common.require(actual_path.is_file() and common.digest(actual_path) == library_digest,
                                   f"Actual Godot export did not use the verified device template: {actual_path}")
            result[library] = {"sha256": library_digest, "slices": identities}
    return result


def replace_section_value(text, section, key, value):
    lines, inside, found, sections = [], False, False, 0
    for line in text.splitlines(keepends=True):
        if line.startswith("["):
            if inside and not found:
                lines.append(key + "=" + value + "\n")
            inside = line.strip() == "[" + section + "]"
            sections += int(inside)
        if inside and line.split("=", 1)[0].strip() == key:
            common.require(not found, f"Duplicate {key}")
            line, found = key + "=" + value + "\n", True
        lines.append(line)
    if inside and not found:
        lines.append(key + "=" + value + "\n")
    common.require(sections == 1, f"Expected exactly one [{section}]")
    return "".join(lines)


def patch_device_profile(presets_source, presets_destination, project_source, project_destination, template):
    # This operation is scoped to a copied Debug device preset. It never
    # changes the ordinary device preset, global renderer or Simulator tags.
    common.require(Path(presets_source).resolve() != Path(presets_destination).resolve()
                   and Path(project_source).resolve() != Path(project_destination).resolve(),
                   "Use separate profile copies or backups; preserve the ordinary source files")
    common.patch_preset(presets_source, presets_destination, "iOS Debug", template, "debug")
    text = Path(presets_destination).read_text()
    config = configparser.ConfigParser(interpolation=None)
    config.read_string(text)
    sections = [section for section in config.sections() if section.startswith("preset.")
                and not section.endswith(".options") and config.get(section, "name", fallback="") == '"iOS Debug"']
    common.require(len(sections) == 1, "Expected the scoped Debug device preset")
    features = json.loads(config.get(sections[0], "custom_features", fallback='""')).split(",")
    features = [value.strip() for value in features if value.strip()]
    common.require("ios_simulator" not in features and "ios_simulator_x64" not in features,
                   "A device profile must never select Simulator libraries")
    if FEATURE not in features:
        features.append(FEATURE)
    Path(presets_destination).write_text(replace_section_value(text, sections[0], "custom_features", json.dumps(",".join(features))))
    project = Path(project_source).read_text()
    Path(project_destination).write_text(replace_section_value(project, "rendering",
                        "renderer/rendering_method." + FEATURE, '"gl_compatibility"'))


def build(args):
    common.require(sys.platform == "darwin", "A genuine macOS/Xcode host with its iPhoneOS SDK is required")
    import SCons
    common.require(tuple(map(int, SCons.__version__.split(".")[:2])) >= (4, 4), "Godot requires SCons >= 4.4")
    original, output, root = args.input_template.resolve(strict=True), args.output_template.resolve(), args.output_dir.resolve()
    common.require(original != output, "The official input template must remain unchanged")
    common.require("OSXCROSS_IOS" not in os.environ, "Use the genuine selected Xcode SDK")
    root.mkdir(parents=True, exist_ok=True)
    source = root / "godot-source"
    common.require(not source.exists(), "Use a fresh output directory for a real device source build")
    sdk = common.command(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"])
    compiler = common.command(["xcrun", "--sdk", "iphoneos", "--find", "clang"])
    evidence = {"status": "building", "source_url": common.SOURCE_URL, "source_sha": common.SOURCE_SHA,
                "input_template_sha256": common.digest(original), "sdk_path": sdk,
                "sdk_version": common.command(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"]),
                "compiler": compiler, "compiler_version": common.command([compiler, "--version"]),
                "xcode_version": common.command(["xcodebuild", "-version"]),
                "renderer_profile": FEATURE, "signing": "not_run", "device_gameplay": "not_run"}
    report = root / "evidence.json"
    report.write_text(json.dumps(evidence, indent=2) + "\n")
    try:
        evidence["input_libraries"] = verify_template(original)
        common.command(["git", "init", "--quiet", source])
        common.command(["git", "-C", source, "fetch", "--depth=1", common.SOURCE_URL, common.SOURCE_SHA])
        common.command(["git", "-C", source, "checkout", "--quiet", "--detach", "FETCH_HEAD"])
        common.require(common.command(["git", "-C", source, "rev-parse", "HEAD"]) == common.SOURCE_SHA, "Godot source pin mismatch")
        toolchain = Path(compiler).resolve(strict=True).parents[2]
        common.require((toolchain / "usr/bin/clang++").is_file(), "Selected compiler lacks its real Apple toolchain")
        invocation = [sys.executable, "-m", "SCons", *BUILD_FLAGS,
                      "APPLE_SDK_PATH=" + sdk, "APPLE_TOOLCHAIN_PATH=" + str(toolchain), "-j" + str(args.jobs)]
        evidence["build_command"] = invocation
        print("Real Godot iPhoneOS build:", shlex.join(invocation), flush=True)
        with (root / "source-build.log").open("w") as log:
            subprocess.run(invocation, cwd=source, stdout=log, stderr=subprocess.STDOUT, check=True)
        replacements, libraries = {}, {}
        for library in common.LIBRARIES:
            archive = source / f"bin/{library}.ios.template_debug.arm64.a"
            identities = common.archive_identity(archive, expected_platform=2)
            common.require(len(identities) == 1 and identities[0]["architecture"] == "arm64", f"Wrong source build: {archive}")
            replacements[member(library)] = archive
            libraries[library] = {"sha256": common.digest(archive), "objects": identities[0]["objects"], "platform": 2}
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(prefix="ios-device-template-", suffix=".zip", dir=output.parent, delete=False) as temporary:
            staged = Path(temporary.name)
        try:
            with zipfile.ZipFile(original) as template:
                common.replace_template_archives(template, staged, replacements,
                                                 allowed_members={member(library) for library in common.LIBRARIES})
            verify_template(staged, require_sdl_free=True)
            os.replace(staged, output)
        finally:
            staged.unlink(missing_ok=True)
        evidence.update(status="built_and_verified", output_template_sha256=common.digest(output), libraries=libraries,
                        untouched_template_members="all_sha256_identical")
    except BaseException as error:
        evidence.update(status="failed", error=str(error))
        raise
    finally:
        report.write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    builder = commands.add_parser("build")
    builder.add_argument("--input-template", type=Path, required=True)
    builder.add_argument("--output-template", type=Path, required=True)
    builder.add_argument("--output-dir", type=Path, required=True)
    builder.add_argument("--jobs", type=int, default=3)
    checker = commands.add_parser("verify")
    checker.add_argument("--template", type=Path, required=True)
    checker.add_argument("--exported-dir", type=Path)
    checker.add_argument("--nm", type=Path, help="Existing real LLVM nm for thin-archive validation on Linux")
    profile = commands.add_parser("profile")
    profile.add_argument("--presets-source", type=Path, required=True)
    profile.add_argument("--presets-destination", type=Path, required=True)
    profile.add_argument("--project-source", type=Path, required=True)
    profile.add_argument("--project-destination", type=Path, required=True)
    profile.add_argument("--template", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.action == "build":
            common.require(args.jobs > 0, "Build jobs must be positive")
            build(args)
        elif args.action == "verify":
            print(json.dumps(verify_template(args.template, args.exported_dir, require_sdl_free=True, nm=args.nm), indent=2))
        else:
            patch_device_profile(args.presets_source, args.presets_destination, args.project_source,
                                 args.project_destination, args.template)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error:
        print(f"Godot device template failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
