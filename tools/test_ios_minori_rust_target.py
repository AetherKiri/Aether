#!/usr/bin/env python3
"""Configure the pinned production Minori CMake and inspect real Cargo rules.

Apple SDK names/platform variables are configuration inputs, not SDK/compiler
substitutes. Real CMake/Ninja/Cargo are required. No generated Cargo command,
Apple target compilation, application, or gameplay is executed by this check.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess


PIN = "7c56b2e7fbe5316d45aa30aedbd02fb5d9ba08c9"
ROOT_BASELINE = "8be1181db6c0305361e74ea13478355f26faaef6"


def run(argv: list[str], cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(argv, cwd=cwd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, timeout=60)


def checked(argv: list[str], cwd: Path) -> str:
    result = run(argv, cwd)
    if result.returncode:
        raise RuntimeError(f"{shlex.join(argv)} failed ({result.returncode}):\n{result.stdout}")
    return result.stdout


def integration(source: str) -> str:
    pattern = r"if\(AETHERKIRI_ENABLE_MINORI AND BUILD_GODOT_EXTENSION AND\s*\(LINUX OR APPLE OR ANDROID OR EMSCRIPTEN\)\)\n.*?endif\(\)"
    matches = re.findall(pattern, source, flags=re.S)
    if len(matches) != 1:
        raise RuntimeError("production Minori integration boundary changed")
    return matches[0]


def inspect(binary: Path, source: Path, ninja: str, expected: str,
            override: str | None, sdk: str, profile: str) -> dict:
    commands = checked([ninja, "-C", str(binary), "-t", "commands",
                        "aether_minori_runtime_build"], binary)
    cargo_commands = []
    for line in commands.splitlines():
        argv = shlex.split(line)
        if any(Path(arg).name == "cargo" and index + 1 < len(argv)
               and argv[index + 1] == "build" for index, arg in enumerate(argv)):
            cargo_commands.append(argv)
    if len(cargo_commands) != 1:
        raise AssertionError("expected exactly one genuine production Cargo build rule")
    argv = cargo_commands[0]
    targets = [argv[i + 1] for i, arg in enumerate(argv) if arg == "--target"]
    if targets != ([expected] if expected else []):
        raise AssertionError((targets, expected))
    if argv[argv.index("--manifest-path") + 1] != str(source / "packages/AetherMinori/Cargo.toml"):
        raise AssertionError("Cargo rule did not use the genuine pinned package manifest")
    if "--lib" not in argv or ("--release" in argv) != (profile == "Release"):
        raise AssertionError("production Cargo library/profile rule changed")
    archive, cache_value, outer_value, actual_sdk = (binary / "minori-state.txt").read_text().splitlines()
    selected_profile = "release" if profile == "Release" else "debug"
    subdir = expected + "/" if expected else ""
    wanted_archive = str(binary / "packages/AetherMinori/cargo-target" /
                         (subdir + selected_profile + "/libaether_minori_runtime.a"))
    if archive != wanted_archive or cache_value != (override or "") or outer_value != (override or ""):
        raise AssertionError((archive, cache_value, outer_value, wanted_archive, override))
    if actual_sdk != sdk:
        raise AssertionError("integration changed the actual SDK input")
    if (binary / "parent-target-file.txt").read_text() != archive:
        raise AssertionError("the root host cannot resolve the actual imported Minori target")
    target_dir = str(binary / "packages/AetherMinori/cargo-target")
    if f"CARGO_TARGET_DIR={target_dir}" not in argv:
        raise AssertionError("the actual Cargo output environment changed")
    return {"generated_cargo_target": expected or "host_default", "imported_archive": archive,
            "cache_override": cache_value, "automatic_default_leaked": False,
            "sdk_unchanged": True, "root_imported_target_reference": "passed", "cargo_build": "not_run"}


def configure(root: Path, label: str, repository: Path, block: str, cmake: str,
              ninja: str, cargo: str, *, system="iOS", apple=True, sdk="iphonesimulator",
              arch="arm64", processor="arm64", android=False, abi="", emscripten=False,
              override=None, expected="aarch64-apple-ios-sim", profile="Debug",
              failure=None, reuse=False, override_untyped=False) -> dict:
    source = root / label / "source"
    binary = root / label / "build"
    if not reuse:
        (source / "packages").mkdir(parents=True)
        (source / "packages/AetherMinori").symlink_to(repository / "packages/AetherMinori",
                                                    target_is_directory=True)
        (source / "cmake").symlink_to(repository / "cmake", target_is_directory=True)
        project = f"""cmake_minimum_required(VERSION 3.28)
