#!/usr/bin/env python3
"""Measure fresh Apple host process startup to engine success."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


def percentile(values, p):
    ordered = sorted(values)
    if not ordered:
        return math.nan
    if len(ordered) == 1:
        return ordered[0]
    index = (len(ordered) - 1) * p
    low, high = math.floor(index), math.ceil(index)
    if low == high:
        return ordered[low]
    return ordered[low] + (ordered[high] - ordered[low]) * (index - low)


def wait_for_success(process, started, log_path, timeout):
    deadline = time.monotonic() + timeout
    pattern = re.compile(r"startup state: SUCCEEDED")
    position = 0
    while time.monotonic() < deadline:
        if log_path.exists():
            text = log_path.read_text(errors="replace")
            match = pattern.search(text, position)
            if match:
                return time.monotonic() - started
            position = len(text)
        if process.poll() is not None:
            break
        time.sleep(0.01)
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--renderer", choices=("software", "metal"), default="software")
    parser.add_argument("--output", type=Path, default=Path("out/apple_host/evidence/cold-start"))
    args = parser.parse_args()
    if args.runs < 3 or args.runs > 30 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("runs must be 3..30 and timeout must be positive")
    root = Path(__file__).resolve().parent.parent
    host = root / "out/apple_host/derived/Build/Products/Debug/AetherHost.app/Contents/MacOS/AetherHost"
    game = root / "tests/fixtures/apple_host_controls"
    if not host.is_file() or not game.is_dir():
        parser.error("build the Debug host and keep the controls fixture available")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    results = []
    base_env = os.environ.copy()
    for key in ("AETHER_HOST_TEST_INPUT", "AETHER_HOST_TEST_KEYS", "AETHER_HOST_CAPTURE_AFTER", "AETHER_HOST_CAPTURE_DIR"):
        base_env.pop(key, None)
    for run in range(1, args.runs + 1):
        folder = output / f"run-{run:02d}"
        if folder.exists():
            shutil.rmtree(folder)
        folder.mkdir(parents=True)
        log_path = folder / "run.log"
        env = base_env.copy()
        env.update(
            AETHER_HOST_AUTORUN="1",
            AETHER_HOST_GAME_PATH=str(game),
            AETHER_HOST_LIBRARY_ROOT=str(folder / "library"),
            AETHER_HOST_DEFAULT_FONT=str(root / "apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf"),
            AETHER_HOST_RENDERER=args.renderer,
            AETHER_HOST_PRESENTATION="image",
            AETHER_HOST_EXIT_AFTER="3",
        )
        started = time.monotonic()
        with log_path.open("w") as log:
            process = subprocess.Popen([str(host)], env=env, stdout=log, stderr=subprocess.STDOUT)
            elapsed = wait_for_success(process, started, log_path, args.timeout)
            try:
                code = process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.terminate()
                code = process.wait(timeout=5)
        text = log_path.read_text(errors="replace")
        clean = code == 0 and "engine destroyed" in text and elapsed is not None
        result = {"run": run, "startup_seconds": elapsed, "exit_code": code, "clean_shutdown": clean}
        results.append(result)
        if not clean:
            raise SystemExit(f"FAIL run {run}; see {log_path}")
        print(f"PASS run {run}: {elapsed:.3f}s", flush=True)
    values = [item["startup_seconds"] for item in results]
    summary = {
        "runs": results,
        "renderer": args.renderer,
        "fixture": str(game),
        "p50_seconds": percentile(values, 0.50),
        "p95_seconds": percentile(values, 0.95),
        "max_seconds": max(values),
        "target_2_seconds_met": max(values) <= 2.0,
        "measurement": "fresh host process to first startup state SUCCEEDED line; includes process launch and engine startup, excludes library import",
    }
    (output / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({key: summary[key] for key in ("p50_seconds", "p95_seconds", "max_seconds", "target_2_seconds_met")}, indent=2))
    print(f"Evidence: {output}")


if __name__ == "__main__":
    main()
