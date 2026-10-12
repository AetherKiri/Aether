#!/usr/bin/env python3
"""Build-independent Apple host G0 smoke, with engine and GPU PNG evidence."""
import argparse
import csv
import hashlib
import json
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
    parser.add_argument("--output-resolution", choices=("original", "1080p", "2k", "4k"), default="1080p")
    parser.add_argument("--sampling-algorithm", choices=("nearest", "linear", "bicubic", "lanczos"), default="bicubic")
    parser.add_argument("--fps-limit", choices=("0", "60", "80", "90", "120", "144"), default=None,
                        help="engine fps_limit override; 0 follows the display refresh")
    parser.add_argument("--pace", choices=("auto", "display", "timer"), default="auto",
                        help="host tick callback source; display is preferred, timer is the fallback")
    parser.add_argument("--lifecycle", default=None,
                        help="scripted lifecycle events, e.g. 4:on,7:off (focus/hide/minimize equivalent)")
    parser.add_argument("--frame-enhancement", choices=("off", "adaptive_sharpen"), default=None,
                        help="frame enhancement override; off keeps the original frame")
    parser.add_argument("--enhancement-amount", type=float, default=None,
                        help="enhancement strength 0.0-1.0 (defaults to the saved preference)")
    parser.add_argument("--snapshots", choices=("sync", "async", "direct"), default="sync",
                        help="native frame mode; direct uses session-owned frame leases")
    parser.add_argument("--profile", action="store_true", help="record host work and tick-to-GPU-completion, including MTKView")
    parser.add_argument("--drawable-1080p", action="store_true", help="use a real 1920x1080 Metal drawable (requires --profile)")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not math.isfinite(args.duration) or args.duration < 30:
        parser.error("duration must be >=30 to capture input progression")
    if args.drawable_1080p and (not args.profile or args.presentation != "metal"):
        parser.error("drawable-1080p requires --profile and Metal presentation")
    if args.snapshots in ("async", "direct") and (args.renderer != "metal" or args.presentation != "metal"):
        parser.error("async/direct frames require Metal renderer and presentation")
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
            for variable in list(env):
                if variable.startswith("AETHER_HOST_TEST_"):
                    env.pop(variable, None)
            env.update(AETHER_HOST_AUTORUN="1", AETHER_HOST_LIBRARY_ROOT=str((folder / "library").resolve()), AETHER_HOST_GAME_PATH=str(game),
                       AETHER_HOST_DEFAULT_FONT=str(root / "apps/godot_app/assets/fonts/aetherkiri-runtime-cjk.otf"),
                       AETHER_HOST_TEST_INPUT="8", AETHER_HOST_PRESENTATION=args.presentation,
                       AETHER_HOST_RENDERER=args.renderer,
                       AETHER_HOST_OUTPUT_RESOLUTION=args.output_resolution,
                       AETHER_HOST_SAMPLING_ALGORITHM=args.sampling_algorithm,
                       AETHER_HOST_ASYNC_SNAPSHOT="1" if args.snapshots == "async" else "0",
                       AETHER_HOST_DIRECT_RENDER="1" if args.snapshots == "direct" else "0",
                       AETHER_HOST_SCHEDULING="direct",
                       AETHER_HOST_PACE=args.pace,
                       AETHER_HOST_DRAWABLE_1080P="1" if args.drawable_1080p else "0",
                       AETHER_HOST_PROFILE="1" if args.profile else "0",
                       # Profile and direct-lease runs measure drawable
                       # submission, which the presenter skips while the window
                       # is occluded, so those runs must bring it forward.
                       AETHER_HOST_ACTIVATE="1" if (args.profile or args.snapshots == "direct") else "0",
                       AETHER_HOST_CAPTURE_AFTER=f"6,20,{final_capture}",
                       AETHER_HOST_CAPTURE_DIR=str(folder.resolve()),
                       AETHER_HOST_EXIT_AFTER=str(args.duration))
            if args.fps_limit is not None:
                env["AETHER_HOST_FPS_LIMIT"] = args.fps_limit
            if args.lifecycle:
                env["AETHER_HOST_TEST_LIFECYCLE"] = args.lifecycle
            if args.frame_enhancement is not None:
                env["AETHER_HOST_FRAME_ENHANCEMENT"] = args.frame_enhancement
            if args.enhancement_amount is not None:
                env["AETHER_HOST_FRAME_ENHANCEMENT_AMOUNT"] = str(args.enhancement_amount)
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
            async_summary = None
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
                if args.frame_enhancement == "adaptive_sharpen":
                    # The enhancement intentionally changes the presented frame,
                    # so require a bounded, non-zero effect instead of parity.
                    if len(differences) != 3 or min(differences, default=0) == 0:
                        errors.append(f"enhancement did not change the presented frame: {differences}")
                    if max(differences, default=255) > 160:
                        errors.append(f"enhancement diff exceeded the local contrast bound: {differences}")
                elif len(differences) != 3 or max(differences, default=255) > 1:
                    errors.append(f"GPU/engine RGB comparison failed: {differences}")
                if "Metal presentation failed" in text or "presentation=metal-upload" not in text:
                    errors.append("Metal presentation fell back or was unavailable")
                if args.output_resolution != "original":
                    expected_output = {"1080p": "1440x1080", "2k": "1920x1440", "4k": "2880x2160"}[args.output_resolution]
                    if f"Output capture saved: {expected_output}" not in text:
                        errors.append(f"missing configured output capture {expected_output}")
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
                if args.snapshots == "direct":
                    counters = re.findall(r"leases_acquired=(\d+) leases_live=(\d+) lease_submitted=(\d+) lease_completed=(\d+) lease_failures=(\d+) frame_detach_copies=(\d+)", text)
                    if not counters:
                        errors.append("missing direct frame lifecycle counters")
                    else:
                        acquired, live, submitted, completed, lease_failures, copies = map(int, counters[-1])
                        if acquired == 0 or submitted == 0 or submitted != completed or live != 0 or lease_failures != 0:
                            errors.append(f"direct frames not drained: {counters[-1]}")
                if args.snapshots == "async":
                    counters = re.findall(r"async_submitted=(\d+) async_completed=(\d+) async_inflight=(\d+)", text)
                    if not counters:
                        errors.append("missing async snapshot teardown counters")
                    else:
                        submitted, completed, inflight = map(int, counters[-1])
                        async_summary = {"submitted": submitted, "completed": completed, "inflight": inflight}
                        if submitted == 0 or submitted != completed or inflight != 0:
                            errors.append(f"async snapshots not drained: {submitted}/{completed}/{inflight}")
                    if "Metal queue drain failed" in text:
                        errors.append("Metal queue drain failed")
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
            # Tick/render/presentation are separate counters; the smoke run must
            # report all three and never claim them as display scan-out FPS.
            pacing_stats = None
            stats_matches = re.findall(
                r"pacing stats: tick=(\d+) \(([\d.]+)/s\) render=(\d+) \(([\d.]+)/s\) "
                r"presentation=(\d+) \(([\d.]+)/s\) dropped_catch_up=(\d+) coalesced=(\d+) "
                r"resets=(\d+) max_delta_ms=(\d+)", text)
            if not stats_matches:
                errors.append("missing tick/render/presentation pacing statistics")
            else:
                ticks, tick_rate, rendered, _, presented, _, dropped, coalesced, resets, max_delta = stats_matches[-1]
                pacing_stats = {"ticks": int(ticks), "tick_rate": float(tick_rate),
                                "rendered": int(rendered), "presentations": int(presented),
                                "dropped_catch_up": int(dropped), "coalesced_callbacks": int(coalesced),
                                "pacing_resets": int(resets), "max_delta_ms": int(max_delta)}
                if int(rendered) > int(ticks) or int(presented) > int(ticks):
                    errors.append(f"render/presentation counters exceed ticks: {stats_matches[-1]}")
                if int(max_delta) > 100:
                    errors.append(f"tick delta exceeded the 100 ms catch-up clamp: {max_delta}")
            driver = re.search(r"tick loop started \(pacing=.*?driver=([\w-]+)", text)
            if not driver:
                errors.append("missing pacing driver log")
            elif args.pace == "timer" and driver.group(1) != "timer":
                errors.append(f"timer pacing requested but driver={driver.group(1)}")
            elif args.pace == "display" and driver.group(1) != "display-link":
                errors.append(f"display-link pacing requested but driver={driver.group(1)}")
            if args.fps_limit is not None and int(args.fps_limit) > 0:
                target = int(args.fps_limit)
                if f"fps_limit={target}" not in text or f"target={target} FPS" not in text:
                    errors.append(f"fps_limit={target} was not configured for the session")
                if pacing_stats and pacing_stats["tick_rate"] > target * 1.1 + 1:
                    errors.append(f"tick rate {pacing_stats['tick_rate']}/s exceeded target {target}")
            if args.lifecycle:
                if "host lifecycle testLifecycle=on" not in text or "host lifecycle testLifecycle=off" not in text:
                    errors.append("scripted lifecycle transition was not handled")
                if pacing_stats and pacing_stats["pacing_resets"] < 2:
                    errors.append("lifecycle transitions did not reset the pacing clock")
            if args.frame_enhancement == "adaptive_sharpen" and "frame enhancement adaptive_sharpen amount=" not in text:
                errors.append("frame enhancement was requested but not applied")
            (folder / "result.json").write_text(json.dumps({
                "game": name, "duration_seconds": args.duration,
                "renderer": args.renderer, "presentation": args.presentation,
                "snapshots": args.snapshots, "exit_code": code,
                "fps_limit": args.fps_limit, "pace": args.pace,
                "frame_enhancement": args.frame_enhancement,
                "pacing_driver": driver.group(1) if driver else None,
                "pacing_stats": pacing_stats,
                "async_teardown": async_summary, "errors": errors,
                "passed": not errors,
            }, indent=2) + "\n")
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
