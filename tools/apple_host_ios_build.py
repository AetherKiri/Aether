#!/usr/bin/env python3
"""Build the actual native Apple host core with isolated iOS 18 SDK caches.

This builds archives, not an App or proof of iOS 18 runtime compatibility.
A native App must link the complete CMake dependency closure and explicitly
reference aether_apple_host_core_initialize so static registration survives.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys


def commands(root, args):
    platform = "device" if args.sdk == "iphoneos" else "simulator"
    build = root / "out/apple_host/ios" / platform / args.configuration.lower()
    triplet = "arm64-ios18" + ("-simulator" if platform == "simulator" else "")
    providers = set(args.providers.split(","))
    if providers != {"kirikiri"}:
        raise ValueError("this migration phase supports only kirikiri; ONS/Siglus are deferred")
    configure = ["cmake", "-S", str(root), "-B", str(build), "-G", "Ninja",
                 "-DIOS=ON", "-DCMAKE_SYSTEM_NAME=iOS", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                 f"-DCMAKE_OSX_SYSROOT={args.sdk}", "-DCMAKE_OSX_DEPLOYMENT_TARGET=18.0",
                 f"-DCMAKE_BUILD_TYPE={args.configuration}", f"-DVCPKG_TARGET_TRIPLET={triplet}",
                 f"-DVCPKG_OVERLAY_TRIPLETS={root / 'vcpkg/triplets'}",
                 f"-DVCPKG_INSTALLED_DIR={build / 'vcpkg_installed'}",
                 "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON", "-DBUILD_GODOT_EXTENSION=OFF",
                 "-DBUILD_ENGINE_API=ON", "-DAETHERKIRI_ENABLE_APPLE_HOST=ON",
                 "-DENABLE_TESTS=OFF", "-DBUILD_TOOLS=OFF", "-DBUILD_GPU_BRIDGE=OFF",
                 "-DAETHERKIRI_ENABLE_INTERNAL=OFF", "-DAETHERKIRI_ENABLE_MINORI=OFF",
                 "-DAETHERKIRI_ENABLE_RFVP=OFF", "-DAETHERKIRI_ENABLE_SOFTPAL_RUNTIME=OFF",
                 "-DAETHERKIRI_ENABLE_ONSCRIPTER=OFF",
                 "-DAETHERKIRI_ENABLE_SIGLUS=OFF"]
    return build, configure, ["cmake", "--build", str(build), "--target",
                              "aether_apple_host_core", "engine_api", "--parallel", str(args.jobs)]


def run_logged(command, path, env):
    print(shlex.join(command), flush=True)
    with path.open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, env=env)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}); see {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", choices=["iphoneos", "iphonesimulator"], required=True)
    parser.add_argument("--configuration", choices=["Debug", "Release"], default="Debug")
    parser.add_argument("--providers", default="kirikiri", help="only kirikiri in the current migration phase")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--configure-only", action="store_true")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("jobs must be positive")
    root = Path(__file__).resolve().parents[1]
    vcpkg = Path(os.environ.get("VCPKG_ROOT", root / ".devtools/vcpkg"))
    try:
        build, configure, compile_command = commands(root, args)
    except ValueError as error:
        parser.error(str(error))
    if args.dry_run:
        print(shlex.join(configure))
        print(shlex.join(compile_command))
        return
    if sys.platform != "darwin" or not (vcpkg / "scripts/buildsystems/vcpkg.cmake").exists():
        parser.error("macOS with Xcode and a configured VCPKG_ROOT is required")
    build.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, VCPKG_ROOT=str(vcpkg))
    metadata = {"sdk": args.sdk, "minimumOS": "18.0", "architecture": "arm64",
                "configuration": args.configuration, "providers": args.providers.split(","),
                "configure": configure, "build": compile_command, "status": "configuring"}
    manifest = build / "build-result.json"
    try:
        manifest.write_text(json.dumps(metadata, indent=2) + "\n")
        run_logged(configure, build / "configure.log", env)
        metadata["status"] = "configured"
        if not args.configure_only:
            run_logged(compile_command, build / "build.log", env)
            for relative in ["bridge/apple_host/libaether_apple_host_core.a", "abi/libengine_api.a"]:
                if not (build / relative).exists():
                    raise RuntimeError(f"missing archive: {relative}")
            metadata["status"] = "built"
        print(f"{metadata['status']}: {build}")
    except (RuntimeError, OSError) as error:
        metadata["status"] = "failed"
        metadata["error"] = str(error)
        raise
    finally:
        manifest.write_text(json.dumps(metadata, indent=2) + "\n")


if __name__ == "__main__":
    main()
