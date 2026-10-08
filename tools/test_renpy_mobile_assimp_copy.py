#!/usr/bin/env python3
"""Build the actual pinned Assimp recipe and execute host ownership checks.

This runs the real download/build tasks, compiler, library and C++ objects.
It does not compile an iOS target or execute Ren'Py/mobile gameplay.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
BUILD_PIN = "7bfab40c1174f622f644b24669afd5fb167fbb79"
ASSIMP_PIN = "c35200e38ea8f058812b83de2ef32c6093b0ece2"


def command(arguments, *, cwd):
    result = subprocess.run(list(map(str, arguments)), cwd=cwd,
                            text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=1200)
    if result.returncode:
        raise RuntimeError(f"Host command failed ({result.returncode}):\n{result.stdout[-8000:]}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_source", type=Path)
    parser.add_argument("--compiler", default=shutil.which("clang++"))
    args = parser.parse_args()
    if not args.compiler:
        raise SystemExit("A genuine Clang 21 or later host C++ compiler is required.")
    # Preserve clang++'s argv[0] so its C++ driver also links the standard library.
    compiler = Path(args.compiler).absolute()
    assert compiler.is_file()
    version = command([compiler, "--version"], cwd=REPO)
    detected = re.search(r"clang version (\d+)\.", version)
    if not detected or int(detected[1]) < 21:
        raise SystemExit("The nontrivial object-copy regression requires genuine Clang 21 or later.")
    c_compiler = compiler.with_name("clang")
    assert c_compiler.is_file()
    assert command(["git", "rev-parse", "HEAD"], cwd=args.build_source).strip() == BUILD_PIN
    patches = sorted((REPO / "bridge/renpy_runtime/mobile_launcher/patches/native").glob(
        "[0-9][0-9][0-9][0-9]-*.patch"))
    assert any(path.name.startswith("0011-") for path in patches)
    with tempfile.TemporaryDirectory(prefix="renpy-real-assimp-copy-") as directory:
        root = Path(directory) / "renpy-build"
        command(["git", "clone", "--no-local", "--depth=1", "--single-branch", "--quiet", "--no-checkout",
                 args.build_source.resolve(), root], cwd=REPO)
        command(["git", "checkout", "--quiet", "--detach", BUILD_PIN], cwd=root)
        command([sys.executable, REPO / "tools/apply_renpy_mobile_patch_series.py",
                 "--checkout", root, "--pin", BUILD_PIN, *patches], cwd=REPO)
        sys.path.insert(0, str(root))
        from renpybuild.context import Context
        from renpybuild.task import annotators, tasks
        # Load the unchanged Assimp task without importing unrelated SDK tasks.
        specification = importlib.util.spec_from_file_location("assimp", root / "tasks/assimp.py")
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)

        def host_compiler(context):
            context.env("CC", str(c_compiler))
            context.env("CXX", str(compiler))
            context.env("CXXFLAGS", "-Werror=nontrivial-memcall {{ CXXFLAGS }}")
            context.env("CMAKE_BUILD_PARALLEL_LEVEL", str(min(os.cpu_count() or 1, 4)))
            context.var("cmake_args", "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON")

        annotators.append(host_compiler)
        selected = {task.task: task for task in tasks if task.name == "assimp"}
        context = Context("host", "host", "3", root, SimpleNamespace())
        selected["download"].run(context)
        source = context.tmp / "source/assimp"
        assert command(["git", "rev-parse", "HEAD"], cwd=source).strip() == ASSIMP_PIN
        selected["build"].run(context)
        recipes = json.loads((context.build / "compile_commands.json").read_text())
        scene = [entry for entry in recipes if entry["file"].endswith("/Common/SceneCombiner.cpp")]
        assert len(scene) == 1 and "-Werror=nontrivial-memcall" in scene[0]["command"]
        assert "-Wno-nontrivial-memcall" not in scene[0]["command"]

        project = Path(directory) / "drivers"
        project.mkdir()
        (project / "CMakeLists.txt").write_text("""cmake_minimum_required(VERSION 3.20)
project(RealAssimpOwnership LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
find_package(assimp CONFIG REQUIRED)
add_executable(ownership "${DRIVER_ROOT}/ownership.cpp")
target_link_libraries(ownership PRIVATE assimp::assimp)
add_executable(constructors "${DRIVER_ROOT}/constructors.cpp")
target_include_directories(constructors PRIVATE "${ASSIMP_SOURCE}/contrib/Open3DGC")
foreach(target ownership constructors)
  target_compile_options(${target} PRIVATE -Wall -Wextra -Werror -Werror=nontrivial-memcall -UNDEBUG)
endforeach()
""")
        driver_build = project / "build"
        command(["cmake", "-S", project, "-B", driver_build,
                 "-DCMAKE_CXX_COMPILER=" + str(compiler),
                 "-DCMAKE_PREFIX_PATH=" + str(context.install),
                 "-DDRIVER_ROOT=" + str(REPO / "tools/renpy_assimp_acceptance"),
                 "-DASSIMP_SOURCE=" + str(source)], cwd=root)
        command(["cmake", "--build", driver_build, "--parallel", "2"], cwd=root)
        ownership = command([driver_build / "ownership"], cwd=root).strip()
        constructors = command([driver_build / "constructors"], cwd=root).strip()
        print(json.dumps({"status": "passed", "build_source_pin": BUILD_PIN,
                          "assimp_source_pin": ASSIMP_PIN,
                          "compiler": version.splitlines()[0], "host": sys.platform,
                          "production_download_and_build": "passed",
                          "actual_scene_combiner_copy": ownership,
                          "actual_open3dgc_constructors": constructors,
                          "target_compilation": "not_run", "gameplay": "unverified"}, sort_keys=True))


if __name__ == "__main__":
    main()
