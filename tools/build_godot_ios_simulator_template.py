#!/usr/bin/env python3
"""Build Godot 4.7.2's real arm64 Simulator engine into a template copy.

The official device/release libraries and the existing x86_64 Simulator slices
are preserved. This verifies build inputs and archives, not app gameplay.
"""
import argparse
import configparser
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

SOURCE_URL = "https://github.com/godotengine/godot.git"
SOURCE_SHA = "ed1daf0bf001b61586d9930840f2f1394092c079"
SIMULATOR = "ios-arm64_x86_64-simulator"
ARCHITECTURES = {0x100000C: "arm64", 0x1000007: "x86_64"}
LIBRARIES = {"libgodot": "", "libgodot_camera": "_camera"}
BUILD_FLAGS = ("platform=ios", "target=template_debug", "arch=arm64",
               "ios_simulator=yes", "vulkan=no", "metal=no", "opengl3=yes",
               "generate_bundle=no", "sdl=no")


def digest(path):
    with Path(path).open("rb") as stream:
        return stream_digest(stream)


def stream_digest(stream):
    value = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        value.update(block)
    return value.hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def macho_identity(data, expected_platform=7):
    require(len(data) >= 32 and data[:4] == bytes.fromhex("cffaedfe"),
            "Expected a genuine little-endian Mach-O64 object (LTO bitcode is not accepted)")
    cpu, _, kind, count, commands_size = struct.unpack_from("<IIIII", data, 4)
    require(cpu in ARCHITECTURES and kind == 1, "Expected an arm64/x86_64 Mach-O relocatable object")
    limit = 32 + commands_size
    require(limit <= len(data), "Truncated Mach-O load commands")
    offset, platforms = 32, set()
    for _ in range(count):
        require(offset + 8 <= limit, "Truncated Mach-O load command")
        command, size = struct.unpack_from("<II", data, offset)
        require(size >= 8 and offset + size <= limit, "Invalid Mach-O load command size")
        if command == 0x32:  # LC_BUILD_VERSION
            require(size >= 24, "Truncated LC_BUILD_VERSION")
            platforms.add(struct.unpack_from("<I", data, offset + 8)[0])
        elif command in (0x24, 0x25):  # macOS / iPhoneOS legacy minimum version
            platforms.add(1 if command == 0x24 else 2)
        offset += size
    require(offset == limit and platforms == {expected_platform},
            f"Object must actually target Apple platform {expected_platform}, found {sorted(platforms)}")
    return ARCHITECTURES[cpu]


def thin_archive(stream, offset, length, expected_platform=7):
    stream.seek(offset)
    require(stream.read(8) == b"!<arch>\n", "Expected a genuine static ar archive")
    end, count, architectures = offset + length, 0, set()
    while stream.tell() < end:
        header = stream.read(60)
        require(len(header) == 60 and header[58:] == b"`\n", "Invalid static archive member header")
        name = header[:16].decode("ascii").rstrip()
        size = int(header[48:58])
        require(size >= 0 and stream.tell() + size <= end, "Truncated static archive member")
        data = stream.read(size)
        if name.startswith("#1/"):
            name_size = int(name[3:])
            require(name_size <= size, "Invalid BSD archive member name")
            name, data = data[:name_size].rstrip(b"\0").decode("utf-8"), data[name_size:]
        if name not in ("/", "//", "/SYM64/") and not name.startswith("__.SYMDEF"):
            try:
                architectures.add(macho_identity(data, expected_platform))
            except ValueError as error:
                raise ValueError(f"{name}: {error}") from error
            count += 1
        if size % 2:
            require(stream.read(1) == b"\n", "Invalid static archive alignment")
    require(stream.tell() == end and count > 0 and len(architectures) == 1,
            "Each archive slice must contain nonempty objects of exactly one Apple architecture")
    return {"architecture": next(iter(architectures)), "objects": count, "platform": expected_platform}


