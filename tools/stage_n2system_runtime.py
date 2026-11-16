#!/usr/bin/env python3
"""Stage the configured NativeAOT runtime and its isolated native/font assets."""

import argparse
import os
from pathlib import Path
import shutil


def stage(source, destination, macos_bundle=False):
    if destination.name != "n2system-runtime":
        raise ValueError("destination must be the generated n2system-runtime directory")
    if macos_bundle and (destination.parent.name != "Frameworks" or
                         destination.parent.parent.name != "Contents"):
        raise ValueError("macOS destination must be Contents/Frameworks/n2system-runtime")
    if source is not None and not source.is_dir():
        raise ValueError(f"configured N2System publish directory is missing: {source}")
    if source is not None and source.resolve() == destination.resolve():
        raise ValueError("publish and destination directories must differ")
    targets = [destination]
    resources = destination.parent.parent / "Resources/n2system-runtime"
    if macos_bundle:
        targets.append(resources)
    # Both trees are generated. Remove stale fonts too when disabling N2System.
    for target in targets:
        if target.is_symlink():
            target.unlink()
        elif target.exists():
            shutil.rmtree(target)
    if source is not None:
        shutil.copytree(source, destination, ignore=shutil.ignore_patterns("*.pdb", "*.dSYM", "*.dbg"))
        fonts = destination / "Fonts"
        if macos_bundle and fonts.is_dir():
            # Frameworks is a code-only location: signing treats font licenses
            # there as unsigned nested code. Keep data in Resources and retain
            # the host's library-relative Fonts lookup through a relative alias.
            resources.mkdir(parents=True, exist_ok=True)
            fonts.rename(resources / "Fonts")
            fonts.symlink_to(os.path.relpath(resources / "Fonts", fonts.parent),
                             target_is_directory=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--macos-bundle", action="store_true")
    args = parser.parse_args()
    source_text = args.manifest.read_text().strip()
    source = Path(source_text) if source_text else None
    try:
        stage(source, args.destination, args.macos_bundle)
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
