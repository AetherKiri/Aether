#!/usr/bin/env python3
"""Check GLib's genuine pipe2 probe and source function with real host headers.

This uses the pinned public GLib/Meson sources and a real Linux compiler/libc.
POSIX feature mode reproduces a linkable pipe2 without a header declaration;
GNU mode verifies that the corrected probe still enables a declared pipe2.
The original GLib function body then exercises actual pipe/fcntl operations.
No SDK or compiler is mocked. Full GLib/Apple/application/gameplay are NOT_RUN.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


GLIB_COMMIT = "2371bee17d85318480b3ddeeab4f5107b4889ad7"
MESON_COMMIT = "75ef08140346d9a058546493036a31431774eb7a"
REPOSITORY = Path(__file__).resolve().parents[1]
PORT = REPOSITORY / "vcpkg/ports/glib"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--glib-source", type=Path, required=True)
    parser.add_argument("--meson-source", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--cc", default="cc")
    parser.add_argument("--cmake", default="cmake")
    args = parser.parse_args()
    if sys.platform != "linux":
        parser.error("This real POSIX/GNU header regression requires a Linux host")
    source = args.glib_source.resolve(strict=True)
    meson = args.meson_source.resolve(strict=True)
    output = args.output_dir.resolve()
    if any(output == p or output.is_relative_to(p) for p in (source, meson, REPOSITORY)):
        parser.error("Use an isolated output directory outside both checkouts and the repository")
    cc, cmake, patch = (shutil.which(x) for x in (args.cc, args.cmake, "patch"))
    if not all((cc, cmake, patch)):
        raise RuntimeError("A real host compiler, CMake and patch are required")
    for directory, expected in ((source, GLIB_COMMIT), (meson, MESON_COMMIT)):
        actual = subprocess.check_output(
            ["git", "-C", str(directory), "rev-parse", "HEAD"], text=True).strip()
        if actual != expected:
            raise RuntimeError(f"Expected genuine pinned source {expected}, got {actual}")
        subprocess.run(["git", "-C", str(directory), "diff", "--exit-code", "HEAD", "--"],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    output.mkdir(parents=True, exist_ok=False)
    process_env = os.environ.copy()
    process_env["CC"] = cc

    def run(argv: list[str], log: Path, *, cwd: Path | None = None) -> subprocess.CompletedProcess:
        result = subprocess.run(argv, cwd=cwd, env=process_env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log.write_text(result.stdout)
        return result

    # Execute the production CMake patch-selection block without replacing any
    # vcpkg function or evaluating the download/build portions of the recipe.
    recipe = (PORT / "portfile.cmake").read_text()
    selection = "set(GLIB_PATCHES\n" + recipe.split("set(GLIB_PATCHES\n", 1)[1].split(
        "vcpkg_extract_source_archive(SOURCE_PATH", 1)[0]
    checks = ""
    for ios in (True, False):
        checks += "set(VCPKG_TARGET_IS_IOS " + ("TRUE" if ios else "FALSE") + ")\n"
        checks += selection
        expected = "use-libiconv-on-windows.patch;libintl.patch"
        if ios:
            expected += ";ios-pipe2-prototype.patch"
        checks += f'if(NOT GLIB_PATCHES STREQUAL "{expected}")\n'
        checks += 'message(FATAL_ERROR "Wrong production patch selection")\nendif()\n'
    (output / "production-scope.cmake").write_text(checks)
    result = run([cmake, "-P", str(output / "production-scope.cmake")],
                 output / "production-scope.log")
    if result.returncode:
        raise RuntimeError("Actual production iOS/non-iOS patch selection failed")

    snapshot = output / "patched-source"
    shutil.copytree(source, snapshot, ignore=shutil.ignore_patterns(".git"))
    for name in ("use-libiconv-on-windows.patch", "libintl.patch", "ios-pipe2-prototype.patch"):
        result = run([patch, "--batch", "--fuzz=0", "-p1", "-i", str(PORT / name)],
                     output / (name + ".log"), cwd=snapshot)
        if result.returncode:
            raise RuntimeError(f"Genuine GLib source patch failed: {name}")

    def probe_block(path: Path) -> str:
        text = path.read_text()
        if text.count("foreach f : functions\n") != 1:
            raise RuntimeError("The production GLib capability loop changed")
        return "foreach f : functions\n" + text.split("foreach f : functions\n", 1)[1].split(
            "endforeach", 1)[0] + "endforeach\n"

    original_block = probe_block(source / "meson.build")
    patched_block = probe_block(snapshot / "meson.build")
    header = source / "glib/glib-unixprivate.h"
    if header.read_bytes() != (snapshot / "glib/glib-unixprivate.h").read_bytes():
        raise RuntimeError("The production pipe function must remain unchanged")
    body = header.read_text().split("G_BEGIN_DECLS\n", 1)[1].split("G_END_DECLS", 1)[0]
    # Only the upstream scalar declarations/macros accompany its unmodified
    # function body. All OS declarations and operations use actual host libc.
    types = re.findall(r"^typedef\s+(?:int\s+gint|gint\s+gboolean);",
                       (source / "glib/gtypes.h").read_text(), re.M)
    macros = re.findall(r"^#define\s+(?:FALSE|TRUE)\s+[^\n]+",
                        (source / "glib/gmacros.h").read_text(), re.M)
    if len(types) != 2 or len(macros) != 2 or body.count("g_unix_open_pipe_internal") != 1:
        raise RuntimeError("The pinned GLib scalar declarations/function boundary changed")
    driver = '''#include "config.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
''' + "\n".join(types + macros) + "\n" + body + '''
int main(void) {
  for (int clo = 0; clo < 2; clo++) for (int nb = 0; nb < 2; nb++) {
    int fds[2] = {-1, -1};
    assert(g_unix_open_pipe_internal(fds, clo, nb));
    for (int i = 0; i < 2; i++) {
      int fdflags = fcntl(fds[i], F_GETFD);
      int flags = fcntl(fds[i], F_GETFL);
      assert(fdflags >= 0 && flags >= 0);
      assert(!!(fdflags & FD_CLOEXEC) == clo);
      assert(!!(flags & O_NONBLOCK) == nb);
    }
    if (nb) {
      char byte;
      errno = 0;
      assert(read(fds[0], &byte, 1) == -1);
      assert(errno == EAGAIN || errno == EWOULDBLOCK);
    }
    assert(write(fds[1], "ok", 2) == 2);
    char bytes[2];
    assert(read(fds[0], bytes, 2) == 2);
    assert(bytes[0] == 'o' && bytes[1] == 'k');
    assert(close(fds[0]) == 0 && close(fds[1]) == 0);
  }
  puts("actual_upstream_pipe_function_4_flag_cases_PASS");
  return 0;
}
'''
    cases = {}
    for label, flags, block, available in (
        ("original-posix", "-D_POSIX_C_SOURCE=200809L", original_block, True),
        ("patched-posix", "-D_POSIX_C_SOURCE=200809L", patched_block, False),
        ("patched-gnu", "-D_GNU_SOURCE", patched_block, True),
    ):
        directory = output / label
        directory.mkdir()
        project = "project('genuine-glib-probe', 'c', default_options : ['c_std=c99'])\n"
        project += "cc = meson.get_compiler('c')\nfunctions = ['pipe2']\n"
        project += "glib_conf = configuration_data()\nglib_conf_prefix = ''\n" + block
        project += "configure_file(output : 'config.h', configuration : glib_conf)\n"
        (directory / "meson.build").write_text(project)
        result = run([sys.executable, str(meson / "meson.py"), "setup",
                      str(directory / "build"), str(directory), "--backend=none",
                      "-Dc_args=" + flags], directory / "configure.log")
        if result.returncode:
            raise RuntimeError(f"Real Meson configure failed: {label}")
        config = (directory / "build/config.h").read_text()
        detected = "#define HAVE_PIPE2 1" in config
        if detected != available:
            raise RuntimeError(f"Unexpected genuine header probe in {label}: {config}")
        (directory / "actual-function.c").write_text(driver)
        result = run([cc, "-std=c99", "-Werror=implicit-function-declaration", flags,
                      "-I", str(directory / "build"), str(directory / "actual-function.c"),
                      "-o", str(directory / "actual-function")], directory / "compiler.log")
        if label == "original-posix":
            if not result.returncode or not re.search(
                    r"(?:implicit declaration|undeclared function).*['‘]pipe2", result.stdout):
                raise RuntimeError("Original real source did not fail on undeclared pipe2")
            runtime = "NOT_RUN_EXPECTED_COMPILER_FAILURE"
        else:
            if result.returncode:
                raise RuntimeError(f"Actual GLib function compilation failed: {label}")
            result = run([str(directory / "actual-function")], directory / "runtime.log")
            if result.returncode or "4_flag_cases_PASS" not in result.stdout:
                raise RuntimeError(f"Actual pipe/fcntl runtime failed: {label}")
            runtime = "PASS"
        cases[label] = {"have_pipe2": detected, "runtime": runtime}

    evidence = {
        "result": "PASS", "scope": "genuine_Linux_host_Meson_probe_and_isolated_GLib_source_function",
        "glib_commit": GLIB_COMMIT, "meson_commit": MESON_COMMIT,
        "compiler": subprocess.check_output([cc, "--version"], text=True).splitlines()[0],
        "glib_meson_sha256": sha(source / "meson.build"),
        "meson_compiler_sha256": sha(meson / "mesonbuild/compilers/mixins/clike.py"),
        "pipe_header_sha256": sha(header), "patch_sha256": sha(PORT / "ios-pipe2-prototype.patch"),
        "recipe_sha256": sha(PORT / "portfile.cmake"), "cases": cases,
        "not_run": ["exact_GNOME_release_archive_build", "complete_GLib_build",
                    "Apple_SDK_compilation", "iOS_application", "gameplay"],
    }
    (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence))


if __name__ == "__main__":
    main()