project(MinoriTargetAcceptance LANGUAGES NONE)
# Input-only configuration fixture. No Apple compiler or SDK is probed.
set(CMAKE_SYSTEM_NAME "${{CASE_SYSTEM}}")
set(APPLE "${{CASE_APPLE}}")
set(LINUX FALSE)
if(CASE_SYSTEM STREQUAL "Linux")
    set(LINUX TRUE)
endif()
set(ANDROID "${{CASE_ANDROID}}")
set(ANDROID_ABI "${{CASE_ANDROID_ABI}}")
set(EMSCRIPTEN "${{CASE_EMSCRIPTEN}}")
set(CMAKE_OSX_SYSROOT "${{CASE_SDK}}")
set(CMAKE_OSX_ARCHITECTURES "${{CASE_ARCH}}")
set(CMAKE_SYSTEM_PROCESSOR "${{CASE_PROCESSOR}}")
set(AETHERKIRI_ENABLE_MINORI TRUE)
set(BUILD_GODOT_EXTENSION TRUE)
set(AETHERKIRI_MINORI_DIR "${{CMAKE_CURRENT_SOURCE_DIR}}/packages/AetherMinori")
{block}
if(NOT TARGET aether_minori_runtime OR NOT TARGET aether_minori_runtime_build)
    message(FATAL_ERROR "the root host cannot access the production Minori targets")
endif()
get_target_property(imported_global aether_minori_runtime IMPORTED_GLOBAL)
if(NOT imported_global)
    message(FATAL_ERROR "the production imported target is no longer GLOBAL")
endif()
add_library(minori_host_reference INTERFACE)
target_link_libraries(minori_host_reference INTERFACE aether_minori_runtime)
file(GENERATE OUTPUT "${{CMAKE_BINARY_DIR}}/parent-target-file.txt"
    CONTENT "$<TARGET_FILE:aether_minori_runtime>")
get_target_property(archive aether_minori_runtime IMPORTED_LOCATION)
get_property(cache_value CACHE AETHERKIRI_RUST_TARGET PROPERTY VALUE)
file(WRITE "${{CMAKE_BINARY_DIR}}/minori-state.txt"
    "${{archive}}\n${{cache_value}}\n${{AETHERKIRI_RUST_TARGET}}\n${{CMAKE_OSX_SYSROOT}}\n")