def archive_identity(path, expected_platform=7):
    require(expected_platform in (2, 7), "Only actual iPhoneOS/Simulator archives are supported")
    path = Path(path)
    with path.open("rb") as stream:
        magic = stream.read(4)
        if magic == b"!<ar":
            identities = [thin_archive(stream, 0, path.stat().st_size, expected_platform)]
        else:
            formats = {bytes.fromhex("cafebabe"): (">", False),
                       bytes.fromhex("bebafeca"): ("<", False),
                       bytes.fromhex("cafebabf"): (">", True),
                       bytes.fromhex("bfbafeca"): ("<", True)}
            require(magic in formats, "Expected a thin or universal Mach-O static archive")
            endian, fat64 = formats[magic]
            count = struct.unpack(endian + "I", stream.read(4))[0]
            require(0 < count <= 2, "Unexpected universal archive architecture count")
            slices = []
            for _ in range(count):
                fields = struct.unpack(endian + ("IIQQII" if fat64 else "IIIII"),
                                       stream.read(32 if fat64 else 20))
                cpu, _, offset, length, alignment = fields[:5]
                require(cpu in ARCHITECTURES and length > 0 and alignment < 32
                        and offset >= 8 + count * (32 if fat64 else 20)
                        and offset + length <= path.stat().st_size, "Invalid universal archive slice")
                require(offset % (1 << alignment) == 0, "Misaligned universal archive slice")
                slices.append((cpu, offset, length))
            ranges = sorted((offset, offset + length) for _, offset, length in slices)
            require(all(a[1] <= b[0] for a, b in zip(ranges, ranges[1:])), "Overlapping archive slices")
            identities = []
            for cpu, offset, length in slices:
                identity = thin_archive(stream, offset, length, expected_platform)
                require(identity["architecture"] == ARCHITECTURES[cpu], "CPU header disagrees with archive objects")
                identities.append(identity)
    require(len({item["architecture"] for item in identities}) == len(identities), "Duplicate CPU slices")
    return identities


def reject_sdl_symbols(path, arch=None, nm=None):
    if nm:
        require(arch is None, "Explicit LLVM nm checks use a genuine thin archive")
        arguments = [str(nm), "--defined-only", "--extern-only", str(path)]
    else:
        require(sys.platform == "darwin", "Checking a rebuilt arm64 engine requires real Xcode nm")
        arguments = ["xcrun", "nm", "-gU"]
        if arch:
            arguments.extend(("-arch", arch))
        arguments.append(str(path))
    listing = command(arguments)
    forbidden = {"_SDL_Init", "_SDL_GetError", "_SDL_GetGamepads"}
    actual = {line.split()[-1] for line in listing.splitlines() if line.split()}
    require(not actual & forbidden, f"Godot's SDL3 conflicts with force-loaded host SDL2: {sorted(actual & forbidden)}")


def member(library):
    return f"{library}.ios.debug.xcframework/{SIMULATOR}/{library}.a"


def verify_template(template, arch, exported=None):
    result = {}
    with zipfile.ZipFile(template) as source, tempfile.TemporaryDirectory(prefix="godot-ios-verify-") as work:
        require(len(source.namelist()) == len(set(source.namelist())), "Duplicate template ZIP members")
        for library, suffix in LIBRARIES.items():
            framework = f"{library}.ios.debug.xcframework"
            metadata = plistlib.loads(source.read(f"{framework}/Info.plist"))
            candidates = [entry for entry in metadata["AvailableLibraries"]
                          if entry.get("LibraryIdentifier") == SIMULATOR]
            require(len(candidates) == 1, f"Missing or ambiguous Simulator metadata: {framework}")
            info = candidates[0]
            require(info.get("SupportedPlatform") == "ios" and info.get("SupportedPlatformVariant") == "simulator"
                    and info.get("LibraryPath") == f"{library}.a", f"Invalid Simulator metadata: {framework}")
            path = Path(work) / (library + ".a")
            with source.open(member(library)) as src, path.open("wb") as dest:
                shutil.copyfileobj(src, dest)
            identities = archive_identity(path)
            actual = {entry["architecture"] for entry in identities}
            require(arch in actual, f"Godot {framework} lacks actual {arch} Simulator objects: {sorted(actual)}")
            # The original x64-only official ZIP incorrectly advertises arm64.
            # The repaired arm64 ZIP must have exact, truthful metadata.
            if arch == "arm64":
                require(actual == set(info["SupportedArchitectures"]) == {"arm64", "x86_64"},
                        f"Simulator metadata differs from real CPU slices: {framework}")
                reject_sdl_symbols(path, arch="arm64")
            library_digest = digest(path)
            if exported:
                actual_path = Path(exported) / f"Aether{suffix}.xcframework/{SIMULATOR}/{library}.a"
                # Godot only exports the optional camera framework when enabled.
                if not suffix or actual_path.exists():
                    require(actual_path.is_file() and digest(actual_path) == library_digest,
                            f"Actual Godot export did not use the verified template: {actual_path}")
            result[library] = {"sha256": library_digest, "slices": identities}
    return result


