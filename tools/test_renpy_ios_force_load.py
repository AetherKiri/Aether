#!/usr/bin/env python3
"""Link real Mach-O archives using the production Renios force-load arguments.

Darwin uses the selected Xcode Simulator SDK and Apple linker. Linux can use
real LLVM tools to check archive loading semantics, without an Apple SDK.
Neither path builds an application or executes an iOS runtime.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

import build_godot_ios_simulator_template as archive_tools

REPO = Path(__file__).resolve().parents[1]
ROOTS = ("librenpython.a", "librenpy.a", "libpython3.12.a", "libSDL2.a", "libSDL2_image.a")
EXCLUDED = ("libSDL2main.a", "libSDL2_test.a", "libSDL3main.a", "libSDL3_test.a", "libmockrt.a")


def run(command):
    result = subprocess.run(list(map(str, command)), stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(f"Actual command failed ({result.returncode}): {command}\n{result.stderr.decode()}")
    return result.stdout


def production_arguments(prebuilt):
    source = (REPO / "scripts/build_ios.sh").read_text()
    functions = []
    for name in ("renios_archive_is_excluded", "collect_renios_archives"):
        start = source.index(name + "() {\n")
        end = source.index("\n}\n", start) + 3
        functions.append(source[start:end])
    framework = source[source.index("build_renios_runtime_framework() {\n"):]
    start = framework.index("    local force_load_args=() archive\n")
    end = framework.index("    local minimum_flag=", start)
    actual_builder = framework[start:end]
    link_start = framework.index("    xcrun --sdk \"$IOS_SDK\" clang++")
    link_end = framework.index('\n        -o "$RENPY_FRAMEWORK_OUTPUT/$RENPY_FRAMEWORK_NAME"', link_start)
    actual_link = framework[link_start:link_end]
    assert actual_link.count('"${force_load_args[@]}"') == 1, "Production link must use the checked argv array"
    assert "-all_load" not in actual_link and "-noall_load" not in actual_link
    shell = "set -euo pipefail\n" + "\n".join(functions) + "\n"
    shell += 'arguments() {\n    local prebuilt="$1"\n' + actual_builder
    shell += '    printf "%s\\0" "${force_load_args[@]}"\n}\narguments "$1"\n'
    output = run(["bash", "-c", shell, "force-load-regression", prebuilt])
    return [part.decode() for part in output.rstrip(b"\0").split(b"\0")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clang", default=shutil.which("clang"))
    parser.add_argument("--ar", default=shutil.which("llvm-ar"))
    parser.add_argument("--nm", default=shutil.which("llvm-nm"))
    parser.add_argument("--linker", default=shutil.which("ld64.lld"))
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    output = (args.output_dir or Path(tempfile.mkdtemp(prefix="renios-real-force-load-"))).resolve()
    output.mkdir(parents=True, exist_ok=True)
    prebuilt = output / "native archives, selected"
    prebuilt.mkdir(exist_ok=True)
    target = "arm64-apple-ios14.0-simulator"
    if sys.platform == "darwin":
        sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"]).decode().strip()
        compiler = ["xcrun", "--sdk", "iphonesimulator", "clang", "-isysroot", sdk, "-target", target]
        archiver, nm = ["xcrun", "ar"], ["xcrun", "nm"]
        version_command = ["xcrun", "--sdk", "iphonesimulator", "clang", "--version"]
        linker_flags = []
        linker_kind = "selected_xcode_apple_linker"
    else:
        assert all((args.clang, args.ar, args.nm, args.linker)), "Actual clang/ar/nm/ld64.lld tools are required"
        sdk = "not_used_no_apple_sdk"
        compiler = [args.clang, "-target", target]
        archiver, nm = [args.ar, "--format=darwin"], [args.nm]
        version_command = [args.clang, "--version"]
        # LLD selects the Darwin flavor from its invoked ld64.lld basename.
        linker_flags = ["-fuse-ld=" + str(Path(args.linker).absolute()), "-Xlinker", "-arch", "-Xlinker", "arm64",
                        "-Xlinker", "-platform_version", "-Xlinker", "ios-simulator", "-Xlinker", "14.0",
                        "-Xlinker", "14.0"]
        linker_kind = "real_llvm_ld64_lld_not_apple_linker"
    symbols = {}
    selected_names = (*ROOTS, "libdependency.a", "libregistration, optional.a")
    for index, name in enumerate((*selected_names, *EXCLUDED, "ordinary.a")):
        objects, registrations = [], []
        for member in range(2):
            symbol = f"unreferenced_registration_{index}_{member}"
            source, obj = output / f"registration-{index}-{member}.c", output / f"registration-{index}-{member}.o"
            source.write_text(f"int {symbol}(void) {{ return {index + member}; }}\n")
            run([*compiler, "-c", source, "-o", obj])
            objects.append(obj)
            registrations.append("_" + symbol)
        archive = prebuilt / name
        run([*archiver, "rcs", archive, *objects])
        assert archive_tools.archive_identity(archive) == [{"architecture": "arm64", "objects": 2, "platform": 7}]
        symbols[name] = registrations
    nested = prebuilt / "nested"
    nested.mkdir(exist_ok=True)
    shutil.copy2(prebuilt / "ordinary.a", nested / "libnested.a")
    actual = production_arguments(prebuilt)
    expected_paths = [str(prebuilt / name) for name in (*ROOTS, *sorted(selected_names[len(ROOTS):]))]
    assert len(actual) == 4 * len(expected_paths), actual
    assert actual[::4] == ["-Xlinker"] * len(expected_paths)
    assert actual[1::4] == ["-force_load"] * len(expected_paths)
    assert actual[2::4] == ["-Xlinker"] * len(expected_paths)
    assert actual[3::4] == expected_paths, actual
    assert len(set(actual[3::4])) == len(expected_paths), "Each archive must be loaded once"
    entry = output / "entry.c"
    entry.write_text("int framework_entry(void) { return 0; }\n")
    entry_object = output / "entry.o"
    run([*compiler, "-c", entry, "-o", entry_object])
    exports = output / "exports.txt"
    exports.write_text("_framework_entry\n")
    common = [*compiler, "-dynamiclib", "-nostdlib", *linker_flags, entry_object]
    for label, archives in (("control", expected_paths), ("force-loaded", actual)):
        library = output / (label + ".dylib")
        command = [*common, *archives, prebuilt / "ordinary.a", "-Xlinker", "-exported_symbols_list",
                   "-Xlinker", exports, "-o", library]
        run(command)
        data = library.read_bytes()
        assert struct.unpack_from("<II", data) == (0xFEEDFACF, 0x0100000C), "Output must be real ARM64 Mach-O"
        assert struct.unpack_from("<I", data, 12)[0] == 6, "Output must be a linked Mach-O dylib"
        names = {line.split()[-1] for line in run([*nm, library]).decode().splitlines() if line.split()}
        wanted = {symbol for name in selected_names for symbol in symbols[name]}
        assert (wanted <= names if label == "force-loaded" else not wanted.intersection(names)), names
        assert not {symbol for name in (*EXCLUDED, "ordinary.a") for symbol in symbols[name]}.intersection(names)
        assert "_framework_entry" in names
    report = {"status": "passed", "linker": linker_kind, "sdk": sdk,
              "compiler_version": run(version_command).decode().splitlines()[0],
              "production_script_sha256": hashlib.sha256((REPO / "scripts/build_ios.sh").read_bytes()).hexdigest(),
              "selected_archives": len(expected_paths), "unreferenced_registration_objects_retained": len(wanted),
              "archive_paths_with_spaces_and_commas": "passed", "root_dedup_and_exclusion_boundaries": "passed",
              "unrelated_archive_not_force_loaded": "passed", "control_link_omits_unreferenced_objects": "passed",
              "linked_dylib_sha256": hashlib.sha256((output / "force-loaded.dylib").read_bytes()).hexdigest(),
              "apple_linker_execution": "performed" if sys.platform == "darwin" else "not_run",
              "ios_application_build": "not_run", "ios_gameplay": "not_run"}
    (output / "evidence.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
