#!/usr/bin/env python3
"""Key compiler snapshots by tracked native inputs, not CI runs or UI assets."""

import hashlib
import os
from pathlib import Path
import subprocess


def native_key(root, toolchain=b""):
    # Gitlinks include the exact engine revisions without reading private files.
    # The index is the checked-out commit in CI, so mtimes and merge SHAs do not
    # invalidate a cache when its native inputs have not changed.
    inputs = subprocess.check_output([
        "git", "-C", str(root), "ls-files", "--stage", "-z", "--",
        "CMakeLists.txt", "CMakePresets.json", "cmake", "abi", "bridge", "src",
        "include", "host", "plugins", "packages", "third_party", "vcpkg",
        "vcpkg.json", "vcpkg-configuration.json", "build.sh", "scripts/build_*.sh",
        "tools/linux_env.sh", "tools/setup_linux.sh",
    ])
    return hashlib.sha256(inputs + b"\0" + toolchain).hexdigest()


if __name__ == "__main__":
    versions = [subprocess.check_output([tool, "--version"], env=dict(os.environ, LC_ALL="C"))
                for tool in ("cc", "c++", "cmake")]
    versions.append(os.environ.get("ANDROID_NDK_VERSION", "").encode())
    key = native_key(Path.cwd(), b"\0".join(versions))
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"key={key}\n")
