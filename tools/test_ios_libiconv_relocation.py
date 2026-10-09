#!/usr/bin/env python3
"""Compile and execute the genuine gnulib install-reloc wrapper at -O0.

The iOS libiconv 1.19 failure is a missing standalone-wrapper dependency.
This regression uses an explicitly pinned public gnulib checkout and its real
autotools-generated config/headers. It does not download a release, imitate an
iOS SDK, or claim that libiconv's release installation or mobile gameplay ran.
Supply normal Autoconf/Automake/m4 through PATH (or their standard env vars).
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
import sys


GNULIB_COMMIT = "42dd0e518e06e55e4629710bff94790fe8b9aec9"
REPOSITORY = Path(__file__).resolve().parents[1]
PATCH = REPOSITORY / "vcpkg/ports/libiconv/ios-reloc-memeq.patch"
SOURCE_FILES = (
    "build-aux/install-reloc", "lib/progname.c", "lib/progreloc.c",
    "lib/memeq.c", "lib/string.in.h", "modules/relocatable-prog-wrapper",
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command: list[str], cwd: Path, env: dict[str, str], log: Path,
        *, expected_failure: bool = False) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(command, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text(result.stdout, encoding="utf-8")
    if not expected_failure and result.returncode:
        raise RuntimeError(f"{command[0]} failed ({result.returncode}); see {log}")
    return result


def validate_checkout(source: Path) -> str:
    commit = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if commit != GNULIB_COMMIT:
        raise RuntimeError(f"Expected genuine gnulib {GNULIB_COMMIT}, got {commit}")
    for name in SOURCE_FILES:
        original = subprocess.check_output(
            ["git", "-C", str(source), "show", f"{commit}:{name}"])
        if (source / name).read_bytes() != original:
            raise RuntimeError(f"Gnulib source differs from its pinned commit: {name}")
    return commit


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gnulib-source", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True,
                        help="A fresh scratch directory; existing files are never changed")
    parser.add_argument("--jobs", type=int, default=3)
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    args = parser.parse_args()
    if args.jobs < 1 or sys.platform not in ("linux", "darwin"):
        parser.error("This genuine host regression requires Linux or macOS and jobs >= 1")
    source = args.gnulib_source.resolve(strict=True)
    commit = validate_checkout(source)
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=False)
    env = os.environ.copy()
    cc = shlex.split(args.cc)
    if not cc or any(any(c.isspace() for c in part) for part in cc):
        parser.error("CC must have ordinary compiler arguments without embedded whitespace")
    if not shutil.which(cc[0]):
        raise RuntimeError(f"Compiler not available: {cc[0]}")
    env.update(CC=shlex.join(cc), CFLAGS="-O0 -g")
    generated = output / "generated"
    run([str(source / "gnulib-tool"), "--create-testdir", "--without-tests",
         f"--dir={generated}", "relocatable-prog", "minmax",
         "glibc-internal/scratch_buffer"], output, env,
        output / "generate.log")
    for name in ("progname.c", "progreloc.c", "memeq.c"):
        if (generated / "gllib" / name).read_bytes() != (source / "lib" / name).read_bytes():
            raise RuntimeError(f"Generator changed the actual source {name}")
    wrapper = generated / "build-aux/install-reloc"
    if wrapper.read_bytes() != (source / "build-aux/install-reloc").read_bytes():
        raise RuntimeError("Generator changed the actual install-reloc source")
    install_prefix = output / "installed-prefix"
    run(["./configure", "--enable-relocatable", f"--prefix={install_prefix}"],
        generated, env, output / "configure.log")
    run(["make", f"-j{args.jobs}"], generated, env, output / "make.log")
    if not (generated / "config.h").is_file() or not (generated / "gllib/string.h").is_file():
        raise RuntimeError("Actual Autoconf-generated config/string headers are missing")

    # A real shared-library payload makes moving the prefix exercise the actual
    # GNU wrapper's relocation, runtime search-path setup, and normal exec path.
    payload = output / "payload"
    payload.mkdir()
    (payload / "library.c").write_text("int relocation_marker(void) { return 314159; }\n")
    (payload / "program.c").write_text(
        '#include <stdio.h>\nextern int relocation_marker(void);\n'
        'int main(void) { int n = relocation_marker(); printf("marker=%d\\n", n); '
        'return n != 314159; }\n')
    darwin = sys.platform == "darwin"
    library_name = "libaether_relocation.dylib" if darwin else "libaether_relocation.so"
    shared_flags = (["-dynamiclib", "-Wl,-install_name,@rpath/" + library_name]
                    if darwin else ["-shared", "-fPIC"])
    run(cc + shared_flags + [str(payload / "library.c"), "-o", str(payload / library_name)],
        output, env, output / "payload-library.log")
    binary = payload / "program"
    run(cc + [str(payload / "program.c"), "-L" + str(payload),
              "-laether_relocation", "-o", str(binary)],
        output, env, output / "payload-program.log")

    def install(script: Path, name: str) -> tuple[Path, subprocess.CompletedProcess[str]]:
        # Both cases use the real configured prefix. Reset only our own failed
        # installation before re-running the genuine script with the patch.
        prefix = install_prefix
        if prefix.exists():
            shutil.rmtree(prefix)
        (prefix / "bin").mkdir(parents=True)
        (prefix / "lib").mkdir()
        shutil.copy2(payload / library_name, prefix / "lib" / library_name)
        install_env = env.copy()
        install_env.update(
            RELOC_LIBRARY_PATH_VAR="DYLD_LIBRARY_PATH" if darwin else "LD_LIBRARY_PATH",
            RELOC_LIBRARY_PATH_VALUE=str(prefix / "lib"), RELOC_PREFIX=str(prefix),
            RELOC_DESTDIR="", RELOC_COMPILE_COMMAND=shlex.join(cc + ["-O0", "-g"]),
            RELOC_SRCDIR=str(generated / "gllib"), RELOC_BUILDDIR=str(generated / "gllib"),
            RELOC_CONFIG_H_DIR=str(generated), RELOC_EXEEXT="", RELOC_STRIP_PROG=":",
            RELOC_INSTALL_PROG="install -m 755")
        result = run(["sh", str(script), str(binary), str(prefix / "bin/program")],
                     output, install_env, output / (name + "-install.log"),
                     expected_failure=True)
        return prefix, result

    _, original = install(wrapper, "original")
    if original.returncode == 0 or not re.search(r"undefined|unresolved", original.stdout, re.I) \
            or not re.search(r"\b_?memeq\b", original.stdout):
        raise RuntimeError("Original genuine -O0 wrapper did not fail with undefined memeq")

    run(["patch", "--batch", "--fuzz=0", "-p1", "-i", str(PATCH)], generated,
        env, output / "patch.log")
    prefix, patched = install(wrapper, "patched")
    if patched.returncode:
        raise RuntimeError("Patched genuine wrapper failed; see patched-install.log")
    installed = prefix / "bin/program"
    if not installed.is_file() or digest(installed) == digest(binary) \
            or digest(prefix / "bin/program.bin") != digest(binary):
        raise RuntimeError("The real relocating wrapper/payload installation is missing")
    runtime_env = env.copy()
    for name in ("LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH"):
        runtime_env.pop(name, None)
    result = run([str(installed)], output, runtime_env, output / "installed.log")
    if result.stdout != "marker=314159\n":
        raise RuntimeError("The actual installed wrapper did not execute its shared-library payload")
    moved = output / "relocated-prefix"
    shutil.move(str(prefix), moved)
    result = run([str(moved / "bin/program")], output, runtime_env, output / "relocated.log")
    if result.stdout != "marker=314159\n":
        raise RuntimeError("The actual GNU wrapper did not resolve its relocated library")
    evidence = {
        "status": "PASS", "scope": "genuine-canonical-gnulib-host-wrapper",
        "gnulib_commit": commit, "platform": sys.platform,
        "compiler": subprocess.check_output(cc + ["--version"], text=True).splitlines()[0],
        "source_sha256": {name: digest(source / name) for name in SOURCE_FILES},
        "patch_sha256": digest(PATCH), "generated_config_sha256": digest(generated / "config.h"),
        "generated_string_header_sha256": digest(generated / "gllib/string.h"),
        "original_undefined_memeq": "PASS", "patched_standalone_link": "PASS",
        "installed_wrapper_execution": "PASS", "relocated_library_execution": "PASS",
        "libiconv_1_19_release_install": "NOT_RUN", "apple_ios_sdk_link": "NOT_RUN",
        "ios_application_gameplay": "NOT_RUN",
    }
    (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, sort_keys=True))


if __name__ == "__main__":
    main()
