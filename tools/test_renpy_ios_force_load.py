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
    start = framework.index("    local archive_link_args=() archive\n")
    end = framework.index("    local minimum_flag=", start)
    actual_builder = framework[start:end]
    link_start = framework.index("    xcrun --sdk \"$IOS_SDK\" clang++")
    link_end = framework.index('\n        -o "$RENPY_FRAMEWORK_OUTPUT/$RENPY_FRAMEWORK_NAME"', link_start)
    actual_link = framework[link_start:link_end]
    assert actual_link.count('"${archive_link_args[@]}"') == 1, "Production link must use the checked argv array"
    assert "-all_load" not in actual_link and "-noall_load" not in actual_link
    shell = "set -euo pipefail\n" + "\n".join(functions) + "\n"
    shell += 'arguments() {\n    local prebuilt="$1"\n' + actual_builder
    shell += '    printf "%s\\0" "${archive_link_args[@]}"\n}\narguments "$1"\n'
    output = run(["bash", "-c", shell, "force-load-regression", prebuilt])
    return [part.decode() for part in output.rstrip(b"\0").split(b"\0")]


def linked_identity(data):
    assert struct.unpack_from("<II", data) == (0xFEEDFACF, 0x0100000C), "Output must be real ARM64 Mach-O"
    assert struct.unpack_from("<I", data, 12)[0] == 6, "Output must be a linked Mach-O dylib"
    commands, position, platforms, dependencies = struct.unpack_from("<I", data, 16)[0], 32, [], []
    end = position + struct.unpack_from("<I", data, 20)[0]
    assert end <= len(data), "Truncated actual Mach-O load commands"
    for _ in range(commands):
        command, size = struct.unpack_from("<II", data, position)
        assert size >= 8 and position + size <= end, "Invalid actual Mach-O load command"
        if command == 0x32:  # LC_BUILD_VERSION
            platforms.append(struct.unpack_from("<I", data, position + 8)[0])
        elif command == 0xC:  # LC_LOAD_DYLIB
            name_offset = struct.unpack_from("<I", data, position + 8)[0]
            assert 24 <= name_offset < size, "Invalid actual dylib dependency name"
            dependencies.append(data[position + name_offset:position + size].split(b"\0", 1)[0].decode())
        position += size
    assert position == end and platforms == [7], "Linked dylib must target the Simulator platform"
    return dependencies


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
        runtime_flags = []  # Apple dylibs require the selected SDK's libSystem.
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
        runtime_flags = ["-nostdlib"]  # No Apple SDK or fabricated libSystem on Linux.
    def object_file(name, text):
        source, obj = output / (name + ".c"), output / (name + ".o")
        source.write_text(text + "\n")
        run([*compiler, "-c", source, "-o", obj])
        return obj

    def archive(name, objects):
        path = prebuilt / name
        path.unlink(missing_ok=True)
        run([*archiver, "rcs", path, *objects])
        assert archive_tools.archive_identity(path) == [{"architecture": "arm64", "objects": len(objects), "platform": 7}]
        return path

    # The adapter's API objects require explicit retention. Its initializer
    # references genuine-style static registration tables, whose function
    # pointers retain every module object through ordinary archive extraction.
    adapter = [object_file("adapter-bootstrap", """
int fixture_renpy_init(void); int fixture_python_init(void);
int fixture_sdl(void); int fixture_image(void);
int fixture_adapter_bootstrap(void) {
    return fixture_renpy_init() + fixture_python_init() + fixture_sdl() + fixture_image();
}
"""), object_file("adapter-lifecycle", "int fixture_unreferenced_lifecycle(void) { return 1; }"),
        object_file("adapter-greenlet", "int fixture_unreferenced_greenlet(void) { return 2; }")]
    archive("librenpython.a", adapter)
    modules = [f"fixture_module_{index}" for index in range(14)]

    def module_table(name, selected):
        declarations = "\n".join(f"int {symbol}(void);" for symbol in selected)
        table = ", ".join(selected)
        return object_file(name, declarations + f"\nint (*const {name}_table[])(void) = {{ {table} }};\n"
                           + f"int fixture_{name}_init(void) {{ return {name}_table[0](); }}")

    renpy_modules = [object_file(symbol, f"int fixture_hb_main(void); int fixture_late_dependency(void);\n"
                              + f"int {symbol}(void) {{ return fixture_hb_main() + fixture_late_dependency(); }}")
                     for symbol in modules[:10]]
    inittab = module_table("renpy", modules[:10])
    # Actual pinned tasks/librenpy.py appends inittab.o to objects and supplies
    # it to ar again. Reproduce both real archive members; do not erase one.
    archive("librenpy.a", [*renpy_modules, inittab, inittab])
    assert run([*archiver, "t", prebuilt / "librenpy.a"]).decode().splitlines().count(inittab.name) == 2
    python_modules = [object_file(symbol, f"int {symbol}(void) {{ return 3; }}") for symbol in modules[10:]]
    archive("libpython3.12.a", [*python_modules, module_table("python", modules[10:])])
    archive("libSDL2.a", [object_file("sdl", "int fixture_sdl(void) { return 4; }")])
    archive("libSDL2_image.a", [object_file("image", "int fixture_jpeg_common(void);\n"
                                                    "int fixture_image(void) { return fixture_jpeg_common(); }")])
    archive("libdependency, optional.a", [object_file("late-dependency", "int fixture_late_dependency(void) { return 5; }")])
    archive("libjpeg.a", [object_file("jpeg-common", "int fixture_jpeg_common(void) { return 6; }")])
    archive("libturbojpeg.a", [object_file("turbojpeg-common", "int fixture_jpeg_common(void) { return 6; }\n"
                                                               "int fixture_unused_turbo_api(void) { return 7; }")])
    archive("libharfbuzz.a", [object_file("hb-main", "int fixture_hb_shared(void);\n"
                                                    "int fixture_hb_main(void) { return fixture_hb_shared(); }"),
                             object_file("hb-static", "int fixture_hb_shared(void) { return 8; }")])
    for variant in ("cairo", "subset"):
        archive(f"libharfbuzz-{variant}.a", [object_file(f"hb-{variant}-static", "int fixture_hb_shared(void) { return 8; }\n"
                                                        + f"int fixture_unused_{variant}_api(void) {{ return 9; }}")])
    excluded_symbols = []
    for index, name in enumerate((*EXCLUDED, "ordinary.a")):
        symbol = f"fixture_excluded_{index}"
        archive(name, [object_file(symbol, f"int {symbol}(void) {{ return 10; }}")])
        excluded_symbols.append("_" + symbol)
    selected_names = (*ROOTS, *sorted(path.name for path in prebuilt.glob("lib*.a") if path.name not in (*ROOTS, *EXCLUDED)))
    nested = prebuilt / "nested"
    nested.mkdir(exist_ok=True)
    shutil.copy2(prebuilt / "ordinary.a", nested / "libnested.a")
    actual = production_arguments(prebuilt)
    expected_paths = [str(prebuilt / name) for name in selected_names]
    assert actual[:4] == ["-Xlinker", "-force_load", "-Xlinker", expected_paths[0]], actual
    assert actual[4:] == expected_paths[1:], "All other archives must remain as ordinary linker inputs"
    assert len(set(expected_paths)) == len(expected_paths), "Each archive must be linked once"
    entry = output / "entry.c"
    entry.write_text("int framework_entry(void) { return 0; }\n")
    entry_object = output / "entry.o"
    run([*compiler, "-c", entry, "-o", entry_object])
    exports = output / "exports.txt"
    exports.write_text("_framework_entry\n")
    common = [*compiler, "-dynamiclib", *runtime_flags, *linker_flags, entry_object]
    adapter_symbols = {"_fixture_adapter_bootstrap", "_fixture_unreferenced_lifecycle", "_fixture_unreferenced_greenlet"}
    module_symbols = {"_" + name for name in modules}
    dependency_symbols = {"_fixture_renpy_init", "_fixture_python_init", "_fixture_sdl", "_fixture_image",
                          "_fixture_jpeg_common", "_fixture_hb_main", "_fixture_hb_shared", "_fixture_late_dependency"}
    wanted = adapter_symbols | module_symbols | dependency_symbols
    for label, archives in (("control", expected_paths), ("force-loaded", actual)):
        library = output / (label + ".dylib")
        command = [*common, *archives, prebuilt / "ordinary.a", "-Xlinker", "-exported_symbols_list",
                   "-Xlinker", exports, "-o", library]
        run(command)
        data = library.read_bytes()
        dependencies = linked_identity(data)
        if sys.platform == "darwin":
            assert "/usr/lib/libSystem.B.dylib" in dependencies, "Apple link must use the real SDK's libSystem"
        else:
            assert not dependencies, "Linux archive semantics test must not use a fake Apple runtime"
        names = {line.split()[-1] for line in run([*nm, library]).decode().splitlines() if line.split()}
        assert (wanted <= names if label == "force-loaded" else not wanted.intersection(names)), names
        assert not set(excluded_symbols).intersection(names)
        assert "_fixture_unused_turbo_api" not in names
        assert len({"_fixture_unused_cairo_api", "_fixture_unused_subset_api"}.intersection(names)) <= 1
        assert "_framework_entry" in names
    old_force_all = [argument for path in expected_paths for argument in ("-Xlinker", "-force_load", "-Xlinker", path)]
    old_command = [*common, *old_force_all, "-o", output / "invalid-all-force.dylib"]
    failed = subprocess.run(list(map(str, old_command)), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    diagnostic = failed.stderr.decode()
    assert failed.returncode != 0, "The old force-all variant and repeated-member graph must fail a real link"
    assert "duplicate symbol" in diagnostic and "fixture_renpy_init" in diagnostic and "fixture_jpeg_common" in diagnostic
    assert "fixture_hb_shared" in diagnostic, diagnostic
    (output / "old-force-all-error.log").write_text(diagnostic)
    report = {"status": "passed", "linker": linker_kind, "sdk": sdk,
              "standard_runtime_driver_flags": runtime_flags, "linked_platform": 7,
              "linked_system_dependencies": dependencies,
              "compiler_version": run(version_command).decode().splitlines()[0],
              "production_script_sha256": hashlib.sha256((REPO / "scripts/build_ios.sh").read_bytes()).hexdigest(),
              "selected_archives": len(expected_paths), "force_loaded_archives": ["librenpython.a"],
              "unreferenced_adapter_objects_retained": 2, "static_module_registration_objects_retained": len(modules),
              "referenced_dependency_functions_retained": len(dependency_symbols),
              "duplicate_inittab_members": 2, "old_force_all_duplicate_graph_rejected": True,
              "archive_paths_with_spaces_and_commas": "passed", "root_dedup_and_exclusion_boundaries": "passed",
              "unrelated_archive_not_force_loaded": "passed", "control_link_omits_unreferenced_objects": "passed",
              "linked_dylib_sha256": hashlib.sha256((output / "force-loaded.dylib").read_bytes()).hexdigest(),
              "apple_linker_execution": "performed" if sys.platform == "darwin" else "not_run",
              "ios_application_build": "not_run", "ios_gameplay": "not_run"}
    (output / "evidence.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
