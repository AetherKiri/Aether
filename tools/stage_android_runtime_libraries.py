#!/usr/bin/env python3
"""Package the configured runtime providers in Godot's generated Gradle project."""
import argparse
from pathlib import Path
import shutil


def stage(build: Path, source: Path, manifest: Path, abi: str):
    gradle = build / "build.gradle"
    if not gradle.is_file():
        raise ValueError(f"Not a Godot Android build template: {build}")
    if abi not in ("arm64-v8a", "armeabi-v7a", "x86", "x86_64"):
        raise ValueError(f"Unsupported Android ABI: {abi}")
    names = [Path(line).name for line in manifest.read_text().splitlines() if line.strip()]
    for name in names:
        if not name.startswith("lib") or not name.endswith(".so") or not (source / name).is_file():
            raise ValueError(f"Missing staged Android runtime: {source / name}")
    destination = build / "aether_runtime_jni" / abi
    destination.mkdir(parents=True, exist_ok=True)
    for previous in destination.glob("*.so"):
        previous.unlink()
    for name in names:
        shutil.copyfile(source / name, destination / name)
    (build / "aether_runtime.gradle").write_text(
        "android.sourceSets.main.jniLibs.srcDir file('aether_runtime_jni')\n")
    include = "apply from: 'aether_runtime.gradle'"
    text = gradle.read_text()
    if include not in text:
        gradle.write_text(text.rstrip() + "\n\n" + include + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--abi", required=True)
    args = parser.parse_args()
    stage(args.build_dir, args.source_dir, args.manifest, args.abi)