def patch_preset(source, destination, name, template, mode):
    text = Path(source).read_text()
    config = configparser.ConfigParser(interpolation=None, strict=True)
    config.read_string(text)
    sections = [section for section in config.sections() if section.startswith("preset.")
                and not section.endswith(".options") and config.get(section, "name", fallback="") == json.dumps(name)]
    require(len(sections) == 1, f"Expected one export preset named {name}")
    section = sections[0]
    require(config.get(section, "platform") == '"iOS"', "Custom iOS template requires an iOS export preset")
    options, key = section + ".options", "custom_template/" + mode
    require(options in config, f"Missing {options}")
    value = json.dumps(str(Path(template).resolve(strict=True)), ensure_ascii=False)
    lines, inside, found = [], False, False
    for line in text.splitlines(keepends=True):
        if line.startswith("["):
            if inside and not found:
                lines.append(key + "=" + value + "\n")
            inside = line.strip() == "[" + options + "]"
        if inside and line.split("=", 1)[0].strip() == key:
            require(not found, f"Duplicate {key}")
            line, found = key + "=" + value + "\n", True
        lines.append(line)
    if inside and not found:
        lines.append(key + "=" + value + "\n")
    Path(destination).write_text("".join(lines))


def command(arguments, *, cwd=None):
    result = subprocess.run(list(map(str, arguments)), cwd=cwd, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
    return result.stdout.strip()


def replace_template_archives(template, destination, replacements, allowed_members=None):
    require(len(template.namelist()) == len(set(template.namelist())), "Duplicate template ZIP members")
    simulator_members = {member(library) for library in LIBRARIES}
    device_members = {f"{library}.ios.debug.xcframework/ios-arm64/{library}.a" for library in LIBRARIES}
    allowed = simulator_members if allowed_members is None else set(allowed_members)
    require(allowed <= simulator_members | device_members and set(replacements) <= allowed,
            "Only the explicitly selected debug engine/camera archives may be replaced")
    with zipfile.ZipFile(destination, "w") as patched:
        patched.comment = template.comment
        for info in template.infolist():
            with (replacements[info.filename].open("rb") if info.filename in replacements
                  else template.open(info)) as src, patched.open(copy.copy(info), "w") as dest:
                shutil.copyfileobj(src, dest)
    with zipfile.ZipFile(destination) as patched:
        require(template.namelist() == patched.namelist(), "Template member set/order changed")
        for name in template.namelist():
            if name not in replacements:
                with template.open(name) as before, patched.open(name) as after:
                    require(stream_digest(before) == stream_digest(after), f"Untouched template member changed: {name}")


def build(args):
    require(sys.platform == "darwin", "A genuine macOS/Xcode host is required; no cross-SDK substitute is accepted")
    import SCons
    require(tuple(map(int, SCons.__version__.split(".")[:2])) >= (4, 4), "Godot requires SCons >= 4.4")
    original, output, root = args.input_template.resolve(strict=True), args.output_template.resolve(), args.output_dir.resolve()
    require(original != output, "The official input template must remain unchanged")
    require("OSXCROSS_IOS" not in os.environ, "Use genuine selected Xcode tools, not an osxcross SDK")
    root.mkdir(parents=True, exist_ok=True)
    source = root / "godot-source"
    require(not source.exists(), "Use a fresh output directory for a real source build")
    sdk = command(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
    compiler = command(["xcrun", "--sdk", "iphonesimulator", "--find", "clang"])
    evidence = {"status": "building", "source_url": SOURCE_URL, "source_sha": SOURCE_SHA,
                "input_template_sha256": digest(original), "sdk_path": sdk,
                "sdk_version": command(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]),
                "compiler": compiler, "compiler_version": command([compiler, "--version"]),
                "xcode_version": command(["xcodebuild", "-version"]), "gameplay": "not_run"}
    report = root / "evidence.json"
    report.write_text(json.dumps(evidence, indent=2) + "\n")
    try:
        evidence["input_libraries"] = verify_template(original, "x86_64")
        command(["git", "init", "--quiet", source])
        command(["git", "-C", source, "fetch", "--depth=1", SOURCE_URL, SOURCE_SHA])
        command(["git", "-C", source, "checkout", "--quiet", "--detach", "FETCH_HEAD"])
        require(command(["git", "-C", source, "rev-parse", "HEAD"]) == SOURCE_SHA, "Godot source pin mismatch")
        toolchain = Path(compiler).resolve(strict=True).parents[2]
        require((toolchain / "usr/bin/clang++").is_file(), "Selected compiler lacks its real Apple toolchain")
        invocation = [sys.executable, "-m", "SCons", *BUILD_FLAGS,
                      "APPLE_SDK_PATH=" + sdk, "APPLE_TOOLCHAIN_PATH=" + str(toolchain), "-j" + str(args.jobs)]
        evidence["build_command"] = invocation
        print("Real Godot Simulator build:", shlex.join(invocation), flush=True)
        with (root / "source-build.log").open("w") as log:
            subprocess.run(invocation, cwd=source, stdout=log, stderr=subprocess.STDOUT, check=True)
        replacements, libraries = {}, {}
        with zipfile.ZipFile(original) as template:
            for library in LIBRARIES:
                arm = source / f"bin/{library}.ios.template_debug.arm64.simulator.a"
                identities = archive_identity(arm)
                require(len(identities) == 1 and identities[0]["architecture"] == "arm64", f"Wrong source build: {arm}")
                base = root / (library + "-official.a")
                with template.open(member(library)) as src, base.open("wb") as dest:
                    shutil.copyfileobj(src, dest)
                original_slices = archive_identity(base)
                require({entry["architecture"] for entry in original_slices} <= {"arm64", "x86_64"}
                        and any(entry["architecture"] == "x86_64" for entry in original_slices), "Official x64 slice missing")
                x64 = root / (library + "-x86_64.a")
                if len(original_slices) == 1:
                    shutil.copyfile(base, x64)
                else:
                    command(["xcrun", "lipo", base, "-thin", "x86_64", "-output", x64])
                merged = root / (library + "-simulator.a")
                command(["xcrun", "lipo", "-create", x64, arm, "-output", merged])
                retained = root / (library + "-retained-x86_64.a")
                command(["xcrun", "lipo", merged, "-thin", "x86_64", "-output", retained])
                require(digest(x64) == digest(retained), "Official x64 archive bytes changed")
                require({entry["architecture"] for entry in archive_identity(merged)} == {"arm64", "x86_64"}, "Bad merged archive")
                replacements[member(library)] = merged
                libraries[library] = {"arm64_sha256": digest(arm), "official_x86_64_sha256": digest(x64),
                                      "merged_sha256": digest(merged), "arm64_objects": identities[0]["objects"]}
            output.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(prefix="ios-template-", suffix=".zip", dir=output.parent, delete=False) as temporary:
                staged = Path(temporary.name)
            try:
                replace_template_archives(template, staged, replacements)
                verify_template(staged, "arm64")
                os.replace(staged, output)
            finally:
                staged.unlink(missing_ok=True)
        evidence.update(status="built_and_verified", output_template_sha256=digest(output), libraries=libraries,
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
    checker.add_argument("--arch", choices=("arm64", "x86_64"), required=True)
    checker.add_argument("--exported-dir", type=Path)
    preset = commands.add_parser("preset")
    preset.add_argument("--source", type=Path, required=True)
    preset.add_argument("--destination", type=Path, required=True)
    preset.add_argument("--preset", required=True)
    preset.add_argument("--template", type=Path, required=True)
    preset.add_argument("--mode", choices=("debug", "release"), required=True)
    args = parser.parse_args()
    try:
        if args.action == "build":
            require(args.jobs > 0, "Build jobs must be positive")
            build(args)
        elif args.action == "verify":
            print(json.dumps(verify_template(args.template, args.arch, args.exported_dir), indent=2))
        else:
            patch_preset(args.source, args.destination, args.preset, args.template, args.mode)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, struct.error, subprocess.CalledProcessError) as error:
        print(f"Godot Simulator template failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
