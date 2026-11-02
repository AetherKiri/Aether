#!/usr/bin/env python3
"""Release completed Apple build trees before the next CI build phase."""

import argparse
from pathlib import Path
import shutil


def clean(workspace: Path, stage: str) -> None:
    workspace = workspace.resolve()
    platform, configuration = stage.split("-")
    export = workspace / "out/godot" / platform / configuration
    artifact = (export / "Aether.app/Contents/MacOS/Aether" if platform == "macos"
                else export / "Aether-Release-Unsigned.ipa")
    if not artifact.is_file() or artifact.stat().st_size == 0:
        raise ValueError(f"Completed application artifact is missing: {artifact}")

    build = workspace / "out" / platform / configuration
    # CI owns these generated directories. Refuse redirected paths before
    # removing anything; retained vcpkg installs may themselves be symlinks.
    if build.resolve() != build:
        raise ValueError(f"Refusing symlinked build directory: {build}")
    # Imported package metadata can retain absolute paths into the Release
    # installation even in Debug. CTest also reuses the Debug installation.
    targets = [path for path in build.iterdir() if path.name != "vcpkg_installed"] if build.exists() else []
    targets += [workspace / ".devtools/vcpkg" / name for name in ("buildtrees", "packages")]
    for path in targets:
        if path.resolve() != path:
            raise ValueError(f"Refusing symlinked intermediate directory: {path}")

    before = shutil.disk_usage(workspace).free
    for path in targets:
        if path.is_dir():
            shutil.rmtree(path)
        elif path.exists():
            path.unlink()
    after = shutil.disk_usage(workspace).free
    print(f"Completed {stage} cleanup; free space: {before / 2**30:.1f} -> {after / 2**30:.1f} GiB")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("ios-release", "macos-release", "macos-debug"))
    args = parser.parse_args()
    clean(Path.cwd(), args.stage)
