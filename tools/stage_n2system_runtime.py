#!/usr/bin/env python3
"""Stage the configured NativeAOT runtime and its isolated native/font assets."""

import argparse
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    destination = args.destination
    if destination.name != "n2system-runtime":
        parser.error("destination must be the generated n2system-runtime directory")
    source_text = args.manifest.read_text().strip()
    source = Path(source_text) if source_text else None
    if source is not None and not source.is_dir():
        parser.error(f"configured N2System publish directory is missing: {source}")
    if source is not None and source.resolve() == destination.resolve():
        parser.error("publish and destination directories must differ")
    # Replace this generated tree so a disabled runtime or removed dependency
    # cannot leak into the next export from an earlier editor build.
    if destination.is_symlink():
        destination.unlink()
    elif destination.exists():
        shutil.rmtree(destination)
    if source is not None:
        shutil.copytree(source, destination, ignore=shutil.ignore_patterns("*.pdb", "*.dSYM", "*.dbg"))


if __name__ == "__main__":
    main()
