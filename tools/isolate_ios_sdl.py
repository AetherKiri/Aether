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


def collect_rename_symbols(nm: str, archives: list[Path]) -> set[str]:
    """Union of SDL-matching symbols (defined or referenced) across archives."""
    symbols: set[str] = set()
    for archive in archives:
        symbols |= sdl_symbols(nm, archive)
    return symbols


def rename_sdl_prefix(nm: str, objcopy: str, archives: list[Path],
                      output_dir: Path, prefix: str) -> list[Path]:
    """Copy archives to output_dir with every SDL symbol renamed to <prefix>_<name>.

    Used for the MAGES. runtime, which links its own SDL3 while the iOS
    extension already renames SDL2 (AetherSDL2_*) and Godot embeds another
    SDL3. Renaming impacto's SDL3 (AetherSDL3_*) keeps all three isolated.
    """
    definitions = collect_rename_symbols(nm, archives)
    if not definitions:
        # Nothing to rename; still copy so consumers find the archives.
        outputs = []
        for archive in archives:
            output = output_dir / archive.name
            shutil.copy2(archive, output)
            outputs.append(output)
        return outputs
    output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="aether-sdl3-") as tmp:
        mapping = Path(tmp) / "symbols.txt"
        mapping.write_text("".join(
            f"{name} {'_' if name.startswith('_') else ''}{prefix}_{name.lstrip('_')}\n"
            for name in sorted(definitions)))
        outputs = []
        for archive in archives:
            output = output_dir / archive.name
            subprocess.run([objcopy, "--redefine-syms", str(mapping),
                            str(archive), str(output)], check=True)
            outputs.append(output)
    return outputs


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
    parser.add_argument("--sdl-archive", type=Path,
                        help="SDL2 archive defining the rename set (isolate mode)")
    parser.add_argument("--directory", type=Path,
                        help="directory of archives to isolate (isolate mode)")
    parser.add_argument("--rename-output", type=Path,
                        help="enable rename mode: write renamed copies here")
    parser.add_argument("--rename-archive", action="append", type=Path,
                        default=[], dest="rename_archives",
                        help="input archive for rename mode (repeatable)")
    parser.add_argument("--rename-prefix", default="AetherSDL3",
                        help="symbol prefix for rename mode")
    parser.add_argument("--llvm-bin", type=Path)
    args = parser.parse_args()
    try:
        if args.rename_output is not None:
            if not args.rename_archives:
                parser.error("--rename-output requires at least one --rename-archive")
            nm = find_tool("llvm-nm", args.llvm_bin)
            objcopy = find_tool("llvm-objcopy", args.llvm_bin)
            rename_sdl_prefix(nm, objcopy, args.rename_archives,
                              args.rename_output, args.rename_prefix)
            print(f"Renamed SDL symbols in {len(args.rename_archives)} "
                  f"archives to {args.rename_prefix}_*")
        else:
            if args.sdl_archive is None or args.directory is None:
                parser.error("isolate mode requires --sdl-archive and --directory")
            count = isolate(args.sdl_archive, args.directory, args.llvm_bin)
            print(f"Isolated SDL2 symbols in {count} iOS runtime archives")
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"SDL isolation failed: {error}\n")


if __name__ == "__main__":
    main()
