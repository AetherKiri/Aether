#!/usr/bin/env python3
"""Publish the embedded N2System NativeAOT host with the Android NDK."""

import argparse
import os
from pathlib import Path
import platform
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--ndk", type=Path, required=True)
    parser.add_argument("--abi", choices=("arm64-v8a", "x86_64"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--dotnet", default="dotnet")
    parser.add_argument("--configuration", default="Release")
    parser.add_argument("--font", type=Path)
    parser.add_argument("--api", type=int, default=24)
    args = parser.parse_args()
    if args.api < 21:
        parser.error("64-bit Android NativeAOT requires Android API 21 or newer")
    host = {"Darwin": "darwin-x86_64", "Linux": "linux-x86_64"}.get(platform.system())
    if host is None:
        parser.error(f"unsupported Android NDK build host: {platform.system()}")
    toolchain = args.ndk.resolve() / "toolchains" / "llvm" / "prebuilt" / host
    compiler = toolchain / "bin" / "clang"
    if not compiler.is_file():
        parser.error(f"Android NDK compiler does not exist: {compiler}")
    if not args.project.is_file():
        parser.error(f"N2System host project does not exist: {args.project}")
    if args.font is not None and not args.font.is_file():
        parser.error(f"runtime font does not exist: {args.font}")
    arch = "arm64" if args.abi == "arm64-v8a" else "x64"
    target_arch = "aarch64" if arch == "arm64" else "x86_64"
    rid = f"linux-bionic-{arch}"
    environment = os.environ.copy()
    environment["PATH"] = str(toolchain / "bin") + os.pathsep + environment.get("PATH", "")
    command = [
        args.dotnet, "publish", str(args.project.resolve()),
        "-c", args.configuration, "-r", rid,
        f"-p:NativeRid={rid}", "-p:PublishAotUsingRuntimePack=true",
        f"-p:CppCompilerAndLinker={compiler}",
        f"-p:CppLibCreator={toolchain / 'bin' / 'llvm-ar'}",
        f"-p:AetherAndroidTargetTriple={target_arch}-linux-android{args.api}",
        "-o", str(args.output.resolve()),
    ]
    if args.font is not None:
        command.append(f"-p:AetherRuntimeCjkFontPath={args.font.resolve()}")
    subprocess.run(command, check=True, env=environment)
    # Android's package manager and linker expect lib*.so in the APK's ABI
    # directory, whereas NativeAOT names its output after AssemblyName.
    source = args.output / "aether_n2system.so"
    if not source.is_file():
        parser.error(f"NativeAOT did not publish the expected shared library: {source}")
    shutil.copy2(source, args.output / "libaether_n2system.so")


if __name__ == "__main__":
    main()
