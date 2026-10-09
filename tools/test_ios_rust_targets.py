#!/usr/bin/env python3
"""Exercise production Rust target selection and generated Cargo commands.

The SDK names and Apple platform variables below are configuration fixtures.
This runs real CMake/Ninja and existing host Rust tools, without compiling an
Apple target, substituting an SDK/compiler, or executing a generated build.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess


def run(argv: list[str], cwd: Path, env: dict[str, str]) -> str:
    result = subprocess.run(argv, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=60, check=False)
    if result.returncode:
        raise RuntimeError(f"{shlex.join(argv)} failed ({result.returncode}):\n{result.stdout}")
    return result.stdout


def quote(value: str | Path) -> str:
    value = str(value)
    if "]]" in value:
        raise ValueError("unsupported CMake bracket delimiter in input")
    return "[[" + value + "]]"


def fragment(source: str, start: str, end: str) -> str:
    if source.count(start) != 1 or source.count(end) != 1:
        raise RuntimeError("production CMake fragment boundaries changed")
    return source[source.index(start):source.index(end)]


def cargo_target(commands: str, subcommand: str) -> str:
    matches = []
    for line in commands.splitlines():
        args = shlex.split(line)
        if any(Path(arg).name == "cargo" and i + 1 < len(args)
               and args[i + 1] == subcommand for i, arg in enumerate(args)):
            if args.count("--target") != 1:
                raise RuntimeError("generated Cargo command lacks exactly one target")
            matches.append(args[args.index("--target") + 1])
    if len(matches) != 1:
        raise RuntimeError(f"expected one production Cargo {subcommand} command")
    return matches[0]


def configure_case(root: Path, name: str, sdk: str, arch: str,
                   expected: str, rfvp_expected: str, override: str | None,
                   repository: Path, siglus_helper: Path, rfvp_source: str,
                   cmake: str, ninja: str, env: dict[str, str], ios: bool = True) -> dict:
    source = root / name / "source"
    binary = root / name / "build"
    (source / "packages").mkdir(parents=True)
    (source / "packages" / "AetherSiglus").symlink_to(repository / "packages/AetherSiglus",
                                                    target_is_directory=True)
    selection = fragment(rfvp_source, "find_program(RFVP_CARGO cargo REQUIRED)",
                         "include(cmake/PrepareRfvpSources.cmake)")
    build = fragment(rfvp_source, 'set(rfvp_features "',
                     "add_library(aether_rfvp_rust STATIC IMPORTED GLOBAL)")
    (source / "rfvp-production-selection.cmake").write_text(selection)
    (source / "rfvp-production-build.cmake").write_text(build)
    production_siglus_dir = repository / "bridge/siglus_runtime"
    project = f"""cmake_minimum_required(VERSION 3.28)
project(RustTargetAcceptance LANGUAGES NONE)
# Controlled configuration inputs, not an Apple compiler or SDK probe.
set(APPLE TRUE)
set(IOS {'TRUE' if ios else 'FALSE'})
set(CMAKE_OSX_ARCHITECTURES {quote(arch)})
set(CMAKE_OSX_SYSROOT {quote(sdk)})
set(CMAKE_BUILD_TYPE Debug)
include({quote(siglus_helper)})
aetherkiri_deduce_rust_target(selected_siglus)
function(generate_siglus)
    set(CMAKE_CURRENT_SOURCE_DIR {quote(production_siglus_dir)})
    aetherkiri_add_siglus_rs(actual_siglus)
    if(NOT actual_siglus_FOUND)
        message(FATAL_ERROR "actual production Siglus target was skipped")
    endif()
    get_target_property(archive actual_siglus IMPORTED_LOCATION)
    file(WRITE "${{CMAKE_BINARY_DIR}}/siglus-archive.txt" "${{archive}}")
endfunction()
generate_siglus()
set(AETHERKIRI_RFVP_PROJECT_ROOT {quote(repository)})
set(AETHERKIRI_RFVP_DIR {quote(repository / 'packages/rfvp')})
include("${{CMAKE_CURRENT_SOURCE_DIR}}/rfvp-production-selection.cmake")
set(rfvp_prepared "${{CMAKE_BINARY_DIR}}/prepared")
include("${{CMAKE_CURRENT_SOURCE_DIR}}/rfvp-production-build.cmake")
file(WRITE "${{CMAKE_BINARY_DIR}}/selected.txt"
    "${{selected_siglus}}\n${{AETHERKIRI_RFVP_RUST_TARGET}}\n${{rfvp_library}}\n")
