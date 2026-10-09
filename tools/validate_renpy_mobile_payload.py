#!/usr/bin/env python3
"""Reject incomplete mobile packaging inputs; this does not test gameplay."""

import argparse
import ast
import importlib.util
import marshal
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import types
import zipfile


LIFECYCLE_SYMBOLS = (
    "renpy_mobile_bootstrap", "renpy_mobile_bind_window", "renpy_mobile_init",
    "renpy_mobile_tick", "renpy_mobile_frame", "renpy_mobile_input",
    "renpy_mobile_pause", "renpy_mobile_resume", "renpy_mobile_shutdown",
    "renpy_mobile_text_input_state", "renpy_mobile_set_surface_size",
)

ANDROID_ARCHITECTURES = {
    "arm64": ("arm64-v8a", 183),
    "arm64-v8a": ("arm64-v8a", 183),
    "x86_64": ("x86_64", 62),
}


def fail(message):
    raise ValueError(message)


def module_functions(root, relative):
    source = root / (relative + ".py")
    bytecode = root / (relative + ".pyc")
    if source.is_file():
        return {node.name for node in ast.parse(source.read_bytes()).body
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
    if bytecode.is_file():
        data = bytecode.read_bytes()
        if data[:4] != importlib.util.MAGIC_NUMBER:
            fail(f"{bytecode}: validate with the matching Python 3.12 interpreter")
        code = marshal.loads(data[16:])
        if not isinstance(code, types.CodeType):
            fail(f"invalid Python bytecode: {bytecode}")
        return {value.co_name for value in code.co_consts
                if isinstance(value, types.CodeType)}
    fail(f"missing Python module: {root / relative}.py or .pyc")


def validate_private(root, platform):
    if not root.is_dir():
        fail(f"Ren'Py private payload must be an unpacked directory: {root}")
    for entry in root.rglob("*"):
        if entry.is_symlink():
            fail(f"APK/bundle private assets must not contain symlinks: {entry}")
    entrypoints = ("main.py",) if platform == "android" else ("renpy.py", "main.py")
    if not any((root / entry).is_file() for entry in entrypoints):
        fail(f"Ren'Py private payload lacks entrypoint {entrypoints}: {root}")
    for module in ("lib/python3.12/site", "lib/python3.12/encodings/__init__",
                   "renpy/__init__", "renpy/execution", "renpy/display/core"):
        module_functions(root, module)
    module_functions(root, "renpy/main")
    functions = module_functions(root, "renpy/aether_mobile")
    missing = {"cooperative_start", "cooperative_tick", "cooperative_stop"} - functions
    if missing:
        fail(f"unpatched Ren'Py Python payload: missing {', '.join(sorted(missing))} in {root}/renpy/aether_mobile")


def command_output(command):
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        fail(f"cannot inspect mobile native payload ({' '.join(command)}): {result.stderr.strip()}")
    return result.stdout


def validate_library(library, platform, arch, sdk, executable=False, packaged=False):
    if not library.is_file():
        fail(f"Ren'Py lifecycle library is missing: {library}")
    data = library.read_bytes()
    if b"AETHERKIRI_RENPY_LIFECYCLE_STUB" in data:
        fail(f"contract-only stub cannot be packaged as a Ren'Py runtime: {library}")
    if platform == "android":
        if arch not in ANDROID_ARCHITECTURES:
            fail(f"unsupported Android runtime ABI: {arch}")
        abi, expected_machine = ANDROID_ARCHITECTURES[arch]
        if len(data) < 20 or data[:4] != b"\x7fELF" or data[4:6] != b"\x02\x01":
            fail(f"Android Ren'Py payload must be a little-endian ELF64 shared library: {library}")
        elf_type, machine = struct.unpack_from("<HH", data, 16)
        if elf_type != 3 or machine != expected_machine:
            fail(f"Android Ren'Py payload must target {abi}: {library}")
        nm = shlex.split(os.environ.get("RENPY_MOBILE_NM", "nm"))
        listing = command_output(nm + ["-D", "--defined-only", str(library)])
        dynamic = command_output(shlex.split(os.environ.get("RENPY_MOBILE_READELF", "readelf"))
                                 + ["-d", str(library)])
        needed = set(re.findall(r"\(NEEDED\).*\[([^]]+)\]", dynamic))
        system = {"libandroid.so", "liblog.so", "libEGL.so", "libGLESv1_CM.so",
                  "libGLESv2.so", "libGLESv3.so", "libOpenSLES.so", "libz.so",
                  "libc.so", "libm.so", "libdl.so"}
        if not packaged:
            # Godot's Android template supplies the NDK C++ shared runtime.
            # Its presence must still be verified in the exported APK below.
            system.add("libc++_shared.so")
        missing_dependencies = {name for name in needed - system
                                if not (library.parent / name).is_file()}
        if missing_dependencies:
            fail(f"unpackaged Ren'Py native dependencies: {', '.join(sorted(missing_dependencies))}: {library}")
    else:
        if not shutil.which("xcrun"):
            fail("iOS runtime validation requires macOS Xcode tools (xcrun nm/lipo/otool)")
        command_output(["xcrun", "lipo", str(library), "-verify_arch", arch])
        if executable:
            # Release stripping can remove the nlist symbol table while dyld
            # retains the export trie used by dlsym(RTLD_DEFAULT, ...).
            listing = command_output(["xcrun", "dyld_info", "-exports", str(library)])
        else:
            listing = command_output(["xcrun", "nm", "-gU", "-arch", arch, str(library)])
        if sdk:
            load_commands = command_output(["xcrun", "otool", "-l", "-arch", arch, str(library)])
            # Modern Xcode archives identify device/simulator explicitly in
            # LC_BUILD_VERSION. Refuse the other platform even for arm64,
            # whose CPU architecture alone cannot distinguish the two.
            platforms = set(re.findall(r"\bplatform\s+(\S+)", load_commands))
            expected = {"2", "IOS"} if sdk == "iphoneos" else {"7", "IOSSIMULATOR"}
            if not platforms or not platforms <= expected:
                fail(f"iOS runtime archive has incompatible SDK platform {sorted(platforms)} for {sdk}: {library}")
    if executable:
        symbols = set(re.findall(r"\b_?(renpy_mobile_\w+)\b", listing))
    else:
        symbols = {line.split()[-1].lstrip("_") for line in listing.splitlines()
                   if line.split() and " U " not in line}
    if platform == "android":
        if "JNI_OnLoad" not in symbols:
            fail(f"Android Ren'Py payload lacks the SDL/JVM registration entrypoint JNI_OnLoad: {library}")
        leaked = {name for name in symbols if name.startswith(("SDL_", "avcodec_", "avformat_", "Py_", "_Py_"))}
        if leaked:
            fail(f"Ren'Py private implementations must not be exported into the host: {', '.join(sorted(leaked)[:12])}: {library}")
    missing = set(LIFECYCLE_SYMBOLS) - symbols
    if missing:
        fail(f"official blocking or incomplete Ren'Py payload: missing {', '.join(sorted(missing))}: {library}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=("android", "ios"), required=True)
    parser.add_argument("--library", type=Path)
    parser.add_argument("--private-root", type=Path)
    parser.add_argument("--arch", "--abi", dest="arch", default="arm64")
    parser.add_argument("--sdk", choices=("iphoneos", "iphonesimulator"))
    parser.add_argument("--executable", action="store_true",
                        help="check an iOS app's dyld exports after release stripping")
    parser.add_argument("--apk", type=Path,
                        help="inspect the actual exported APK rather than staged inputs")
    args = parser.parse_args()
    if args.library is None and args.private_root is None and args.apk is None:
        parser.error("at least --library or --private-root is required")
    try:
        if args.library is not None:
            validate_library(args.library, args.platform, args.arch, args.sdk, args.executable)
        if args.private_root is not None:
            validate_private(args.private_root, args.platform)
        if args.apk is not None:
            if args.platform != "android":
                fail("--apk requires --platform android")
            if args.arch not in ANDROID_ARCHITECTURES:
                fail(f"unsupported Android runtime ABI: {args.arch}")
            abi = ANDROID_ARCHITECTURES[args.arch][0]
            with zipfile.ZipFile(args.apk) as apk, tempfile.TemporaryDirectory(prefix="aether-renpy-apk-") as work:
                root = Path(work)
                names = apk.namelist()
                required = (f"lib/{abi}/librenpython.so", f"lib/{abi}/libengine_api.so",
                            f"lib/{abi}/libaether_kiri_godot.so", "assets/renpy_mobile/private/main.py",
                            "assets/renpy_mobile/manifest.properties", "classes.dex")
                for name in required:
                    if name not in names:
                        fail(f"exported APK lacks {name}: {args.apk}")
                for name in names:
                    if name.startswith((f"lib/{abi}/", "assets/renpy_mobile/private/")):
                        relative = Path(name)
                        if relative.is_absolute() or ".." in relative.parts:
                            fail(f"unsafe APK member: {name}")
                        apk.extract(name, root)
                validate_library(root / required[0], "android", args.arch, None, packaged=True)
                validate_private(root / "assets/renpy_mobile/private", "android")
    except (ValueError, OSError, SyntaxError, EOFError, zipfile.BadZipFile) as error:
        print(f"Ren'Py mobile packaging input rejected: {error}", file=sys.stderr)
        return 1
    print("Ren'Py mobile packaging inputs validated; device gameplay remains unverified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
