#!/usr/bin/env python3
"""Exercise the real legacy vcpkg command with OpenSSL 3.6.3 Configure.

This needs existing public OpenSSL/vcpkg checkouts and actual CMake, Bash, Perl
and a host compiler. It generates a native HOST Makefile/configdata with the
unmodified production wrapper. No SDK, compiler, Configure, or return value is
mocked; target Apple compilation/application/gameplay are explicitly NOT_RUN.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys


OPENSSL_COMMIT = "aae016bfd52fcad2bc9657c2c782cfdf73b1ed5f"
BASELINE = "9e593bb18ea69cc5095e012465dcd675a822ed0d"
REPOSITORY = Path(__file__).resolve().parents[1]
PORT = REPOSITORY / "vcpkg/ports/openssl"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def literal(value: str | Path) -> str:
    text = str(value)
    if "]==]" in text:
        raise ValueError("Unsupported CMake bracket terminator in input")
    return "[==[" + text + "]==]"


def block(recipe: str, name: str) -> str:
    begin = "# AETHER_OPENSSL_IOS_TRIPLET_" + name + "_BEGIN\n"
    end = "# AETHER_OPENSSL_IOS_TRIPLET_" + name + "_END\n"
    if recipe.count(begin) != 1 or recipe.count(end) != 1:
        raise RuntimeError("The production iOS triplet block is missing or ambiguous")
    return recipe.split(begin)[1].split(end)[0]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openssl-source", type=Path, required=True)
    parser.add_argument("--vcpkg-source", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--cmake", default="cmake")
    args = parser.parse_args()
    source = args.openssl_source.resolve(strict=True)
    vcpkg = args.vcpkg_source.resolve(strict=True)
    output = args.output_dir.resolve()
    if any(any(c.isspace() for c in str(p)) for p in (source, vcpkg, output)):
        parser.error("The unmodified upstream wrapper requires paths without whitespace")
    if sys.platform not in ("linux", "darwin"):
        parser.error("This real host Configure regression supports Linux or macOS")
    commit = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"],
                                     text=True).strip()
    if commit != OPENSSL_COMMIT:
        raise RuntimeError(f"Expected genuine OpenSSL 3.6.3 {OPENSSL_COMMIT}, got {commit}")
    subprocess.run(["git", "-C", str(source), "diff", "--exit-code", "HEAD", "--"],
                   check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    wrapper = PORT / "unix/configure"
    original = subprocess.check_output(
        ["git", "-C", str(vcpkg), "show", f"{BASELINE}:ports/openssl/unix/configure"])
    if wrapper.read_bytes() != original:
        raise RuntimeError("The production wrapper differs from the pinned original")
    cmake, perl, bash, cc = (shutil.which(x) for x in (args.cmake, "perl", "bash", "cc"))
    if not all((cmake, perl, bash, cc)):
        raise RuntimeError("Actual CMake, Perl, Bash and the host compiler are required")
    output.mkdir(parents=True, exist_ok=False)
    recipe = (PORT / "unix/portfile.cmake").read_text()
    normalize, restore = block(recipe, "NORMALIZE"), block(recipe, "RESTORE")
    ios_body = recipe.split("elseif(VCPKG_TARGET_IS_IOS)\n")[1].split(
        "elseif(VCPKG_TARGET_IS_TVOS OR VCPKG_TARGET_IS_WATCHOS)")[0]
    helper = vcpkg / "scripts/cmake/vcpkg_configure_make.cmake"
    helper_text = helper.read_text()
    commands = [line.strip() for line in helper_text.splitlines()
                if line.strip().startswith('set(command "${base_cmd}" -c "${configure_env} ./')]
    if len(commands) != 1:
        raise RuntimeError("The real legacy vcpkg command construction changed")
    quote_begin = '    foreach(var IN ITEMS arg_OPTIONS arg_OPTIONS_RELEASE arg_OPTIONS_DEBUG)\n'
    quote_loop = helper_text.split(quote_begin)[1].split(
        "\n    foreach(current_buildtype IN LISTS all_buildtypes)")[0]
    quote_loop = quote_begin + quote_loop
    # These are actual public production functions, not local lookalikes.
    includes = "".join("include(" + literal(path) + ")\n" for path in (
        vcpkg / "scripts/cmake/z_vcpkg_function_arguments.cmake",
        vcpkg / "scripts/cmake/vcpkg_list.cmake",
        vcpkg / "ports/vcpkg-make/vcpkg_scripts.cmake",
        vcpkg / "ports/vcpkg-make/vcpkg_make.cmake",
    ))
    checks = includes + "\n"
    for arch, sdk, expected in (
        ("arm64", "iphonesimulator", "iossimulator-arm64-xcrun"),
        ("arm64", "iphoneos", "ios64-xcrun"),
        ("arm", "iphoneos", "ios-xcrun"),
        ("x64", "iphonesimulator", "iossimulator-xcrun"),
        ("x86", "iphonesimulator", "iossimulator-xcrun"),
    ):
        checks += f'set(VCPKG_TARGET_ARCHITECTURE {arch})\nset(VCPKG_OSX_SYSROOT {sdk})\n'
        checks += ios_body
        checks += f'if(NOT OPENSSL_ARCH STREQUAL "{expected}")\nmessage(FATAL_ERROR "Wrong actual OpenSSL target: ${{OPENSSL_ARCH}}")\nendif()\n'
    # Leave non-iOS/undefined/empty contexts exactly as the actual caller set
    # them, and prove modern make still receives the original two arguments.
    checks += 'include(' + literal(REPOSITORY / "vcpkg/triplets/arm64-ios-simulator.cmake") + ')\n'
    checks += '''set(VCPKG_TARGET_IS_IOS TRUE)
set(original_triplet "${VCPKG_MAKE_BUILD_TRIPLET}")
''' + normalize + restore + '''
if(NOT VCPKG_MAKE_BUILD_TRIPLET STREQUAL original_triplet)
message(FATAL_ERROR "The production recipe did not restore the original triplet list")
endif()
z_vcpkg_make_get_configure_triplets(modern_triplets)
if(NOT modern_triplets STREQUAL original_triplet)
message(FATAL_ERROR "The real modern make helper lost the original argv")
endif()
z_vcpkg_make_get_crosscompiling(is_cross ${modern_triplets})
if(NOT is_cross)
message(FATAL_ERROR "The real modern make helper lost cross-compilation detection")
endif()
set(VCPKG_TARGET_IS_IOS FALSE)
''' + normalize + restore + '''
if(NOT VCPKG_MAKE_BUILD_TRIPLET STREQUAL original_triplet)
message(FATAL_ERROR "Non-iOS triplet context was modified")
endif()
set(VCPKG_TARGET_IS_IOS TRUE)
unset(VCPKG_MAKE_BUILD_TRIPLET)
''' + normalize + restore + '''
if(DEFINED VCPKG_MAKE_BUILD_TRIPLET)
message(FATAL_ERROR "An undefined caller variable became defined")
endif()
set(VCPKG_MAKE_BUILD_TRIPLET "")
''' + normalize + restore + '''
if(NOT DEFINED VCPKG_MAKE_BUILD_TRIPLET OR NOT VCPKG_MAKE_BUILD_TRIPLET STREQUAL "")
message(FATAL_ERROR "The empty caller variable was not preserved")
endif()
'''
    check_file = output / "production-scope.cmake"
    check_file.write_text(checks)
    env = os.environ.copy()
    result = subprocess.run([cmake, "-P", str(check_file)], cwd=output, env=env,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / "production-scope.log").write_text(result.stdout)
    if result.returncode:
        raise RuntimeError("Actual production scope/modern-helper checks failed; see production-scope.log")

    arm64 = platform.machine().lower() in ("aarch64", "arm64")
    target = ("darwin64-arm64" if arm64 else "darwin64-x86_64") if sys.platform == "darwin" \
        else ("linux-aarch64" if arm64 else "linux-x86_64")
    cases = {}
    for label in ("original", "patched"):
        directory = output / label
        directory.mkdir()
        script = includes + 'include(' + literal(REPOSITORY / "vcpkg/triplets/arm64-ios-simulator.cmake") + ')\n'
        script += 'set(VCPKG_TARGET_IS_IOS TRUE)\nset(original_triplet "${VCPKG_MAKE_BUILD_TRIPLET}")\n'
        if label == "patched":
            script += normalize
        script += 'set(arg_BUILD_TRIPLET ${VCPKG_MAKE_BUILD_TRIPLET})\n'
        script += 'set(base_cmd ' + literal(bash) + ')\n'
        script += 'set(configure_env ' + literal("CC='" + cc + "'") + ')\n'
        relative = os.path.relpath(wrapper.parent, directory)
        script += 'set(relative_build_path ' + literal(relative) + ')\n'
        script += 'set(arg_OPTIONS ' + ' '.join(literal(x) for x in (
            perl, source / "Configure", target, "no-tests", "no-apps", "no-shared", "no-module")) + ')\n'
        script += 'set(arg_OPTIONS_DEBUG --debug)\nset(current_buildtype DEBUG)\n' + quote_loop + '\n'
        script += commands[0] + '\nlist(LENGTH command argv_count)\n'
        script += '''execute_process(COMMAND ${command}
WORKING_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}" INPUT_FILE /dev/null
RESULT_VARIABLE rc OUTPUT_FILE configure-out.log ERROR_FILE configure-err.log)
file(WRITE "${CMAKE_CURRENT_LIST_DIR}/result.txt" "${rc}\\n${argv_count}\\n")
'''
        if label == "patched":
            script += restore + '\n'
            script += '''if(NOT VCPKG_MAKE_BUILD_TRIPLET STREQUAL original_triplet)
message(FATAL_ERROR "Legacy call altered the caller's modern helper triplet")
endif()
'''
        cmake_file = directory / "configure.cmake"
        cmake_file.write_text(script)
        result = subprocess.run([cmake, "-P", str(cmake_file)], cwd=directory,
                                env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (directory / "cmake.log").write_text(result.stdout)
        if result.returncode:
            raise RuntimeError(f"Actual CMake command failed; see {directory}/cmake.log")
        cases[label] = (directory / "result.txt").read_text().splitlines()
    if cases["original"] != ["0", "4"] or (output / "original/Makefile").exists() \
            or (output / "original/configdata.pm").exists():
        raise RuntimeError("Original actual argv did not reproduce the zero-exit/missing-Makefile failure")
    if cases["patched"] != ["0", "3"] or not (output / "patched/Makefile").is_file() \
            or not (output / "patched/configdata.pm").is_file():
        raise RuntimeError("Patched actual argv did not run the genuine OpenSSL generator")
    dump = subprocess.run([perl, "configdata.pm", "--dump"], cwd=output / "patched",
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=True)
    (output / "patched/configdata-dump.log").write_text(dump.stdout)
    if "3.6.3" not in dump.stdout or target not in dump.stdout:
        raise RuntimeError("The real configdata does not identify the pinned OpenSSL host target")
    evidence = {
        "status": "PASS", "scope": "genuine-openssl-host-configuration",
        "openssl_commit": commit, "openssl_version": "3.6.3", "host_target": target,
        "cmake_version": subprocess.check_output([cmake, "--version"], text=True).splitlines()[0],
        "original_zero_exit_missing_makefile": "PASS", "production_ios_join_restore": "PASS",
        "modern_make_list_and_cross_detection": "PASS", "production_target_and_context_gates": "PASS",
        "actual_host_makefile_configdata": "PASS", "configure_sha256": sha(source / "Configure"),
        "production_wrapper_sha256": sha(wrapper), "legacy_helper_sha256": sha(helper),
        "production_recipe_sha256": sha(PORT / "unix/portfile.cmake"),
        "apple_ios_sdk_build_link": "NOT_RUN", "ios_app_gameplay": "NOT_RUN",
    }
    (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, sort_keys=True))


if __name__ == "__main__":
    main()
