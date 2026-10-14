#!/usr/bin/env python3
"""Copy a prepared desktop runtime into an exported Aether application."""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil


def stage(platform, runtime, destination):
    repo = Path(__file__).resolve().parents[1]
    spec = importlib.util.spec_from_file_location("renpy_copy", repo / "apps/godot_app/renpy_runtime/host.py")
    copy = importlib.util.module_from_spec(spec); spec.loader.exec_module(copy)
    def clone(src, dst):
        copy.copy_file(Path(src), Path(dst)); return dst
    if not (runtime / "renpy.py").is_file():
        raise ValueError("Not a prepared Ren'Py runtime")
    def reset(target):
        if target.is_symlink():
            raise ValueError("The runtime destination must not be a symlink")
        if target.exists(): shutil.rmtree(target)
    if platform == "linux":
        target = destination / "renpy-runtime"
        reset(target)
        shutil.copytree(runtime, target, copy_function=clone)
        return
    bundle = destination.resolve()
    target = bundle / "Contents/Resources/renpy-runtime"
    reset(target)
    shutil.copytree(runtime, target, copy_function=clone)
    # Put executable code in Frameworks so distribution signing covers it in
    # the same pass as Aether's other native libraries. Python data stays in
    # Resources; relative symlinks preserve the SDK's import/layout contract.
    native = bundle / "Contents/Frameworks/renpy-runtime"
    reset(native)
    native.mkdir(parents=True, exist_ok=True)
    source = target / "lib/py3-mac-universal"
    shutil.copytree(source, native / "mac-universal", copy_function=clone, dirs_exist_ok=True)
    shutil.rmtree(source)
    source.symlink_to(os.path.relpath(native / "mac-universal", source.parent), target_is_directory=True)
    for file in (target / "lib/python3.12/site-packages/greenlet").glob("*.so"):
        destination = native / file.name
        clone(file, destination); file.unlink()
        file.symlink_to(os.path.relpath(destination, file.parent))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("macos", "linux"))
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    stage(args.platform, args.runtime.resolve(), args.destination.resolve())


if __name__ == "__main__":
    main()
