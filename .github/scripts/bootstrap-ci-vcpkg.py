#!/usr/bin/env python3
"""Bootstrap CI's vcpkg checkout at the manifest's registry baseline."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess


def bootstrap(root, configuration, repository="https://github.com/microsoft/vcpkg.git"):
    baseline = json.loads(configuration.read_text())["default-registry"]["baseline"]
    if not re.fullmatch(r"[0-9a-f]{40}", baseline):
        raise ValueError("Expected a full vcpkg registry baseline commit")
    # Bootstrap itself downloads tools, before the binary-cache setup step.
    for variable in ("VCPKG_DOWNLOADS", "VCPKG_DEFAULT_BINARY_CACHE"):
        if os.environ.get(variable):
            Path(os.environ[variable]).mkdir(parents=True, exist_ok=True)
    root = root.resolve()
    if not root.exists():
        root.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", repository, str(root)], check=True)
    if not (root / ".git").exists():
        raise ValueError(f"Refusing to replace a non-git directory: {root}")
    previous = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"]).decode().strip()
    if subprocess.run(["git", "-C", str(root), "cat-file", "-e", baseline + "^{commit}"],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        subprocess.run(["git", "-C", str(root), "fetch", "--no-tags", "origin", baseline], check=True)
    subprocess.run(["git", "-C", str(root), "checkout", "--detach", baseline], check=True)
    if previous != baseline or not os.access(root / "vcpkg", os.X_OK):
        subprocess.run(["bash", "./bootstrap-vcpkg.sh", "-disableMetrics"], cwd=root, check=True)
    if os.environ.get("GITHUB_ENV"):
        with open(os.environ["GITHUB_ENV"], "a") as output:
            output.write(f"VCPKG_ROOT={root}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--configuration", type=Path, default=Path("vcpkg-configuration.json"))
    args = parser.parse_args()
    bootstrap(args.root, args.configuration)