"""
    (source / "CMakeLists.txt").write_text(project)
    argv = [cmake, "-S", str(source), "-B", str(binary), "-G", "Ninja",
            f"-DCMAKE_MAKE_PROGRAM={ninja}"]
    if override is not None:
        argv.append(f"-DAETHERKIRI_RFVP_RUST_TARGET:STRING={override}")
    configure_log = run(argv, root, env)
    (root / name / "configure.log").write_text(configure_log)
    selected, rfvp_selected, rfvp_archive = (binary / "selected.txt").read_text().splitlines()
    siglus_commands = run([ninja, "-C", str(binary), "-t", "commands", "siglus_rs_cargo_build"], root, env)
    rfvp_commands = run([ninja, "-C", str(binary), "-t", "commands", "aether_rfvp_rust_build"], root, env)
    actual = (selected, cargo_target(siglus_commands, "rustc"),
              rfvp_selected, cargo_target(rfvp_commands, "build"))
    wanted = (expected, expected, rfvp_expected, rfvp_expected)
    if actual != wanted:
        raise AssertionError((name, actual, wanted))
    siglus_archive = (binary / "siglus-archive.txt").read_text()
    if f"/siglus-rs-target/{expected}/debug/libsiglus_scene_vm.a" not in siglus_archive:
        raise AssertionError((name, siglus_archive))
    if f"/target/{rfvp_expected}/debug/librfvp.a" not in rfvp_archive:
        raise AssertionError((name, rfvp_archive))
    # Reconfigure the genuine project to exercise the persistent cache too.
    run(argv, root, env)
    if (binary / "selected.txt").read_text().splitlines()[:2] != [expected, rfvp_expected]:
        raise AssertionError("reconfigure changed the selected target")
    return {"name": name, "sdk_fixture": sdk, "architecture": arch,
            "siglus_target": selected, "rfvp_target": rfvp_selected,
            "rfvp_explicit_override": override, "cargo_commands_generated": True,
            "cache_reconfigure": "pass", "target_compile": "not_run"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--cmake", default=shutil.which("cmake"))
    parser.add_argument("--ninja", default=shutil.which("ninja"))
    parser.add_argument("--baseline-commit", help="optional genuine pre-fix source for negative controls")
    args = parser.parse_args()
    repository = args.repository.resolve(strict=True)
    root = args.output_dir.resolve()
    root.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    for tool in (args.cmake, args.ninja, shutil.which("cargo"), shutil.which("rustc")):
        if not tool or not Path(tool).is_file():
            raise RuntimeError("real CMake, Ninja, cargo and rustc must be installed")
    siglus = repository / "bridge/siglus_runtime/cmake/BuildSiglusRs.cmake"
    rfvp_path = repository / "bridge/rfvp_runtime/CMakeLists.txt"
    rfvp = rfvp_path.read_text()
    versions = {"cmake": run([args.cmake, "--version"], root, env).splitlines()[0],
                "ninja": run([args.ninja, "--version"], root, env).strip(),
                "rustc": run([shutil.which("rustc"), "-vV"], root, env),
                "cargo": run([shutil.which("cargo"), "--version"], root, env).strip()}
    cases = []
    for arch, expected in (("arm64", "aarch64-apple-ios-sim"), ("x86_64", "x86_64-apple-ios")):
        for label, sdk in (("alias", "iphonesimulator"), ("mixed-alias", "iPhOnEsImUlAtOr"),
                           ("sdk", "/Applications/Xcode_26.6.app/SDKs/iPhoneSimulator26.5.sdk"),
                           ("spaces", "/Applications/Xcode Selected.app/SDKs/iPhOnEsImUlAtOr26.5.sdk"),
                           ("unversioned-sdk", "/Applications/Xcode.app/SDKs/iPhoneSimulator.sdk")):
            cases.append((f"sim-{arch}-{label}", sdk, arch, expected, expected, None, True))
    for label, sdk in (("alias", "iphoneos"), ("mixed-alias", "iPhOnEoS"),
                       ("sdk", "/Applications/Xcode_26.6.app/SDKs/iPhoneOS26.5.sdk"),
                       ("spaces", "/Applications/Xcode Selected.app/SDKs/iPhOnEoS26.5.sdk"),
                       ("misleading-parent", "/tmp/iphonesimulator/iPhoneSimulator.platform/SDKs/iPhoneOS26.5.sdk")):
        cases.append((f"device-{label}", sdk, "arm64", "aarch64-apple-ios", "aarch64-apple-ios", None, True))
    cases.extend([
        ("mac-arm64", "macosx", "arm64", "aarch64-apple-darwin", "aarch64-apple-darwin", None, False),
        ("mac-x64", "macosx", "x86_64", "x86_64-apple-darwin", "x86_64-apple-darwin", None, False),
        ("rfvp-explicit-sim", "/Applications/Xcode.app/SDKs/iPhoneSimulator26.5.sdk", "arm64",
         "aarch64-apple-ios-sim", "x86_64-apple-ios", "x86_64-apple-ios", True),
        ("rfvp-explicit-device", "iphoneos", "arm64", "aarch64-apple-ios",
         "aarch64-apple-ios-sim", "aarch64-apple-ios-sim", True),
    ])
    results = [configure_case(root, *case[:6], repository, siglus, rfvp, args.cmake,
                              args.ninja, env, ios=case[6]) for case in cases]
    # Execute the unchanged non-Apple mapper branches with real CMake/rustc.
    controls = root / "non-ios.cmake"
    controls.write_text(f"""include({quote(siglus)})
