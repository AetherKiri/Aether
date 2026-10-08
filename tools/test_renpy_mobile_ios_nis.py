#!/usr/bin/env python3
"""Run genuine CPython configure with the actual iOS task's module policy.

This checks generated optional-module rules with a real host compiler. On Mac,
it also probes the actual device/Simulator SDK headers. It does not compile or
link a target Python runtime, emulate an SDK, or verify gameplay.
"""
import argparse
import ast
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[1]
PIN = "7bfab40c1174f622f644b24669afd5fb167fbb79"
PATCHES = REPO / "bridge/renpy_runtime/mobile_launcher/patches/native"


def unchanged_other_targets(original, patched):
    def functions(text):
        return {node.name: ast.dump(node, include_attributes=False)
                for node in ast.parse(text).body if isinstance(node, ast.FunctionDef)}
    before, after = functions(original), functions(patched)
    for name in ("common", "build_posix", "build_android", "build_windows", "build_web"):
        assert before[name] == after[name], f"Unrelated target policy changed: {name}"


def site_from_task(task_text, source, root, Context):
    tree = ast.parse(task_text)
    selected = [node for node in tree.body if isinstance(node, ast.FunctionDef)
                and node.name in ("common", "build_ios")]
    assert len(selected) == 2
    for node in selected:
        node.decorator_list = []
    namespace = {"Context": Context, "version": "3.12.8", "common_post": lambda context: None}
    exec(compile(ast.Module(body=selected, type_ignores=[]), "actual-python3-task", "exec"), namespace)
    context = Context("ios", "arm64", "3", root, None)
    context.set_names("python", "build_ios", "python3")
    context.cwd = source.parent
    # Capture only the site's genuine task policy. Configure runs below with
    # the real host compiler; no SDK or build is represented by this callback.
    context.run = lambda command: None
    namespace["build_ios"](context)
    assert context.cwd == source
    return source / "config.site"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_source", type=Path)
    args = parser.parse_args()
    assert subprocess.check_output(["git", "-C", str(args.build_source), "rev-parse", "HEAD"], text=True).strip() == PIN
    with tempfile.TemporaryDirectory(prefix="renpy-ios-nis-") as temporary:
        root = Path(temporary)
        archive = subprocess.Popen([
            "git", "-C", str(args.build_source), "archive", "HEAD", "renpybuild", "tasks",
            "source/Python-3.12.8-Setup.stdlib", "source/Python-3.12.8.tar.xz",
            "tools/cmake_build_variables.cmake",
        ], stdout=subprocess.PIPE)
        assert archive.stdout is not None
        with tarfile.open(fileobj=archive.stdout, mode="r|*") as source:
            source.extractall(root, filter="data")
        assert archive.wait() == 0
        task = root / "tasks/python3.py"
        original = task.read_text()
        subprocess.run(["git", "apply", "--include=tasks/metalangle.py", str(PATCHES / "0006-ios-offscreen-renderer.patch")], cwd=root, check=True)
        subprocess.run(["git", "apply", str(PATCHES / "0007-darwin-ios-build.patch")], cwd=root, check=True)
        patched = task.read_text()
        unchanged_other_targets(original, patched)
        sys.path.insert(0, str(root))
        from renpybuild.context import Context

        if sys.platform == "darwin":
            compiler = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
            host_sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
            compiler_words = [compiler, "-isysroot", host_sdk]
            assert all(not any(c.isspace() for c in word) for word in compiler_words)
            for sdk, target in (("iphoneos", "arm64-apple-ios13.0"), ("iphonesimulator", "arm64-apple-ios13.0-simulator")):
                sdk_root = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
                assert Path(sdk_root).is_dir(), sdk_root
                result = subprocess.run([compiler, "-target", target, "-isysroot", sdk_root,
                                         "-x", "c", "-fsyntax-only", "-"],
                                        input="#include <rpcsvc/yp_prot.h>\n", text=True, capture_output=True)
                assert result.returncode != 0 and "rpcsvc/yp_prot.h" in result.stderr and "file not found" in result.stderr, result.stderr
                print(f"Actual {sdk} SDK reproduces the unavailable NIS header: {sdk_root}", flush=True)
        else:
            compiler = shutil.which("cc")
            assert compiler
            compiler_words = [compiler]

        for label, text in (("original", original), ("patched", patched)):
            destination = root / label
            destination.mkdir()
            with tarfile.open(root / "source/Python-3.12.8.tar.xz") as source:
                source.extractall(destination, filter="data")
            python_source = destination / "Python-3.12.8"
            site = site_from_task(text, python_source, root, Context)
            environment = {**os.environ, "CONFIG_SITE": str(site), "CC": " ".join(compiler_words),
                           "CFLAGS": "", "CPPFLAGS": "", "LDFLAGS": ""}
            result = subprocess.run(["./configure", "--with-ensurepip=no", "--prefix=" + str(destination / "install")],
                                    cwd=python_source, env=environment, capture_output=True, text=True)
            assert result.returncode == 0, result.stdout[-5000:] + result.stderr[-5000:]
            makefile = (python_source / "Makefile").read_text()
            state = next(line.partition("=")[2] for line in makefile.splitlines() if line.startswith("MODULE_NIS_STATE="))
            if label == "patched":
                assert state == "n/a", state
                assert not any(line.startswith("Modules/nismodule.o:") for line in makefile.splitlines())
                assert not any(line.startswith("nis ") for line in (python_source / "Modules/Setup.stdlib").read_text().splitlines())
                assert "ac_cv_func_clock_settime=no\npy_cv_module_nis=n/a\n" in site.read_text()
            print(f"Actual CPython 3.12.8 {label} host configure: MODULE_NIS_STATE={state}", flush=True)
            if label == "original" and state != "yes":
                print("Original NIS auto-enable is not reproduced by this host's dependencies; the genuine iOS compiler failure is recorded separately", flush=True)
        print("Actual configure generated no NIS extension object rule under the iOS policy; target runtime compilation and gameplay remain untested here")


if __name__ == "__main__":
    main()
