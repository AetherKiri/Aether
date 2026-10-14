#!/usr/bin/env python3
"""Prepare an isolated macOS Ren'Py 8.5.3 SDK without changing the supplied SDK.

The SDK's SDL Objective-C classes need unique runtime names inside Aether,
which already embeds another SDL. Equal-length metadata renaming preserves
Mach-O offsets. The staged library is re-signed after modification.
"""
import argparse
import importlib.util
from pathlib import Path
import re
import shutil
import subprocess

REPO = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--greenlet", type=Path, required=True, help="Directory containing the Python 3.12 greenlet package")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    sdk = args.sdk.resolve()
    output = args.output.resolve()
    if output.exists():
        parser.error("Use a fresh output directory")
    if not (sdk / "renpy/vc_version.py").is_file() or "8.5.3.26051504" not in (sdk / "renpy/vc_version.py").read_text():
        parser.error("The prototype requires the matching Ren'Py 8.5.3 SDK")
    spec = importlib.util.spec_from_file_location("renpy_stage_copy", REPO / "apps/godot_app/renpy_runtime/host.py")
    copy = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(copy)
    def clone(source, target):
        copy.copy_file(Path(source), Path(target))
        return target
    output.mkdir(parents=True)
    for name in ("renpy", "lib/python3.12", "lib/py3-mac-universal"):
        shutil.copytree(sdk / name, output / name, copy_function=clone,
                        ignore=shutil.ignore_patterns("__pycache__"))
    for name in ("renpy.py", "LICENSE.txt"):
        clone(sdk / name, output / name)
    shutil.copytree(args.greenlet / "greenlet", output / "lib/python3.12/site-packages/greenlet", copy_function=clone,
                    ignore=shutil.ignore_patterns("__pycache__", "tests"))
    for metadata in args.greenlet.glob("greenlet-*.dist-info"):
        shutil.copytree(metadata, output / "lib/python3.12/site-packages" / metadata.name, copy_function=clone)
    library = output / "lib/py3-mac-universal/librenpython.dylib"
    symbols = subprocess.run(["nm", str(library)], check=True, capture_output=True, text=True).stdout
    names = sorted(set(re.findall(r"_OBJC_CLASS_\$_((?:SDL|Cocoa_)\w+)", symbols)))
    data = library.read_bytes()
    for name in names:
        data = data.replace(name.encode() + b"\0", ("RNP" + name[3:]).encode() + b"\0")
    library.write_bytes(data)
    subprocess.run(["codesign", "--force", "--sign", "-", str(library)], check=True)
    (output / "AETHER_NATIVE_SDK.txt").write_text(
        "Ren'Py 8.5.3.26051504. SDL Objective-C class metadata renamed SDL to RNP for embedding.\n"
        "Original source: https://github.com/renpy/renpy and https://github.com/renpy/renpy-build\n")
    print(f"AETHER_RENPY_SDK={output}")


if __name__ == "__main__":
    main()
