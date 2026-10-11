#!/usr/bin/env python3
"""Run a real-game benchmark with explicit submission and completion metrics.

The Godot probe measures its native-rendered wall-clock tick loop. Apple Host
is measured twice: uncapped submission (no per-frame GPU wait) and end-to-end
offscreen completion (a GPU completion wait on every fixed 1/60 tick). These
numbers are intentionally reported as separate metrics; submission throughput
is not presented as player-visible FPS.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path


FPS_RE = re.compile(r"step probe fps=([0-9.]+)")


def run(command: list[str], *, cwd: Path, log_path: Path, env: dict[str, str] | None = None) -> str:
    with log_path.open("w") as log:
        completed = subprocess.run(command, cwd=cwd, env=env, stdout=log,
                                   stderr=subprocess.STDOUT, text=True)
    text = log_path.read_text(errors="replace")
    if completed.returncode != 0:
        raise RuntimeError(f"command failed ({completed.returncode}): {' '.join(command)}")
    return text


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("game", type=Path)
    parser.add_argument("--duration", type=float, default=30.0,
                        help="Apple Host duration in seconds; minimum 30")
    parser.add_argument("--measure-frames", type=int, default=1800,
                        help="Godot fixed ticks measured after warmup")
    parser.add_argument("--output", type=Path,
                        default=Path("out/apple_host/evidence") /
                        f"real-game-{time.strftime('%Y%m%d-%H%M%S')}")
    parser.add_argument("--godot-binary", type=Path,
                        default=Path("out/godot/macos/debug/Aether.app/Contents/MacOS/Aether"))
    args = parser.parse_args()
    if not args.game.is_dir():
        parser.error("game must be an existing directory")
    if args.duration < 30:
        parser.error("duration must be at least 30 seconds")
    if args.measure_frames < 120:
        parser.error("measure-frames must be at least 120")

    root = Path(__file__).resolve().parent.parent
    output = args.output if args.output.is_absolute() else root / args.output
    output.mkdir(parents=True, exist_ok=False)
    game = args.game.expanduser().resolve()
    result: dict[str, object] = {
        "game": game.name,
        "surface": [1920, 1080],
        "fixed_tick_hz": 60,
        "duration_seconds": args.duration,
        "metrics": {},
        "interpretation": {
            "godot_wallclock_tick_s":
            "Godot native probe wall-clock tick loop; includes Godot viewport/TextureRect scheduling and Metal submission.",
            "apple_submit_tick_s":
            "Apple Host offscreen fixed-tick submission; excludes per-frame GPU completion and display scanout.",
            "apple_completion_tick_s":
            "Apple Host offscreen fixed-tick end-to-end completion; waits for every 1920x1080 GPU command.",
            "visible_fps":
            "Not inferred from uncapped metrics. A real display path remains bounded by the display refresh cadence."
        },
    }

    config = output / "godot-probe.json"
    config.write_text(json.dumps({
        "game_path": str(game),
        "backend": "Godot Native",
        "surface_size": [1920, 1080],
        "window_size": [1920, 1080],
        "coord_size": [1920, 1080],
        "startup_timeout_frames": 2400,
        "warmup_frames": 300,
        "measure_frames": args.measure_frames,
        "capture_startup": False,
        "runtime_debug": False,
        "actions": [],
    }, indent=2) + "\n")
    godot_env = dict(__import__("os").environ)
    godot_env.update({
        "AETHERKIRI_TEST_CONFIG": str(config),
        "AETHERKIRI_PROBE_USER_DIR": str(output / "godot-user"),
        "AETHERKIRI_PROBE_OUTPUT_DIR": str(output / "godot-output"),
        "AETHERKIRI_PROBE_FPS_LIMIT": "0",
    })
    godot_log = output / "godot.log"
    godot_text = run([str(args.godot_binary.resolve()),
                      "--script", "res://scripts/step_render_probe.gd"],
                     cwd=root / "apps/godot_app", log_path=godot_log, env=godot_env)
    godot_match = FPS_RE.search(godot_text)
    if not godot_match:
        raise RuntimeError(f"Godot probe did not emit step probe fps; see {godot_log}")
    result["metrics"]["godot_wallclock_tick_s"] = {"tick_per_second": float(godot_match.group(1))}

    for label, wait_gpu in (("apple_submit_tick_s", False), ("apple_completion_tick_s", True)):
        folder = output / label
        command = [sys.executable, str(root / "tools/apple_host_profile.py"), str(game),
                   "--duration", str(args.duration), "--offscreen", "--output", str(folder)]
        if wait_gpu:
            command.append("--wait-gpu")
        text = run(command, cwd=root, log_path=output / f"{label}.launcher.log")
        profile = json.loads((folder / "result.json").read_text())
        result["metrics"][label] = profile["runs"]
        if "startup state: SUCCEEDED" not in text and not all(
                "startup state: SUCCEEDED" in (folder / mode / "run.log").read_text(errors="replace")
                for mode in ("deferred", "direct")):
            raise RuntimeError(f"Apple Host startup failed; see {folder}")

    metrics = result["metrics"]
    submit_direct = metrics["apple_submit_tick_s"]["direct"]["ticks_per_second"]
    submit_deferred = metrics["apple_submit_tick_s"]["deferred"]["ticks_per_second"]
    completion_direct = metrics["apple_completion_tick_s"]["direct"]["ticks_per_second"]
    completion_deferred = metrics["apple_completion_tick_s"]["deferred"]["ticks_per_second"]
    godot = metrics["godot_wallclock_tick_s"]["tick_per_second"]
    result["ratios"] = {
        "apple_direct_vs_deferred_submit": submit_direct / submit_deferred,
        "apple_direct_vs_deferred_completion": completion_direct / completion_deferred,
        "godot_vs_apple_direct_completion": None,
        "godot_vs_apple_direct_submit": None,
    }
    result["comparison_notes"] = [
        "Godot wall-clock ticks and Apple completion ticks are retained as separate series because the Godot probe has no equivalent per-frame GPU fence.",
        "The Apple submit series is useful for ABI/scheduling overhead, but must not be called visible FPS.",
        "Use the completion series to discuss end-to-end GPU pressure; use a display-cadenced smoke for actual player-visible FPS.",
    ]
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    report = output / "REPORT.md"
    report.write_text(
        "# Real-game benchmark\n\n"
        f"Game: `{game.name}`; surface: `1920x1080`; fixed tick: `60 Hz`.\n\n"
        "| Series | deferred | direct |\n|---|---:|---:|\n"
        f"| Apple submit tick/s | {submit_deferred:.2f} | {submit_direct:.2f} |\n"
        f"| Apple completion tick/s | {completion_deferred:.2f} | {completion_direct:.2f} |\n\n"
        f"Godot native wall-clock tick/s: **{godot:.2f}**.\n\n"
        f"Direct/deferred ratio: submit **{submit_direct / submit_deferred:.2f}x**, "
        f"completion **{completion_direct / completion_deferred:.2f}x**.\n\n"
        "The Godot value and Apple completion value are not collapsed into a single speedup: Godot has no matching per-frame GPU fence in this probe. "
        "None of these uncapped values is a display-visible FPS claim.\n"
    )
    print(f"Evidence: {output}")
    print(f"Godot wall-clock tick/s: {godot:.2f}")
    print(f"Apple submit deferred/direct: {submit_deferred:.2f}/{submit_direct:.2f} tick/s")
    print(f"Apple completion deferred/direct: {completion_deferred:.2f}/{completion_direct:.2f} tick/s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
