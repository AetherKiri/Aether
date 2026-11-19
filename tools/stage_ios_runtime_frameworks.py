#!/usr/bin/env python3
"""Stage the configured iOS providers and declare their Godot export dependencies."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import shutil


def stage(manifest: Path, project: Path, configuration: str, gdextension: Path) -> list[Path]:
    frameworks = [Path(line.strip()) for line in manifest.read_text().splitlines() if line.strip()]
    names: set[str] = set()
    for framework in frameworks:
        if framework.suffix != ".framework" or not (framework / framework.stem).is_file():
            raise ValueError(f"Missing iOS runtime framework: {framework}")
        if framework.name in names:
            raise ValueError(f"Duplicate iOS runtime framework: {framework.name}")
        names.add(framework.name)
    destination = project / "bin" / "ios" / configuration
    destination.mkdir(parents=True, exist_ok=True)
    staged = []
    for framework in frameworks:
        target = destination / framework.name
        if framework.resolve() != target.resolve():
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(framework, target, symlinks=True)
        staged.append(target)

    source = gdextension.read_text()
    match = re.search(r"(?m)^\[dependencies\]\s*$", source)
    if not match:
        source = source.rstrip() + "\n\n[dependencies]\n"
        match = re.search(r"(?m)^\[dependencies\]\s*$", source)
    start = match.end()
    next_section = re.search(r"(?m)^\[", source[start:])
    end = start + next_section.start() if next_section else len(source)
    dependencies = source[start:end]
    key = f"ios.{configuration}"
    # Only this export's iOS provider entries are generated. Other platform
    # sections stay intact; an empty manifest removes stale provider entries.
    pattern = rf"(?ms)^{re.escape(key)}\s*=\s*(\{{.*?\}})[ \t]*\n?"
    entry = re.search(pattern, dependencies)
    existing = json.loads(re.sub(r",\s*}", "}", entry.group(1))) if entry else {}
    generated_prefix = f"res://bin/ios/{configuration}/"
    entries = {path: target for path, target in existing.items()
               if not (path.startswith(generated_prefix) and path.endswith(".framework"))}
    entries.update({"res://" + path.relative_to(project).as_posix(): "" for path in staged})
    dependencies = re.sub(pattern, "", dependencies)
    if entries:
        dependencies = dependencies.rstrip() + "\n" + key + " = {\n" + ",\n".join(
            f"  {json.dumps(path)}: {json.dumps(target)}" for path, target in entries.items()) + "\n}\n"
    gdextension.write_text(source[:start] + dependencies + source[end:])
    return staged


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--configuration", choices=("debug", "release"), required=True)
    parser.add_argument("--gdextension", type=Path, required=True)
    args = parser.parse_args()
    stage(args.manifest, args.project, args.configuration, args.gdextension)


if __name__ == "__main__":
    main()