find_program(RUSTC_EXECUTABLE rustc REQUIRED)
function(check expected)
    aetherkiri_deduce_rust_target(actual)
    if(NOT actual STREQUAL expected)
        message(FATAL_ERROR "${{actual}} != ${{expected}}")
    endif()
endfunction()
set(WEB TRUE)
check(wasm32-unknown-unknown)
set(WEB FALSE)
set(EMSCRIPTEN TRUE)
check(wasm32-unknown-unknown)
set(EMSCRIPTEN FALSE)
set(ANDROID TRUE)
set(ANDROID_ABI arm64-v8a)
check(aarch64-linux-android)
set(ANDROID_ABI armeabi-v7a)
check(armv7-linux-androideabi)
set(ANDROID_ABI x86_64)
check(x86_64-linux-android)
set(ANDROID_ABI x86)
check(i686-linux-android)
set(ANDROID FALSE)
execute_process(COMMAND "${{RUSTC_EXECUTABLE}}" -vV OUTPUT_VARIABLE version COMMAND_ERROR_IS_FATAL ANY)
string(REGEX MATCH "host: ([^\n]+)" ignored "${{version}}")
check("${{CMAKE_MATCH_1}}")
""")
    run([args.cmake, "-P", str(controls)], root, env)
    baseline = {"negative_controls": "not_run"}
    if args.baseline_commit:
        old_siglus = root / "baseline-siglus.cmake"
        old_siglus.write_text(run(["git", "show", f"{args.baseline_commit}:{siglus.relative_to(repository)}"], repository, env))
        old_rfvp = run(["git", "show", f"{args.baseline_commit}:{rfvp_path.relative_to(repository)}"], repository, env)
        try:
            configure_case(root, "baseline-canonical-sdk", "/Applications/Xcode.app/SDKs/iPhoneSimulator26.5.sdk",
                           "arm64", "aarch64-apple-ios-sim", "aarch64-apple-ios-sim", None,
                           repository, old_siglus, old_rfvp, args.cmake, args.ninja, env)
        except AssertionError as error:
            actual = error.args[0][1]
            if actual != ("aarch64-apple-ios",) * 4:
                raise
            baseline = {"commit": args.baseline_commit, "negative_controls": "pass",
                        "actual_wrong_targets": list(actual)}
        else:
            raise AssertionError("genuine pre-fix source did not reproduce the wrong device target")
    evidence = {"status": "pass", "tools": versions,
                "regression_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                "production_source_sha256": {
                    str(path.relative_to(repository)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in (siglus, rfvp_path)},
                "configuration_and_command_cases": results, "non_ios_mapper_controls": 7,
                "baseline": baseline, "apple_sdk_compile": "not_run",
                "full_application": "not_run", "gameplay": "not_run"}
    (root / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps({"status": "pass", "configuration_and_command_cases": len(results),
                      "non_ios_mapper_controls": 7, "baseline": baseline,
                      "apple_sdk_compile": "not_run", "gameplay": "not_run"}))


if __name__ == "__main__":
    main()
