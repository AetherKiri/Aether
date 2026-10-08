#!/usr/bin/env python3
"""Verify complete-series idempotency and drift refusal on genuine pins.

Optional Ren'Py/greenlet checkouts also exercise prepare -> prepare -> the real
build preflight. That preflight must reject the absent NDK, not pretend a build.
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
HELPER = REPO / "tools/apply_renpy_mobile_patch_series.py"
PIN = "7bfab40c1174f622f644b24669afd5fb167fbb79"


def clone(source, destination, pin):
    subprocess.run(["git", "clone", "--shared", "--quiet", "--no-checkout", str(source), str(destination)], check=True)
    subprocess.run(["git", "-C", str(destination), "checkout", "--quiet", "--detach", pin], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_source", type=Path)
    parser.add_argument("--renpy-src", type=Path)
    parser.add_argument("--greenlet-src", type=Path)
    args = parser.parse_args()
    patches = sorted((REPO / "bridge/renpy_runtime/mobile_launcher/patches/native").glob("000[0-9]-*.patch"))
    with tempfile.TemporaryDirectory(prefix="renpy-patch-series-") as temporary:
        root = Path(temporary) / "renpy-build"
        clone(args.build_source, root, PIN)
        command = [sys.executable, str(HELPER), "--checkout", str(root), "--pin", PIN, *map(str, patches)]
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
        repeated = subprocess.run(command, check=True, capture_output=True, text=True)
        assert "already applied and verified" in repeated.stdout
        for relative in ("runtime/librenpython3.c", "build.sh"):
            path = root / relative
            before = path.read_bytes()
            changed = before + b"\n# actual source drift\n"
            path.write_bytes(changed)
            failure = subprocess.run(command, capture_output=True, text=True)
            assert failure.returncode != 0 and "drift" in failure.stderr.lower(), failure.stderr
            assert path.read_bytes() == changed, "drift was overwritten instead of rejected"
            path.write_bytes(before)
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
        partial = Path(temporary) / "partial"
        clone(args.build_source, partial, PIN)
        subprocess.run(["git", "apply", str(patches[0])], cwd=partial, check=True)
        failure = subprocess.run([sys.executable, str(HELPER), "--checkout", str(partial), "--pin", PIN, *map(str, patches)], capture_output=True, text=True)
        assert failure.returncode != 0 and "partial/stale patch series" in failure.stderr, failure.stderr
        if args.renpy_src or args.greenlet_src:
            assert args.renpy_src and args.greenlet_src
            clone(args.renpy_src, root / "renpy", "39895c1e017f0b36ffea2447d97eccd69d76ee1c")
            clone(args.greenlet_src, root / "aether-greenlet", "65f8da82b13a1273e55a6bfcbd1f9da09fc4eb7a")
            runner = ["bash", str(REPO / "tools/run_renpy_mobile_source_build.sh"), "--platform", "android", "--renpy-build", str(root)]
            for _ in range(2):
                subprocess.run([*runner, "--mode", "prepare"], check=True, stdout=subprocess.DEVNULL)
            preflight = subprocess.run([*runner, "--mode", "build"], capture_output=True, text=True)
            assert preflight.returncode != 0 and "source-build preflight failed" in preflight.stdout + preflight.stderr, preflight.stdout + preflight.stderr
            assert "patch does not apply" not in preflight.stderr
            assert "android-ndk-r29-linux.zip" in preflight.stdout + preflight.stderr
            print("Real pinned prepare -> prepare -> build preflight passed; missing NDK correctly refused compilation")
    print("Complete pinned patch-series idempotency and source-drift checks passed; no native build or gameplay performed")


if __name__ == "__main__":
    main()
