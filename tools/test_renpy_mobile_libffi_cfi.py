#!/usr/bin/env python3
"""Compile the pinned libffi unwind assembly with the genuine LLVM assembler.

On macOS this uses the selected Xcode SDKs and the complete assembly. On Linux
the Apple closure trampoline table is excluded from this focused CFI check,
because its Mach SDK header is unavailable. Neither case links a full runtime
or executes gameplay.
"""
import argparse
import ast
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
PIN = "7bfab40c1174f622f644b24669afd5fb167fbb79"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_source", type=Path)
    parser.add_argument("--clang", type=Path)
    args = parser.parse_args()
    assert subprocess.check_output(["git", "-C", str(args.build_source), "rev-parse", "HEAD"], text=True).strip() == PIN
    if sys.platform == "darwin":
        compiler = str(args.clang) if args.clang else subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
    else:
        compiler = str(args.clang) if args.clang else shutil.which("clang-18") or shutil.which("clang")
    assert compiler, "A genuine LLVM clang is required for the Mach-O assembly regression"
    host_cc = shutil.which("cc")
    assert host_cc
    with tempfile.TemporaryDirectory(prefix="renpy-libffi-cfi-") as temporary:
        root = Path(temporary)
        archive = subprocess.Popen([
            "git", "-C", str(args.build_source), "archive", "HEAD", "renpybuild", "tasks",
            "source/Python-3.12.8-Setup.stdlib", "tools/cmake_build_variables.cmake",
            "source/libffi-3.4.5.tar.gz",
        ], stdout=subprocess.PIPE)
        assert archive.stdout is not None
        with tarfile.open(fileobj=archive.stdout, mode="r|*") as source:
            source.extractall(root, filter="data")
        assert archive.wait() == 0
        subprocess.run(["git", "apply", str(REPO / "bridge/renpy_runtime/mobile_launcher/patches/native/0007-darwin-ios-build.patch")], cwd=root, check=True)
        with tarfile.open(root / "source/libffi-3.4.5.tar.gz") as source:
            source.extractall(root, filter="data")
        source_root = root / "libffi-3.4.5"
        environment = {**os.environ, "CC": host_cc, "CFLAGS": "", "CPPFLAGS": "", "LDFLAGS": ""}
        build = subprocess.check_output([host_cc, "-dumpmachine"], text=True).strip()
        configured = subprocess.run(["./configure", "--host=aarch64-apple-darwin", "--build=" + build,
                                     "--disable-shared", "--enable-portable-binary"],
                                    cwd=source_root, env=environment, capture_output=True, text=True)
        assert configured.returncode == 0, configured.stdout + configured.stderr
        configuration = next(source_root.glob("*/fficonfig.h"))
        if sys.platform != "darwin":
            # This test isolates CFI, not the Apple-specific closure page table.
            # Production configuration and source compilation retain that table.
            text = configuration.read_text()
            assert "#define FFI_EXEC_TRAMPOLINE_TABLE 1" in text
            configuration.write_text(text.replace("#define FFI_EXEC_TRAMPOLINE_TABLE 1", "#define FFI_EXEC_TRAMPOLINE_TABLE 0"))
        includes = ["-DHAVE_CONFIG_H", "-I" + str(configuration.parent),
                    "-I" + str(configuration.parent / "include"), "-Iinclude", "-Isrc"]
        targets = (("arm64-apple-ios13.0", "iphoneos"),
                   ("arm64-apple-ios13.0-simulator", "iphonesimulator"))
        for target, sdk in targets:
            sdk_args = []
            if sys.platform == "darwin":
                sdk_args = ["-isysroot", subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()]
            command = [compiler, "-target", target, *sdk_args, *includes, "-c", "src/aarch64/sysv.S", "-o", target + ".o"]
            result = subprocess.run(command, cwd=source_root, capture_output=True, text=True)
            assert result.returncode != 0 and "invalid CFI advance_loc expression" in result.stderr, result.stderr
        # Execute the genuine unpack function through its real Context, so a
        # regression in the task's patch wiring also fails this check.
        sys.path.insert(0, str(root))
        from renpybuild.context import Context
        tree = ast.parse((root / "tasks/libffi.py").read_text())
        unpack = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "unpack")
        unpack.decorator_list = []
        namespace = {"Context": Context, "version": "3.4.5"}
        exec(compile(ast.Module(body=[unpack], type_ignores=[]), str(root / "tasks/libffi.py"), "exec"), namespace)
        context = Context("ios", "arm64", "3", root, SimpleNamespace())
        context.set_names("arch", "unpack", "libffi")
        namespace["unpack"](context)
        source_root = context.cwd
        for target, sdk in targets:
            sdk_args = []
            if sys.platform == "darwin":
                sdk_args = ["-isysroot", subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()]
            command = [compiler, "-target", target, *sdk_args, *includes, "-c", "src/aarch64/sysv.S", "-o", target + ".o"]
            result = subprocess.run(command, cwd=source_root, capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            assert (source_root / (target + ".o")).read_bytes()[:4] == bytes.fromhex("cffaedfe")
        print("Real LLVM assembly reproduced the pinned CFI failure and compiled patched arm64 device/Simulator Mach-O objects")
        if sys.platform != "darwin":
            print("Linux check excluded the Apple closure page table; full Xcode runtime compilation and gameplay are not covered")


if __name__ == "__main__":
    main()
