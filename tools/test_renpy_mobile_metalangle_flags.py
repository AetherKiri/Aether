#!/usr/bin/env python3
"""Exercise the genuine MetalANGLE annotator and LLVM compiler/linker flag split.

The compiled probe uses no SDK headers or framework functions. It checks the
actual clang driver with -Werror, not full framework linking or gameplay.
"""
import argparse
import ast
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
PIN = "7bfab40c1174f622f644b24669afd5fb167fbb79"
PATCHES = REPO / "bridge/renpy_runtime/mobile_launcher/patches/native"


def annotator(path, Context):
    tree = ast.parse(path.read_text())
    selected = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "annotate")
    selected.decorator_list = []
    namespace = {"Context": Context}
    exec(compile(ast.Module(body=[selected], type_ignores=[]), str(path), "exec"), namespace)
    return namespace["annotate"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_source", type=Path)
    parser.add_argument("--clang", type=Path)
    args = parser.parse_args()
    assert subprocess.check_output(["git", "-C", str(args.build_source), "rev-parse", "HEAD"], text=True).strip() == PIN
    compiler = str(args.clang) if args.clang else shutil.which("clang-18") or shutil.which("clang")
    assert compiler, "A genuine LLVM clang is required"
    with tempfile.TemporaryDirectory(prefix="renpy-metalangle-flags-") as temporary:
        root = Path(temporary)
        archive = subprocess.Popen([
            "git", "-C", str(args.build_source), "archive", "HEAD", "renpybuild", "tasks",
            "source/Python-3.12.8-Setup.stdlib", "tools/cmake_build_variables.cmake",
        ], stdout=subprocess.PIPE)
        assert archive.stdout is not None
        with tarfile.open(fileobj=archive.stdout, mode="r|*") as source:
            source.extractall(root, filter="data")
        assert archive.wait() == 0
        subprocess.run(["git", "apply", "--include=tasks/metalangle.py", str(PATCHES / "0006-ios-offscreen-renderer.patch")], cwd=root, check=True)
        original = root / "original-metalangle.py"
        original.write_bytes((root / "tasks/metalangle.py").read_bytes())
        subprocess.run(["git", "apply", str(PATCHES / "0007-darwin-ios-build.patch")], cwd=root, check=True)
        sys.path.insert(0, str(root))
        from renpybuild.context import Context
        source = root / "probe.c"
        source.write_text("#ifndef METALANGLE\n#error MetalANGLE compile definition was lost\n#endif\nint renpy_compile_probe(void) { return 1; }\n")
        for architecture, target in (("arm64", "arm64-apple-ios13.0"), ("sim-arm64", "arm64-apple-ios13.0-simulator")):
            for version, expect_success in ((original, False), (root / "tasks/metalangle.py", True)):
                context = Context("ios", architecture, "3", root, SimpleNamespace())
                context.set_names("arch", "build", "libavif")
                annotator(version, Context)(context)
                assert "MetalANGLE.framework/Headers" in context.environ["CPPFLAGS"]
                for language, variable in (("c", "CFLAGS"), ("c++", "CXXFLAGS")):
                    flags = shlex.split(context.environ[variable])
                    if expect_success:
                        assert "-framework" not in flags
                        assert "-F" in flags and "-DMETALANGLE" in flags
                        assert "MetalANGLE.framework/Headers" in context.environ[variable]
                        assert "-framework MetalANGLE" in context.environ["LDFLAGS"]
                    output = root / (architecture + language + ".o")
                    result = subprocess.run([compiler, "-target", target, "-x", language, "-Werror", *flags,
                                             "-c", str(source), "-o", str(output)], capture_output=True, text=True)
                    if expect_success:
                        assert result.returncode == 0, result.stderr
                        assert output.read_bytes()[:4] == bytes.fromhex("cffaedfe")
                    else:
                        assert result.returncode != 0 and "linker" in result.stderr and "unused" in result.stderr, result.stderr
        print("Actual LLVM -Werror reproduced framework flags in compile-only failures and compiled patched C/C++ device/Simulator objects")
        print("MetalANGLE header/compile definitions and framework linker flags retained; full target linking and gameplay not covered")


if __name__ == "__main__":
    main()
