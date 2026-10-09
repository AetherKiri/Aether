#!/usr/bin/env python3
"""Generate a genuine Cython API and compile the C objects that consume it.

This checks clean-source host compilation, not target linkage or gameplay.
"""
import argparse
import ast
from pathlib import Path
import os
import shlex
import subprocess
import sys
import sysconfig
import tarfile
import tempfile


REPO = Path(__file__).resolve().parents[1]
BUILD_PIN = "7bfab40c1174f622f644b24669afd5fb167fbb79"
RENPY_PIN = "39895c1e017f0b36ffea2447d97eccd69d76ee1c"
PATCHES = REPO / "bridge/renpy_runtime/mobile_launcher/patches"


def archive(checkout, destination, pin, *paths):
    actual = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    assert actual == pin, (actual, pin)
    command = subprocess.Popen(["git", "-C", str(checkout), "archive", "HEAD", *paths], stdout=subprocess.PIPE)
    assert command.stdout is not None
    with tarfile.open(fileobj=command.stdout, mode="r|*") as contents:
        contents.extractall(destination, filter="data")
    assert command.wait() == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("renpy_build", type=Path)
    parser.add_argument("renpy_source", type=Path)
    parser.add_argument("--sdl-headers", type=Path, help="SDL2 include directory (otherwise use system headers)")
    args = parser.parse_args()
    sys.path.insert(0, str(args.renpy_build.resolve()))
    from renpybuild.context import Context

    with tempfile.TemporaryDirectory(prefix="renpy-static-api-") as temporary:
        root = Path(temporary)
        source = root / "renpy"
        source.mkdir()
        archive(args.renpy_build, root, BUILD_PIN, "tasks/librenpy.py", "tasks/renpython.py")
        archive(args.renpy_source, source, RENPY_PIN)
        task_file = root / "tasks/librenpy.py"
        original_task = task_file.read_text()
        subprocess.run(["git", "apply", str(PATCHES / "native/0001-renpy-build-link.patch")], cwd=root, check=True)
        subprocess.run(["git", "apply", str(PATCHES / "python/0001-cooperative-loop-skeleton.patch")], cwd=source, check=True)
        generated = source / "tmp/gen3-static"
        generated.mkdir(parents=True)
        subprocess.run([
            sys.executable, "-m", "cython", "-Isrc", "-Isrc/pygame/include", "-Itmp/gen3-static", "-I.",
            "-X", "profile=False", "-X", "embedsignature=True", "-X", "embedsignature.format=python",
            "renpy/pygame/surface.pyx", "-o", str(generated / "renpy.pygame.surface.c"),
        ], cwd=source, check=True)
        assert (generated / "renpy.pygame.surface_api.h").is_file()
        assert not (source / "tmp/gen3").exists(), "test must not use preexisting dynamic API headers"

        base = ["-fPIC", "-I" + sysconfig.get_path("include")]
        if args.sdl_headers:
            include = root / "include"
            include.mkdir()
            (include / "SDL2").symlink_to(args.sdl_headers.resolve(), target_is_directory=True)
            base.append("-I" + str(include))

        def flags(task_text, name):
            context = Context("android", "x86_64", "3", root, None)
            context.env(name, shlex.join(base))
            tree = ast.parse(task_text)
            build = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "build")
            assignments = [node for node in build.body if isinstance(node, ast.Expr)
                           and isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Attribute)
                           and node.value.func.attr == "env" and node.value.args[0].value == name]
            assert len(assignments) == 1
            exec(compile(ast.Module(body=assignments, type_ignores=[]), str(task_file), "exec"), {"c": context})
            return shlex.split(context.environ[name])

        compiler = shlex.split(os.environ.get("CC", "cc"))
        # The unpatched task must reproduce the missing-header error.
        control = subprocess.run(compiler + flags(original_task, "CFLAGS") + ["-c", str(source / "src/core.c"),
                                 "-o", str(root / "control.o")], capture_output=True, text=True)
        assert control.returncode != 0 and "renpy.pygame.surface_api.h" in control.stderr, control.stderr
        task_text = task_file.read_text()
        for name in ("core", "renpysound_core"):
            subprocess.run(compiler + flags(task_text, "CFLAGS") + ["-c", str(source / f"src/{name}.c"),
                           "-o", str(root / f"{name}.o")], check=True)
        probe = root / "api.cc"
        probe.write_text('#include <Python.h>\n#include <SDL2/SDL.h>\n#include <renpy.pygame.surface_api.h>\n')
        subprocess.run(shlex.split(os.environ.get("CXX", "c++")) + flags(task_text, "CXXFLAGS")
                       + ["-c", str(probe), "-o", str(root / "api.o")], check=True)
    print("Actual static Cython API generation and C/C++ compilation passed; no target linkage or gameplay performed")


if __name__ == "__main__":
    main()
