#!/usr/bin/env python3
"""Link and embed the isolated Ren'Py framework in a real Godot Xcode export."""

import argparse
import re
from pathlib import Path


def patch(project: Path, framework: Path) -> None:
    if not framework.is_dir():
        raise ValueError(f"Rebuilt runtime framework is missing: {framework}")
    name = framework.name
    text = project.read_text()
    prefix = "A3F0040000000000000000"
    reference, linked, embedded = (prefix + suffix for suffix in ("04", "03", "05"))
    if f"{reference} /* {name} */ =" in text:
        return

    def insert(pattern: str, addition: str, description: str) -> None:
        nonlocal text
        text, count = re.subn(pattern, lambda m: m[0] + addition, text, count=1, flags=re.S)
        if count != 1:
            raise ValueError(f"Godot Xcode export lacks {description}; refusing an incomplete app")

    insert(r"/\* Begin PBXBuildFile section \*/\n",
           f"\t\t{linked} /* {name} in Frameworks */ = {{isa = PBXBuildFile; fileRef = {reference} /* {name} */; }};\n"
           f"\t\t{embedded} /* {name} in Embed Frameworks */ = {{isa = PBXBuildFile; fileRef = {reference} /* {name} */; settings = {{ATTRIBUTES = (CodeSignOnCopy, RemoveHeadersOnCopy, ); }}; }};\n",
           "PBXBuildFile section")
    insert(r"/\* Begin PBXFileReference section \*/\n",
           f'\t\t{reference} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; path = Frameworks/{name}; sourceTree = "<group>"; }};\n',
           "PBXFileReference section")
    insert(r"[0-9A-F]+ /\* Aether \*/ = \{\s*isa = PBXGroup;\s*children = \(\n",
           f"\t\t\t\t{reference} /* {name} */,\n", "Aether source group")
    insert(r"/\* Begin PBXFrameworksBuildPhase section \*/.*?files = \(\n",
           f"\t\t\t\t{linked} /* {name} in Frameworks */,\n", "framework link phase")
    insert(r'isa = PBXCopyFilesBuildPhase;(?:(?!\};).)*?dstSubfolderSpec = 10;\s*files = \(\n',
           f"\t\t\t\t{embedded} /* {name} in Embed Frameworks */,\n", "framework embed phase")
    project.write_text(text)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("framework", type=Path)
    args = parser.parse_args()
    try:
        patch(args.project, args.framework)
    except (OSError, ValueError) as exc:
        parser.exit(1, f"iOS runtime integration failed: {exc}\n")


if __name__ == "__main__":
    main()
