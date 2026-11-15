#!/usr/bin/env python3
"""Package the configured runtime providers in Godot's generated Gradle project."""
import argparse
from pathlib import Path
import shutil
import tempfile
import zipfile


def stage_cxx_runtime(build: Path, runtime: Path, abi: str):
    """Keep Godot's packaged libc++ consistent with the native build's NDK."""
    if not runtime.is_file():
        raise ValueError(f"Missing Android C++ runtime: {runtime}")
    data = runtime.read_bytes()
    entry = f"jni/{abi}/libc++_shared.so"
    for archive in (build / "libs").glob("*/*.aar"):
        with zipfile.ZipFile(archive) as source:
            if entry not in source.namelist() or source.read(entry) == data:
                continue
            # Godot's Gradle template deliberately picks the AAR's libc++ first.
            # Replace that generated packaging copy, preserving every other entry.
            with tempfile.NamedTemporaryFile(dir=archive.parent, suffix=".aar", delete=False) as temporary:
                temporary_path = Path(temporary.name)
            try:
                with zipfile.ZipFile(temporary_path, "w") as destination:
                    for item in source.infolist():
                        destination.writestr(item, data if item.filename == entry else source.read(item))
                temporary_path.replace(archive)
            finally:
                temporary_path.unlink(missing_ok=True)
    for configuration in ("debug", "release"):
        loose = build / "libs" / configuration / abi / "libc++_shared.so"
        if loose.is_file():
            shutil.copyfile(runtime, loose)


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
    parser.add_argument("--cxx-runtime", type=Path)
    args = parser.parse_args()
    stage(args.build_dir, args.source_dir, args.manifest, args.abi)

    if args.cxx_runtime is not None:
        stage_cxx_runtime(args.build_dir, args.cxx_runtime, args.abi)
