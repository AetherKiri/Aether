#!/usr/bin/env python3
"""Apply or verify a complete patch series against its genuine pinned source.

Later patches can edit earlier patch contexts. Verify the series' final files
against a fresh pinned archive instead of independently reversing each patch.
Partial/stale series and unrelated tracked source changes are rejected.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile


def snapshot(path):
    if path.is_symlink():
        return ("symlink", os.readlink(path))
    if not path.exists():
        return None
    if not path.is_file():
        return ("unexpected-directory",)
    return ("file", hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mode & 0o111)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", required=True, type=Path)
    parser.add_argument("--pin", required=True)
    parser.add_argument("patches", nargs="+", type=Path)
    args = parser.parse_args()
    checkout = args.checkout.resolve()
    patches = [path.resolve() for path in args.patches]
    actual = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    if actual != args.pin:
        raise SystemExit(f"Unsupported source revision: {actual}; expected {args.pin}")
    paths = set()
    for patch in patches:
        for before, after in re.findall(r"^diff --git a/(\S+) b/(\S+)$", patch.read_text(), re.M):
            for name in (before, after):
                path = Path(name)
                if path.is_absolute() or ".." in path.parts:
                    raise SystemExit("Patch contains a path outside the checkout: " + name)
                paths.add(name)
    if not paths:
        raise SystemExit("Patch series contains no source paths")
    changed = set(subprocess.check_output(["git", "-C", str(checkout), "diff", "--name-only", "HEAD"], text=True).splitlines())
    unrelated = changed - paths
    if unrelated:
        raise SystemExit("Unexpected tracked source drift outside the patch series: " + ", ".join(sorted(unrelated)))
    tracked = set(subprocess.check_output(["git", "-C", str(checkout), "ls-files"], text=True).splitlines())
    with tempfile.TemporaryDirectory(prefix="renpy-complete-patch-series-") as temporary:
        expected = Path(temporary)
        archive = subprocess.Popen(["git", "-C", str(checkout), "archive", args.pin, *sorted(paths & tracked)], stdout=subprocess.PIPE)
        assert archive.stdout is not None
        with tarfile.open(fileobj=archive.stdout, mode="r|*") as source:
            source.extractall(expected, filter="data")
        if archive.wait():
            raise SystemExit("Could not archive the genuine pinned patch inputs")
        pristine = {name: snapshot(expected / name) for name in paths}
        for patch in patches:
            subprocess.run(["git", "apply", "--check", str(patch)], cwd=expected, check=True)
            subprocess.run(["git", "apply", str(patch)], cwd=expected, check=True)
        patched = {name: snapshot(expected / name) for name in paths}
        current = {name: snapshot(checkout / name) for name in paths}
        if current == patched:
            print("Complete pinned patch series already applied and verified: " + str(checkout))
            return
        if current != pristine:
            drift = sorted(name for name in paths if current[name] != patched[name])
            raise SystemExit("Source drift or partial/stale patch series; use a clean pinned checkout. Differing files: " + ", ".join(drift))
        for patch in patches:
            subprocess.run(["git", "apply", "--check", str(patch)], cwd=checkout, check=True)
            subprocess.run(["git", "apply", str(patch)], cwd=checkout, check=True)
            print("applied: " + patch.name)
        if any(snapshot(checkout / name) != patched[name] for name in paths):
            raise SystemExit("Source changed while applying the patch series")
        print("Complete pinned patch series applied and verified: " + str(checkout))


if __name__ == "__main__":
    main()