"""
        (source / "CMakeLists.txt").write_text(project)
    argv = [cmake, "-S", str(source), "-B", str(binary), "-G", "Ninja",
            f"-DCMAKE_MAKE_PROGRAM={ninja}", f"-DCARGO_EXECUTABLE:FILEPATH={cargo}",
            f"-DCMAKE_BUILD_TYPE:STRING={profile}", f"-DCASE_SYSTEM:STRING={system}",
            f"-DCASE_APPLE:BOOL={'ON' if apple else 'OFF'}", f"-DCASE_SDK:STRING={sdk}",
            f"-DCASE_ARCH:STRING={arch}", f"-DCASE_PROCESSOR:STRING={processor}",
            f"-DCASE_ANDROID:BOOL={'ON' if android else 'OFF'}", f"-DCASE_ANDROID_ABI:STRING={abi}",
            f"-DCASE_EMSCRIPTEN:BOOL={'ON' if emscripten else 'OFF'}"]
    if override is not None:
        override_name = "AETHERKIRI_RUST_TARGET" if override_untyped else "AETHERKIRI_RUST_TARGET:STRING"
        argv.append(f"-D{override_name}={override}")
    result = run(argv, root)
    (root / label / ("reconfigure.log" if reuse else "configure.log")).write_text(result.stdout)
    if failure:
        if result.returncode == 0 or failure not in result.stdout:
            raise AssertionError((label, "expected genuine configure rejection", result.stdout))
        return {"name": label, "configuration_rejection": "passed", "expected_reason": failure}
    if result.returncode:
        raise RuntimeError(result.stdout)
    record = inspect(binary, source, ninja, expected, override, sdk, profile)
    record.update(name=label, sdk_input=sdk, arch=arch, explicit_override=override)
    return record


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--cmake", default=shutil.which("cmake"))
    parser.add_argument("--ninja", default=shutil.which("ninja"))
    parser.add_argument("--cargo", default=shutil.which("cargo"))
    parser.add_argument("--baseline-commit", default=ROOT_BASELINE,
                        help="Genuine pre-fix root integration for the negative control")
    args = parser.parse_args()
    repository = args.repository.resolve(strict=True)
    root = args.output_dir.resolve()
    root.mkdir(parents=True, exist_ok=False)
    for tool in (args.cmake, args.ninja, args.cargo):
        if not tool or not Path(tool).is_file():
            raise RuntimeError("genuine CMake, Ninja and Cargo are required")
    package = repository / "packages/AetherMinori"
    if checked(["git", "rev-parse", "HEAD"], package).strip() != PIN:
        raise AssertionError("use the genuine pinned public Minori checkout")
    package_cmake = (package / "CMakeLists.txt").read_bytes()
    if package_cmake != subprocess.check_output(["git", "show", "HEAD:CMakeLists.txt"], cwd=package):
        raise AssertionError("the public Minori CMake source was modified")
    current = integration((repository / "CMakeLists.txt").read_text())
    baseline = integration(checked(["git", "show", f"{args.baseline_commit}:CMakeLists.txt"], repository))
    if "aetherkiri_add_minori_runtime" not in current or "add_subdirectory" not in baseline:
        raise AssertionError("review the current/pinned pre-fix integration boundaries")
    arguments = dict(repository=repository, block=current, cmake=args.cmake,
                     ninja=args.ninja, cargo=args.cargo)
    cases = []
    for arch, expected in (("arm64", "aarch64-apple-ios-sim"),
                           ("aarch64", "aarch64-apple-ios-sim"), ("x86_64", "x86_64-apple-ios")):
        for label, sdk in (("alias", "iphonesimulator"), ("mixed-alias", "iPhOnEsImUlAtOr"),
                           ("canonical", "/Applications/Xcode.app/SDKs/iPhoneSimulator26.5.sdk"),
                           ("spaces", "/Applications/Xcode Selected.app/SDKs/iPhOnEsImUlAtOr26.5.sdk"),
                           ("unversioned", "/Applications/Xcode.app/SDKs/iPhoneSimulator.sdk")):
            cases.append(configure(root, f"sim-{arch}-{label}", **arguments,
                                   sdk=sdk, arch=arch, expected=expected))
    for label, sdk in (("alias", "iphoneos"), ("mixed-alias", "iPhOnEoS"),
                       ("canonical", "/Applications/Xcode.app/SDKs/iPhoneOS26.5.sdk"),
                       ("misleading-parent", "/tmp/iphonesimulator/iPhoneSimulator.platform/SDKs/iPhoneOS26.5.sdk")):
        cases.append(configure(root, "device-" + label, **arguments, sdk=sdk,
                               expected="aarch64-apple-ios"))
    cases.extend([
        configure(root, "sim-processor-fallback", **arguments, arch="", processor="arm64"),
        configure(root, "sim-explicit-empty-cache", **arguments, override=""),
        configure(root, "sim-explicit-target", **arguments, override="x86_64-apple-ios",
                  expected="x86_64-apple-ios"),
        configure(root, "sim-explicit-untyped-cache", **arguments, override="x86_64-apple-ios",
                  override_untyped=True, expected="x86_64-apple-ios"),
        configure(root, "device-explicit-target", **arguments, sdk="iphoneos",
                  override="aarch64-apple-ios-sim", expected="aarch64-apple-ios-sim"),
        configure(root, "sim-explicit-target-unsupported-arch", **arguments, arch="riscv64",
                  override="x86_64-apple-ios", expected="x86_64-apple-ios"),
        configure(root, "sim-release", **arguments, profile="Release"),
        configure(root, "sim-unsupported-arch", **arguments, arch="riscv64",
                  failure="Minori has no Rust target mapping for iOS Simulator architecture"),
        configure(root, "sim-multiple-arch", **arguments, arch="arm64;x86_64",
                  failure="Minori has no Rust target mapping for iOS Simulator architecture"),
    ])
    for arch, expected in (("arm64", "aarch64-apple-darwin"), ("x86_64", "x86_64-apple-darwin")):
        cases.append(configure(root, "mac-" + arch, **arguments, system="Darwin", sdk="macosx",
                               arch=arch, expected=expected))
    for abi, expected in (("arm64-v8a", "aarch64-linux-android"),
                          ("armeabi-v7a", "armv7-linux-androideabi"), ("x86_64", "x86_64-linux-android")):
        cases.append(configure(root, "android-" + abi, **arguments, system="Android", apple=False,
                               android=True, abi=abi, expected=expected))
    cases.extend([
        configure(root, "linux-host-default", **arguments, system="Linux", apple=False, expected=""),
        configure(root, "linux-explicit-target", **arguments, system="Linux", apple=False,
                  override="x86_64-unknown-linux-gnu", expected="x86_64-unknown-linux-gnu"),
        configure(root, "emscripten", **arguments, system="Emscripten", apple=False,
                  emscripten=True, expected="wasm32-unknown-emscripten"),
        configure(root, "android-unsupported-abi", **arguments, system="Android", apple=False,
                  android=True, abi="mips", failure="Minori has no Rust target mapping for Android ABI"),
    ])
    # Reconfigure the same genuine projects; automatic target values must not
    # stick in the cache when switching SDK, whereas an explicit override does.
    transitions = [configure(root, "sdk-transition", **arguments, sdk="iphoneos",
                             expected="aarch64-apple-ios")]
    transitions.append(configure(root, "sdk-transition", **arguments, reuse=True))
    transitions.append(configure(root, "sdk-transition", **arguments, reuse=True,
                                 arch="x86_64", expected="x86_64-apple-ios"))
    transitions.append(configure(root, "sdk-transition", **arguments, reuse=True,
                                 sdk="iphoneos", expected="aarch64-apple-ios"))
    transitions.append(configure(root, "sdk-transition", **arguments, reuse=True,
                                 system="Darwin", sdk="macosx", expected="aarch64-apple-darwin"))
    transitions.append(configure(root, "sdk-transition", **arguments, reuse=True,
                                 system="Linux", apple=False, expected=""))
    transitions.append(configure(root, "explicit-transition", **arguments,
                                 override="x86_64-apple-ios", expected="x86_64-apple-ios"))
    transitions.append(configure(root, "explicit-transition", **arguments, reuse=True,
                                 sdk="iphoneos", override="x86_64-apple-ios", expected="x86_64-apple-ios"))
    transitions.append(configure(root, "explicit-transition", **arguments, reuse=True,
                                 sdk="iphoneos", override="", expected="aarch64-apple-ios"))
    transitions.append(configure(root, "explicit-transition", **arguments, reuse=True,
                                 override=""))
    # The genuine pre-fix root block and full pinned package still produce the
    # actual erroneous device target for the canonical Simulator SDK path.
    old_arguments = dict(arguments, block=baseline)
    old = configure(root, "pre-fix-canonical-simulator", **old_arguments,
                    sdk="/Applications/Xcode.app/SDKs/iPhoneSimulator26.5.sdk",
                    expected="aarch64-apple-ios")
    evidence = {"status": "passed", "package_head": PIN,
                "package_cmake_sha256": hashlib.sha256(package_cmake).hexdigest(),
                "source_sha256": {str(path.relative_to(repository)): hashlib.sha256(path.read_bytes()).hexdigest()
                                  for path in (repository / "CMakeLists.txt",
                                               repository / "cmake/AetherKiriMinori.cmake", Path(__file__).resolve())},
                "tools": {"cmake": checked([args.cmake, "--version"], root).splitlines()[0],
                          "ninja": checked([args.ninja, "--version"], root).strip(),
                          "cargo": checked([args.cargo, "--version"], root).strip()},
                "configuration_cases": cases, "cache_sdk_transitions": transitions,
                "baseline_commit": args.baseline_commit,
                "genuine_pre_fix_negative_control": old, "apple_target_compile": "not_run",
                "cargo_build": "not_run", "application": "not_run", "gameplay": "not_run"}
    (root / "evidence.json").write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"status": "passed", "configuration_cases": len(cases),
                      "cache_sdk_transitions": len(transitions), "genuine_pre_fix_negative_control": "passed",
                      "apple_target_compile": "not_run", "application": "not_run", "gameplay": "not_run"}))


if __name__ == "__main__":
    main()
