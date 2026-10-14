#!/usr/bin/env python3
"""Keep the runtimes' SDL2 symbols separate from Godot's embedded SDL3."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
from typing import Optional


SDL_SYMBOL = re.compile(r"^_?(?:SDL_|PLATFORM_hid_|hid_)")


def find_tool(name: str, llvm_bin: Optional[Path] = None) -> str:
    candidates = [llvm_bin / name] if llvm_bin else []
    found = shutil.which(name)
    if found:
        candidates.append(Path(found))
    candidates.extend(Path(root) / name for root in (
        "/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin"))
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    raise RuntimeError(f"{name} is required; install LLVM (brew install llvm)")


def sdl_symbols(nm: str, archive: Path, defined: bool = False) -> set[str]:
    args = [nm, "--extern-only", "--format=posix"]
    if defined:
        args.append("--defined-only")
    result = subprocess.run(args + [str(archive)], check=True,
                            capture_output=True, text=True)
    symbols = set()
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) >= 2 and len(fields[1]) == 1 and SDL_SYMBOL.match(fields[0]):
            symbols.add(fields[0])
    return symbols


def isolate(sdl_archive: Path, directory: Path,
            llvm_bin: Optional[Path] = None) -> int:
    nm = find_tool("llvm-nm", llvm_bin)
    objcopy = find_tool("llvm-objcopy", llvm_bin)
    definitions = sdl_symbols(nm, sdl_archive, defined=True)
    if not definitions:
        raise RuntimeError("The SDL2 source archive has no SDL symbols")
    count = 0
    # SDK compatibility fallbacks belong to Godot's SDL, not to the runtimes.
    archives = [p for p in sorted(directory.glob("*.a"))
                if p.name != "libios_sdk_compat_symbols.a"]
    if not archives:
        raise RuntimeError("No staged iOS runtime archives found")
    pending = []
    for archive in archives:
        original = sdl_symbols(nm, archive)
        if not original:
            continue
        if original - definitions:
            raise RuntimeError(
                f"{archive.name} references SDL symbols absent from the SDL2 archive")
        pending.append(archive)
    with tempfile.TemporaryDirectory(prefix="aether-sdl-", dir=directory) as tmp:
        mapping = Path(tmp) / "symbols.txt"
        mapping.write_text("".join(
            f"{name} {'_' if name.startswith('_') else ''}AetherSDL2_{name.lstrip('_')}\n"
            for name in sorted(definitions)))
        for archive in pending:
            output = Path(tmp) / archive.name
            subprocess.run([objcopy, "--redefine-syms", str(mapping),
                            str(archive), str(output)], check=True)
            if sdl_symbols(nm, output):
                raise RuntimeError(f"SDL isolation did not cover {archive.name}")
            output.chmod(archive.stat().st_mode & 0o777)
        for archive in pending:
            output = Path(tmp) / archive.name
            os.replace(output, archive)
            count += 1
    return count


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdl-archive", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--llvm-bin", type=Path)
    args = parser.parse_args()
    try:
        count = isolate(args.sdl_archive, args.directory, args.llvm_bin)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"SDL2 isolation failed: {error}\n")
    print(f"Isolated SDL2 symbols in {count} iOS runtime archives")


if __name__ == "__main__":
    main()
