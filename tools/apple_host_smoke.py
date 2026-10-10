#!/usr/bin/env python3
"""Build-independent Apple host G0 smoke, with engine and GPU PNG evidence."""
import argparse
import csv
import hashlib
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration", type=float, default=310, help="seconds; G0 requires >=300")
    parser.add_argument("--game", choices=("kag3", "ons", "both"), default="both")
    parser.add_argument("--game-path", type=Path, help="custom game data directory (overrides --game)")
    parser.add_argument("--require-native", action="store_true", help="require a native GPU frame for a custom game")
    parser.add_argument("--renderer", choices=("software", "metal"), default="software")
    parser.add_argument("--presentation", choices=("metal", "image"), default="metal")
    parser.add_argument("--profile", action="store_true", help="record host work and tick-to-GPU-completion, including MTKView")
    parser.add_argument("--drawable-1080p", action="store_true", help="use a real 1920x1080 Metal drawable (requires --profile)")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not math.isfinite(args.duration) or args.duration < 30:
        parser.error("duration must be >=30 to capture input progression")
    if args.drawable_1080p and (not args.profile or args.presentation != "metal"):
        parser.error("drawable-1080p requires --profile and Metal presentation")
    root = Path(__file__).resolve().parent.parent
    binary = root / "out/apple_host/derived/Build/Products/Debug/AetherHost.app/Contents/MacOS/AetherHost"
    output = args.output or root / "out/apple_host/evidence" / time.strftime("smoke-%Y%m%d-%H%M%S")
    games = {"kag3": root / "demos/aetherkiri-kag3/data",
             "ons": root / "tests/fixtures/apple_host_ons_input"}
    if args.game != "both":
        games = {args.game: games[args.game]}
    if args.game_path:
        games = {"custom": args.game_path.expanduser().resolve()}
        if not games["custom"].is_dir():
            parser.error("game-path must be an existing data directory")
    processes = []
    failures = []
    final_capture = str(int(args.duration - 5))
    try:
        for name, game in games.items():
            folder = output / name
            folder.mkdir(parents=True, exist_ok=True)
            env = os.environ.copy()
            env.update(AETHER_HOST_AUTORUN="1", AETHER_HOST_LIBRARY_ROOT=str((folder / "library").resolve()), AETHER_HOST_GAME_PATH=str(game),
                       AETHER_HOST_DEFAULT_FONT=str(root / "apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf"),
                       AETHER_HOST_TEST_INPUT="8", AETHER_HOST_PRESENTATION=args.presentation,
                       AETHER_HOST_RENDERER=args.renderer,
                       AETHER_HOST_DRAWABLE_1080P="1" if args.drawable_1080p else "0",
                       AETHER_HOST_PROFILE="1" if args.profile else "0",
                       AETHER_HOST_CAPTURE_AFTER=f"6,20,{final_capture}",
                       AETHER_HOST_CAPTURE_DIR=str(folder.resolve()),
                       AETHER_HOST_EXIT_AFTER=str(args.duration))
            log = (folder / "run.log").open("w")
            try:
                process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT)
            except BaseException:
                log.close()
                raise
            processes.append((name, folder, process, log))
        deadline = time.monotonic() + args.duration + 30
        for name, folder, process, log in processes:
            code = process.wait(timeout=max(1, deadline - time.monotonic()))
            log.close()
            text = (folder / "run.log").read_text(errors="replace")
            required = ("startup state: SUCCEEDED", "input pointer type=1", "input pointer type=3",
                        "input key down", "engine destroyed")
            errors = [f"missing {entry}" for entry in required if entry not in text]
            if code:
                errors.append(f"exit code {code}")
            for tag in ("6", "20", final_capture):
                for prefix in (("frame", "metal") if args.presentation == "metal" else ("frame",)):
                    if not (folder / f"aetherhost-{prefix}-{tag}.png").is_file():
                        errors.append(f"missing {prefix} capture at {tag}s")
            before = folder / "aetherhost-frame-6.png"
            after = folder / "aetherhost-frame-20.png"
            if before.is_file() and after.is_file():
                if hashlib.sha256(before.read_bytes()).digest() == hashlib.sha256(after.read_bytes()).digest():
                    errors.append("input did not change the captured game frame")
            if args.presentation == "metal":
                differences = [int(value) for value in re.findall(r"RGB max diff=(\d+)", text)]
                if len(differences) != 3 or max(differences, default=255) > 1:
                    errors.append(f"GPU/engine RGB comparison failed: {differences}")
                if "Metal presentation failed" in text or "presentation=metal-upload" not in text:
                    errors.append("Metal presentation fell back or was unavailable")
            if args.renderer == "metal":
                if "renderer=metal-bridge" not in text:
                    errors.append("native renderer was not enabled")
                if (name == "kag3" or args.require_native) and "native GPU frame" not in text:
                    errors.append("game did not publish a native GPU texture")
                # The built-in KAG fixture stays native throughout. Custom games may
                # publish CPU video frames between native scenes; require-native
                # checks native capability, not an exclusively native timeline.
                if name == "kag3" and args.presentation == "metal" and "native_readbacks=3" not in text:
                    errors.append("native frame path performed unexpected CPU readbacks")
                if not re.search(r"Metal bridge .*failures=0", text):
                    errors.append("Metal bridge execution errors or missing diagnostics")
            if args.profile and args.presentation == "metal":
                csv_path = folder / "aetherhost-presentation.csv"
                rows = list(csv.DictReader(csv_path.open())) if csv_path.is_file() else []
                if len(rows) < 60:
                    errors.append(f"insufficient GPU completion samples: {len(rows)}")
                if args.drawable_1080p and any(
                    (row["drawable_width"], row["drawable_height"]) != ("1920", "1080")
                    for row in rows
                ):
                    errors.append("presentation profile contains non-1080p drawables")
                if len({row["tick"] for row in rows}) != len(rows):
                    errors.append("duplicate tick samples in presentation profile")
                if any(not math.isfinite(float(row["tick_to_completion_ms"])) or
                       float(row["tick_to_completion_ms"]) <= 0 for row in rows):
                    errors.append("invalid completion durations")
            if errors:
                failures.append(name)
                print(f"FAIL {name}: {'; '.join(errors)}")
            else:
                print(f"PASS {name}: {args.duration:g}s, input progression, captures, clean shutdown")
        print(f"Evidence: {output.resolve()}")
        if args.duration < 300:
            print("Short smoke only: this does not satisfy the five-minute G0 gate.")
        return bool(failures)
    finally:
        for _, _, process, log in processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            log.close()


if __name__ == "__main__":
    sys.exit(main())
