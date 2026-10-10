#!/usr/bin/env python3
"""Compare software/Metal self-test states at original size and synthetic 1080p.

Copies the authorized TJS fixture into the evidence folder. Disables its repeating
BGM timer for deterministic rendering; audio validation is outside this test.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

CAPTURES = (3, 7, 10, 13, 16, 19, 22, 26)
KEYS = "9:90,12:83,15:67,18:83,21:67,24:90"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path, help="aetherkiri-test directory or its data directory")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    source = args.game.expanduser().resolve()
    if not (source / "startup.tjs").exists():
        source /= "data"
    text = (source / "startup.tjs").read_text()
    if "var SW = 640;" not in text or "var SH = 480;" not in text or "startupTimer.interval = 1500;" not in text:
        parser.error("requires the known 640x480 aetherkiri-test TJS fixture")
    output = args.output.resolve()
    if output.exists():
        parser.error("output must be a new directory to preserve evidence")
    output.mkdir(parents=True)
    binary = root / "out/apple_host/derived/Build/Products/Debug/AetherHost.app/Contents/MacOS/AetherHost"
    compare = output / "compare-images"
    subprocess.run(["xcrun", "swiftc", str(root / "tools/apple_host_compare.swift"), "-o", str(compare)], check=True)
    source_hash = hashlib.sha256((source / "startup.tjs").read_bytes()).hexdigest()
    processes = []
    results = {}
    try:
        for size in ("640x480", "1920x1080"):
            game = output / "games" / size
            shutil.copytree(source, game, ignore=shutil.ignore_patterns("savedata", "*.log"))
            script = text + "\n// Deterministic render-only comparison: disable recurring audio HUD updates.\nstartupTimer.enabled = false;\n"
            if size == "1920x1080":
                script = script.replace("var SW = 640;", "var SW = 1920;").replace("var SH = 480;", "var SH = 1080;")
            (game / "startup.tjs").write_text(script)
            for renderer in ("software", "metal"):
                name = f"{size}-{renderer}"
                folder = output / name
                folder.mkdir()
                env = os.environ.copy()
                env.update(AETHER_HOST_AUTORUN="1", AETHER_HOST_LIBRARY_ROOT=str((folder / "library").resolve()), AETHER_HOST_GAME_PATH=str(game),
                           AETHER_HOST_RENDERER=renderer, AETHER_HOST_PRESENTATION="metal",
                           AETHER_HOST_PROFILE="1", AETHER_HOST_TEST_INPUT="5",
                           AETHER_HOST_TEST_KEYS=KEYS, AETHER_HOST_EXIT_AFTER="28",
                           AETHER_HOST_CAPTURE_AFTER=",".join(map(str, CAPTURES)),
                           AETHER_HOST_CAPTURE_DIR=str(folder),
                           AETHER_HOST_DEFAULT_FONT=str(root / "apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf"))
                log = (folder / "run.log").open("w")
                try:
                    process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=subprocess.STDOUT)
                except BaseException:
                    log.close()
                    raise
                processes.append((name, folder, process, log))
        deadline = time.monotonic() + 65
        for name, folder, process, log in processes:
            code = process.wait(timeout=max(1, deadline - time.monotonic()))
            log.close()
            transcript = (folder / "run.log").read_text(errors="replace")
            errors = []
            for marker in ("startup state: SUCCEEDED", "input pointer type=1", "input pointer type=3", "engine destroyed"):
                if marker not in transcript:
                    errors.append(f"missing {marker}")
            if code:
                errors.append(f"exit={code}")
            if transcript.count("TEST KEY:") != 6:
                errors.append("missing scripted layer/pattern/stack actions")
            diffs = re.findall(r"RGB max diff=(\d+)", transcript)
            if len(diffs) != len(CAPTURES) or any(int(d) != 0 for d in diffs):
                errors.append(f"presentation mismatch: {diffs}")
            if name.endswith("metal"):
                if "native GPU frame" not in transcript or f"native_readbacks={len(CAPTURES)}" not in transcript:
                    errors.append("missing native frame or unexpected CPU readbacks")
                if not re.search(r"Metal bridge .*failures=0", transcript):
                    errors.append("GPU execution error")
            hashes = []
            for tag in CAPTURES:
                path = folder / f"aetherhost-frame-{tag}.png"
                if not path.exists():
                    errors.append(f"missing capture {tag}")
                else:
                    hashes.append(hashlib.sha256(path.read_bytes()).hexdigest())
            if len(hashes) == len(CAPTURES) and any(a == b for a, b in zip(hashes, hashes[1:])):
                errors.append("an input action did not change the scene")
            results[name] = {"errors": errors, "profile": re.findall(r"PROFILE .*", transcript)}
        for size in ("640x480", "1920x1080"):
            for tag in CAPTURES:
                a = output / f"{size}-software" / f"aetherhost-frame-{tag}.png"
                b = output / f"{size}-metal" / f"aetherhost-frame-{tag}.png"
                result = subprocess.run([str(compare), str(a), str(b)], capture_output=True, text=True)
                results[f"{size}-compare-{tag}"] = {"errors": [] if result.returncode == 0 else [result.stdout + result.stderr],
                                                    "comparison": result.stdout.strip()}
        manifest = {"source": str(source), "startup_sha256": source_hash,
                    "derived_changes": "disable BGM timer; 1080p variant changes SW/SH only",
                    "capture_seconds": CAPTURES, "test_keys": KEYS, "results": results,
                    "performance_scope": "host tick+texture only, excludes MTKView; four cases run concurrently"}
        (output / "result.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        for name, result in results.items():
            print(f"{'FAIL' if result['errors'] else 'PASS'} {name}: {result.get('comparison', result.get('profile', []))}")
        print(f"Evidence: {output}")
        return int(any(r["errors"] for r in results.values()))
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
    raise SystemExit(main())
