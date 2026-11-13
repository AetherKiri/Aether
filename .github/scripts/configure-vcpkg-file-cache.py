#!/usr/bin/env python3
"""Configure file-based dependency reuse and identify the CI toolchain."""

import argparse
import hashlib
import os
from pathlib import Path
import subprocess


def configure(vcpkg, android=False):
    binary_cache = Path(os.environ["VCPKG_DEFAULT_BINARY_CACHE"]).resolve()
    downloads = Path(os.environ["VCPKG_DOWNLOADS"]).resolve()
    github_env = Path(os.environ["GITHUB_ENV"])
    github_output = Path(os.environ["GITHUB_OUTPUT"])
    if any(char in str(binary_cache) for char in "\r\n"):
        raise ValueError("The binary cache path must not contain newlines")

    digest = hashlib.sha256()
    digest.update(vcpkg.read_bytes())
    if android:
        digest.update((Path(os.environ["ANDROID_NDK_HOME"]) / "source.properties").read_bytes())
    # vcpkg scripts can change independently of its bootstrapped executable.
    # CMake/tool updates also affect package ABIs: an immutable Actions cache
    # needs a fresh key so new binaries can be saved after such an update.
    commands = [["git", "-C", str(vcpkg.parent), "rev-parse", "HEAD"]]
    commands.extend([tool, "--version"] for tool in ("cc", "c++", "cmake", "ninja"))
    for command in commands:
        digest.update(subprocess.check_output(command, env=dict(os.environ, LC_ALL="C")))

    binary_cache.mkdir(parents=True, exist_ok=True)
    downloads.mkdir(parents=True, exist_ok=True)
    # vcpkg escapes separators using a backtick, including literal backticks.
    location = str(binary_cache).replace("`", "``").replace(",", "`,").replace(";", "`;")
    with github_env.open("a") as output:
        # Clear the NuGet provider: certificate failures can otherwise delay
        # every restore and upload before falling back to a source build.
        # Local writes are safe even for fork PRs and allow Debug to reuse
        # Release's dependencies. Only the workflow may persist this cache,
        # and its save steps exclude untrusted pull requests.
        output.write(f"VCPKG_BINARY_SOURCES=clear;files,{location},readwrite\n")
    with github_output.open("a") as output:
        output.write(f"toolchain-key={digest.hexdigest()}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vcpkg", type=Path)
    parser.add_argument("--android", action="store_true")
    args = parser.parse_args()
    configure(args.vcpkg, args.android)
