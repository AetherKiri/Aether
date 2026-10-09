#!/usr/bin/env python3
"""Install and exercise an actual Ren'Py-enabled APK on a cloud Android device.

No fake adb, scripted provider, skip-execution switch, or host-PC fallback is
provided. Missing APK/adb/device/debug staging yields not_run and exit status 2;
missing gameplay evidence after installation yields failed and exit status 1.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import selectors
import shlex
import shutil
import struct
import subprocess
import tarfile
import tempfile
import time
import uuid
import zlib
from pathlib import Path


class Blocked(RuntimeError):
    pass


class Failed(RuntimeError):
    pass


def bounded_failure_command(command: list[str], deadline: float, *, byte_limit: int = 65536) -> tuple[dict, bytes]:
    """Capture only bounded stdout of an owned read-only diagnostic child."""
    started = time.monotonic()
    expires = min(deadline, started + 2)
    if expires <= started:
        return {"status": "not_available", "reason": "diagnostic_deadline"}, b""
    report, raw = {"status": "not_available"}, bytearray()
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError:
        return {**report, "reason": "command_unavailable"}, b""
    try:
        os.set_blocking(process.stdout.fileno(), False)
        with selectors.DefaultSelector() as reader:
            reader.register(process.stdout, selectors.EVENT_READ)
            read_deadline = expires - min(0.2, (expires - started) / 2)
            eof = False
            while time.monotonic() < read_deadline:
                if not eof:
                    events = reader.select(timeout=min(0.05, max(0, read_deadline - time.monotonic())))
                    if events:
                        chunk = os.read(process.stdout.fileno(), min(4096, byte_limit + 1 - len(raw)))
                        if not chunk:
                            eof = True
                            reader.unregister(process.stdout)
                        else:
                            raw.extend(chunk)
                            if len(raw) > byte_limit:
                                report["reason"] = "stdout_limit"
                                break
                elif process.poll() is None:
                    time.sleep(min(0.01, max(0, read_deadline - time.monotonic())))
                if eof and process.poll() is not None:
                    break
            if not eof and "reason" not in report:
                report["reason"] = "command_timeout"
        if process.poll() is None and not report.get("cleanup_permission_denied"):
            try:
                process.kill()
            except PermissionError:
                report["cleanup_permission_denied"] = True
            except ProcessLookupError:
                pass
        try:
            code = process.wait(timeout=max(0, expires - time.monotonic()))
            report["returncode"] = code
        except subprocess.TimeoutExpired:
            report["collector_not_reaped"] = True
        if not report.get("reason") and report.get("returncode") == 0 and time.monotonic() < deadline:
            report["status"] = "available"
        elif not report.get("reason"):
            report["reason"] = "command_failed_or_deadline"
    except OSError:
        report["reason"] = "command_io_error"
        if process.poll() is None and not report.get("cleanup_permission_denied"):
            try:
                process.kill()
            except PermissionError:
                report["cleanup_permission_denied"] = True
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=max(0, expires - time.monotonic()))
            except subprocess.TimeoutExpired:
                report["collector_not_reaped"] = True
    finally:
        process.stdout.close()
    report["elapsed_seconds"] = round(time.monotonic() - started, 3)
    report["bytes_captured"] = min(len(raw), byte_limit)
    # Incomplete/failed output is never used as PID or Activity state proof.
    return report, bytes(raw) if report["status"] == "available" else b""


def failure_activity_states(raw: bytes, component: str) -> list[dict]:
    """Select state/drawn booleans only within the exact current Activity record."""
    if len(component) > 256 or not re.fullmatch(r"[A-Za-z0-9_.$]+/[A-Za-z0-9_.$]+", component):
        return []
    states, current = [], None
    wanted = re.compile(r"(?<![A-Za-z0-9_.$/])" + re.escape(component) + r"(?![A-Za-z0-9_.$/])")
    # Android 15 ActivityRecord.dump emits state/visibility/drawn fields after
    # configuration and optional TaskDescription output, beyond 24 lines.
    # Keep the whole bounded record, ending at any subsequent ActivityRecord.
    prefix = raw[:65536]
    if len(raw) > len(prefix):
        prefix = prefix.rpartition(b"\n")[0]
    for line in prefix.decode(errors="replace").splitlines()[:1000]:
        if len(line) > 4096:
            if "ActivityRecord{" in line:
                current = None
            continue
        if "ActivityRecord{" in line:
            current = None
            if wanted.search(line) and len(states) < 4:
                current = {}
                states.append(current)
        if current is None:
            continue
        match = re.search(r"\bstate=(INITIALIZING|STARTED|RESUMED|PAUSING|PAUSED|STOPPING|STOPPED|DESTROYING|DESTROYED|RESTARTING_PROCESS)\b", line)
        if match:
            current["state"] = match[1]
        for name in ("mVisibleRequested", "mVisible", "allDrawn", "firstWindowDrawn"):
            match = re.search(r"\b" + name + r"=(true|false)\b", line)
            if match:
                current[name] = match[1] == "true"
    return [row for row in states if row]


def is_successful_os_return(row: object) -> bool:
    """Require a delivered Return in the observer's explicit Godot namespace."""
    return (isinstance(row, dict) and row.get("kind") == "os_key"
            and row.get("keycode_space") == "godot" and row.get("pressed") is True
            and row.get("code") in ((1 << 22) | 5, (1 << 22) | 6)
            and not isinstance(row.get("result"), bool) and row.get("result") == 0)


def png_pixels(path: Path, *, deadline: float | None = None) -> tuple[int, int, bytes, int]:
    """Decode real Android/Godot 8-bit RGB(A) evidence without extra packages."""
    if deadline is not None and time.monotonic() >= deadline:
        raise Failed("Passive capture deadline reached")
    raw = path.read_bytes()
    if deadline is not None and (len(raw) > 8 * 1024 * 1024 or time.monotonic() >= deadline):
        raise Failed("Passive PNG exceeds its byte or time budget")
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise Failed(f"Evidence is not a PNG: {path.name}")
    offset, compressed = 8, bytearray()
    width = height = channels = 0
    while offset + 12 <= len(raw):
        if deadline is not None and time.monotonic() >= deadline:
            raise Failed("Passive capture deadline reached")
        count = struct.unpack_from(">I", raw, offset)[0]
        kind = raw[offset + 4:offset + 8]
        data = raw[offset + 8:offset + 8 + count]
        if kind == b"IHDR":
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", data)
            if depth != 8 or color not in (2, 6) or compression or filtering or interlace:
                raise Failed(f"Unsupported real PNG format in {path.name}")
            channels = 4 if color == 6 else 3
        elif kind == b"IDAT":
            compressed.extend(data)
        elif kind == b"IEND":
            break
        offset += 12 + count
    if width <= 0 or height <= 0 or width * height > 30_000_000 or not channels:
        raise Failed(f"Invalid PNG dimensions: {path.name}")
    stride = width * channels
    if deadline is None:
        stream = zlib.decompress(compressed)
    else:
        # The passive diagnostic has a finite CPU/memory budget. Keep the
        # normal decoder unchanged; reject output beyond the legal PNG size.
        if height * (stride + 1) > 8 * 1024 * 1024:
            raise Failed("Passive PNG exceeds its decoded pixel budget")
        decoder = zlib.decompressobj()
        stream = decoder.decompress(compressed, height * (stride + 1) + 1)
        if not decoder.eof or decoder.unconsumed_tail or time.monotonic() >= deadline:
            raise Failed("Passive PNG decompression exceeds its size or time budget")
    if len(stream) != height * (stride + 1):
        raise Failed(f"Incomplete PNG pixels: {path.name}")
    pixels = bytearray(height * stride)
    previous = bytearray(stride)
    for y in range(height):
        if deadline is not None and time.monotonic() >= deadline:
            raise Failed("Passive capture deadline reached")
        start = y * (stride + 1)
        filter_type = stream[start]
        row = bytearray(stream[start + 1:start + 1 + stride])
        for x in range(stride):
            if deadline is not None and x % 4096 == 0 and time.monotonic() >= deadline:
                raise Failed("Passive capture deadline reached")
            left = row[x - channels] if x >= channels else 0
            up = previous[x]
            corner = previous[x - channels] if x >= channels else 0
            if filter_type == 1:
                value = left
            elif filter_type == 2:
                value = up
            elif filter_type == 3:
                value = (left + up) // 2
            elif filter_type == 4:
                p = left + up - corner
                distance = (abs(p - left), abs(p - up), abs(p - corner))
                value = (left, up, corner)[distance.index(min(distance))]
            elif filter_type == 0:
                value = 0
            else:
                raise Failed(f"Invalid PNG filter in {path.name}")
            row[x] = (row[x] + value) & 255
        pixels[y * stride:(y + 1) * stride] = row
        previous = row
    result = width, height, bytes(pixels), channels
    if deadline is not None and time.monotonic() >= deadline:
        raise Failed("Passive capture deadline reached")
    return result


def pixel(image: tuple[int, int, bytes, int], x: int, y: int) -> tuple[int, int, int]:
    width, height, data, channels = image
    if not 0 <= x < width or not 0 <= y < height:
        raise Failed("Native frame's presentation geometry lies outside the device screenshot")
    offset = (y * width + x) * channels
    return tuple(data[offset:offset + 3])


def image_stats(image: tuple[int, int, bytes, int]) -> dict:
    width, height, _, _ = image
    colors, luma = set(), []
    for y in range(0, height, max(1, height // 64)):
        for x in range(0, width, max(1, width // 64)):
            rgb = pixel(image, x, y)
            colors.add(rgb)
            luma.append(sum(rgb) / 3)
    stats = {"width": width, "height": height, "sampled_colors": len(colors),
             "luma_range": max(luma) - min(luma)}
    if stats["sampled_colors"] < 32 or stats["luma_range"] < 40:
        raise Failed("Real image is blank or insufficiently varied for the Ren'Py scene")
    return stats


def is_script_checkpoint(row: object, stage: str, run_id: str) -> bool:
    return (isinstance(row, dict) and row.get("run_id") == run_id
            and row.get("source") == "renpy-script" and row.get("stage") == stage)


def valid_rgb(rgb: object) -> bool:
    # Godot JSON round-trips integral channels as 40.0 rather than 40. Accept
    # that representation, while rejecting bools, fractions and invalid RGB.
    return (isinstance(rgb, list) and len(rgb) == 3
            and all(not isinstance(v, bool) and isinstance(v, (int, float))
                    and 0 <= v <= 255 and int(v) == v for v in rgb))


def checkpoint_landmarks(checkpoint: dict) -> dict:
    """Read geometry and marker identity from the executed game's checkpoint."""
    if checkpoint.get("source") != "renpy-script":
        raise Failed("Landmarks do not originate from an executed Ren'Py checkpoint")
    expected_name = {"start_ready": "START", "post_text_ready": "WAIT", "quit_ready": "RESUMED"}.get(checkpoint.get("stage"))
    details = checkpoint.get("details", {})
    if not isinstance(details, dict) or not expected_name or details.get("marker_name") != expected_name:
        raise Failed("Checkpoint lacks its executed scene's stage marker")
    canvas = details.get("logical_canvas", [])
    if (not isinstance(canvas, list) or len(canvas) != 2
            or any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v <= 0 for v in canvas)):
        raise Failed("Checkpoint lacks a valid logical game canvas")
    for name in ("button_bounds", "marker_bounds"):
        bounds = details.get(name, [])
        if (not isinstance(bounds, list) or len(bounds) != 4
                or any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) for v in bounds)
                or min(bounds[:2]) < 0 or min(bounds[2:]) <= 8
                or bounds[0] + bounds[2] > canvas[0] or bounds[1] + bounds[3] > canvas[1]):
            raise Failed(f"Checkpoint has invalid {name} within its logical canvas")
    rgb = details.get("marker_rgb", [])
    if not valid_rgb(rgb):
        raise Failed("Checkpoint lacks its actual marker's RGB color")
    button_rgbs = details.get("button_rgbs", [])
    if (not isinstance(button_rgbs, list) or not button_rgbs
            or any(not valid_rgb(rgb) for rgb in button_rgbs)):
        raise Failed("Checkpoint lacks its actual idle/hover button RGB colors")
    return details


def landmark_samples(canvas: list, bounds: list):
    # Exclude the outer four logical pixels where filtering/shadows can mix
    # game and background. Sample densely throughout each remaining landmark.
    x, y, width, height = bounds
    columns = min(48, max(9, int((width - 8) / 5)))
    rows = min(32, max(7, int((height - 8) / 5)))
    for iy in range(rows):
        for ix in range(columns):
            yield ((x + 4 + (ix + 0.5) * (width - 8) / columns) / canvas[0],
                   (y + 4 + (iy + 0.5) * (height - 8) / rows) / canvas[1])


def verify_landmark_pixels(provider: tuple, screen: tuple, frame: dict, checkpoint: dict) -> dict:
    details = checkpoint_landmarks(checkpoint)
    box, viewport = frame["drawn_box"], frame["viewport_size"]
    if (len(box) != 4 or len(viewport) != 2
            or any(not isinstance(v, (int, float)) or not math.isfinite(v) for v in box + viewport)
            or min(box[2:]) <= 0 or min(viewport) <= 0):
        raise Failed("Landmark comparison lacks finite on-device presentation geometry")
    metrics = {}
    for name in ("button", "marker"):
        matches = count = expected_color = 0
        expected_rgbs = details["button_rgbs"] if name == "button" else [details["marker_rgb"]]
        for u, v in landmark_samples(details["logical_canvas"], details[name + "_bounds"]):
            native = pixel(provider, int(u * provider[0]), int(v * provider[1]))
            sx = int((box[0] + u * box[2]) * screen[0] / viewport[0])
            sy = int((box[1] + v * box[3]) * screen[1] / viewport[1])
            # The original sample must be within the OS image. Nearby actual
            # pixels accommodate a subpixel linear-filter/antialiasing shift.
            pixel(screen, sx, sy)
            matches += any(max(abs(a - b) for a, b in zip(native, pixel(screen, nx, ny))) <= 24
                           for ny in range(max(0, sy - 1), min(screen[1], sy + 2))
                           for nx in range(max(0, sx - 1), min(screen[0], sx + 2)))
            expected_color += any(max(abs(a - b) for a, b in zip(native, rgb)) <= 24 for rgb in expected_rgbs)
            count += 1
        metrics[name] = {"logical_bounds": details[name + "_bounds"], "logical_inset": 4,
                         "matching_samples": matches, "samples": count, "fraction": matches / count,
                         "required_fraction": 0.90, "channel_tolerance": 24, "os_neighbor_radius": 1,
                         "native_required_color_fraction": 0.70}
        if name == "marker":
            metrics[name].update(name=details["marker_name"], expected_rgb=details["marker_rgb"],
                                 native_expected_color_fraction=expected_color / count)
        else:
            metrics[name].update(expected_rgbs=details["button_rgbs"],
                                 native_expected_color_fraction=expected_color / count)
    # Return metrics even when an ROI fails so the caller can preserve evidence
    # before rejecting. Solid button/marker fills leave room for actual labels.
    return metrics


def require_landmark_pixels(metrics: dict) -> None:
    for name in ("button", "marker"):
        if metrics[name]["fraction"] < 0.90:
            raise Failed(f"Actual OS screenshot does not present the native {name} ROI: {metrics[name]}")
    if metrics["marker"]["native_expected_color_fraction"] < 0.70:
        raise Failed("Native RGBA does not render the executed script's stage marker; a stale frame cannot pass")
    if metrics["button"]["native_expected_color_fraction"] < 0.70:
        raise Failed("Native RGBA lacks the executed script's visible idle/hover button; matching background cannot pass")


def verify_resumed_marker(before: tuple, before_checkpoint: dict, after: tuple, after_checkpoint: dict) -> dict:
    earlier = checkpoint_landmarks(before_checkpoint)
    later = checkpoint_landmarks(after_checkpoint)
    if earlier["marker_name"] != "WAIT" or later["marker_name"] != "RESUMED":
        raise Failed("Resume evidence must compare actual WAIT and RESUMED script-rendered markers")
    changed = count = 0
    previous_samples = landmark_samples(earlier["logical_canvas"], earlier["marker_bounds"])
    current_samples = landmark_samples(later["logical_canvas"], later["marker_bounds"])
    if earlier["logical_canvas"] != later["logical_canvas"] or earlier["marker_bounds"] != later["marker_bounds"]:
        raise Failed("The executed fixture's marker geometry changed unexpectedly during resume")
    for (u0, v0), (u1, v1) in zip(previous_samples, current_samples):
        previous = pixel(before, int(u0 * before[0]), int(v0 * before[1]))
        current = pixel(after, int(u1 * after[0]), int(v1 * after[1]))
        changed += max(abs(a - b) for a, b in zip(previous, current)) > 24
        count += 1
    return {"source": "actual-native-rgba-before-and-after-resumed-os-touch", "before": "WAIT", "after": "RESUMED",
            "changed_samples": changed, "samples": count, "fraction": changed / count,
            "required_fraction": 0.70, "channel_tolerance": 24}


def read_engine_log_file(path: Path) -> bytes:
    try:
        return path.read_bytes()
    except OSError as exc:
        raise Failed(f"Actual per-game engine log is missing or unreadable: {path}: {exc}") from exc


def require_engine_log(raw: bytes, game_root: str) -> dict:
    """Reject sidecar errors after void native shutdown; do not infer its status."""
    if not isinstance(raw, bytes) or not raw.strip():
        raise Failed("Actual per-game engine log is missing, unreadable or empty")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise Failed("Actual per-game engine log is not readable UTF-8") from exc
    path = game_root.rstrip("/") + "/aetherkiri-engine.log"
    # Both harnesses remove and recreate this private test root before launch.
    # The existing, flushed dispatcher attachment line independently ties the
    # retained file to that root, rather than accepting another game's log.
    attachment = "aetherkiri provider engine log attached: " + path
    if not any(line.rstrip().endswith(attachment) for line in text.splitlines()):
        raise Failed("Engine log lacks the existing dispatcher's attachment to this freshly staged game root")
    records, errors = 0, []
    diagnostics = ("terminal cleanup failed", "private egl context could not be made current",
                   "failed to restore the host egl context", "lifecycle called from a different thread than init")
    for number, line in enumerate(text.splitlines(), 1):
        record = re.search(r"\b(trace|debug|info|warning|error)\s+\[renpy-mobile\]\s*(.*)", line, re.IGNORECASE)
        if record is None:
            continue
        records += 1
        level, message = record.groups()
        if (level.lower() == "error" or any(detail in message.lower() for detail in diagnostics)
                or message.strip() == "cooperative_stop"):
            errors.append({"line": number, "record": line})
    if errors:
        raise Failed("Native Ren'Py cleanup/runtime errors were retained in aetherkiri-engine.log: "
                     + json.dumps(errors, ensure_ascii=False))
    return {"source": "actual-flushed-provider-game-log", "path": path, "bytes": len(raw),
            "renpy_mobile_records": records, "renpy_mobile_error_records": 0,
            "verification": "no-recorded-native-errors; void-shutdown-status-unavailable"}


class Acceptance:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output_dir.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.run_id = uuid.uuid4().hex
        self.device_prefix = [args.adb, "-s", args.serial]
        self.game_root = ""
        self.data_root = ""
        self.pid = ""
        self.installed = False
        self.last_command_returncode = None
        self.last_command_stderr = ""
        self.execution_deadline = 0.0
        self.passive_deadline = None
        self.waiting_marker = None
        self.summary = {"status": "not_run", "run_id": self.run_id,
                        "source": "actual-apk-adb-cloud-device", "serial": args.serial,
                        "package": args.package, "checks": [], "blocker": "",
                        "apk_installed": False, "process_started": False,
                        "actual_status": {stage: {"status": "not_run", "source": "actual-adb-command",
                                                 "package": args.package, "serial": args.serial}
                                          for stage in ("apk_install", "app_launch")}}

    def write_result(self) -> None:
        pending = self.output / "result.pending.json"
        pending.write_text(json.dumps(self.summary, indent=2) + "\n")
        pending.replace(self.output / "result.json")

    def milestone(self, stage: str, **evidence) -> None:
        report = self.summary["actual_status"][stage]
        report.update(status="passed", **evidence)
        self.summary["status"] = "running"
        self.write_result()
        # Publish only bounded command milestones, never raw device logs or
        # any claim that the Ren'Py runtime has rendered or accepted input.
        bounded = {**report, "package": report["package"][:256], "serial": report["serial"][:128]}
        if "activity" in bounded:
            bounded["activity"] = bounded["activity"][:512]
        print(json.dumps({"event": "renpy_device_milestone", "run_id": self.run_id,
                          "apk_installed": self.summary["apk_installed"],
                          "process_started": self.summary["process_started"],
                          "stage": stage, "evidence": bounded}), flush=True)

    def command(self, *parts: str, check: bool = True, timeout: int = 20) -> bytes:
        command = self.device_prefix + list(parts)
        self.last_command_returncode = None
        self.last_command_stderr = ""
        if self.passive_deadline is not None:
            png = parts[:3] == ("exec-out", "screencap", "-p") or (
                parts[:3] == ("exec-out", "run-as", self.args.package) and parts[-1].endswith(".png"))
            report, raw = bounded_failure_command(command, min(self.passive_deadline, time.monotonic() + timeout),
                                                  byte_limit=8 * 1024 * 1024 if png else 65536)
            self.last_command_returncode = report.get("returncode")
            with (self.output / "commands.jsonl").open("a") as log:
                log.write(json.dumps({"command": command, "returncode": self.last_command_returncode,
                                      "passive_diagnostic_only": True, "time": time.time()}) + "\n")
            if (report.get("reason") in ("command_timeout", "stdout_limit", "diagnostic_deadline")
                    or report.get("cleanup_permission_denied") or report.get("collector_not_reaped")
                    or time.monotonic() >= self.passive_deadline):
                raise Failed("Passive device read exceeded its bounded budget")
            if report.get("status") != "available":
                if not check and report.get("returncode") is not None:
                    return b""  # Unavailable observer/checkpoint data is not readiness proof.
                raise Failed("Passive device read is unavailable")
            return raw
        try:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise Failed(f"Device command did not complete: {parts[0]}: {exc}") from exc
        self.last_command_returncode = result.returncode
        self.last_command_stderr = result.stderr.decode(errors="replace")
        with (self.output / "commands.jsonl").open("a") as log:
            log.write(json.dumps({"command": command, "returncode": result.returncode,
                                  "stderr": result.stderr.decode(errors="replace"),
                                  "time": time.time()}) + "\n")
        if check and result.returncode:
            raise Failed(f"adb {' '.join(parts[:3])} failed: {result.stderr.decode(errors='replace').strip()}")
        return result.stdout

    def shell(self, *parts: str, check: bool = True, timeout: int = 20) -> bytes:
        # adb shell joins arguments into a remote shell string. Quote at that
        # boundary instead of relying on local subprocess's argument handling.
        return self.command("shell", shlex.join(parts), check=check, timeout=timeout)

    def private(self, relative: str, required: bool = False) -> bytes:
        return self.command("exec-out", "run-as", self.args.package, "cat", relative, check=required)

    def rows(self, relative: str) -> list[dict]:
        result = []
        for line in self.private(relative).decode(errors="replace").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict) and row.get("run_id") == self.run_id:
                result.append(row)
        return result

    def game_rows(self) -> list[dict]:
        return self.rows("files/renpy-device-demo/game/aether-device-checkpoints.jsonl")

    def observer_rows(self) -> list[dict]:
        return self.rows("files/renpy-device-evidence/observer.jsonl")

    def wait(self, description: str, condition, timeout: int | None = None):
        expires = time.monotonic() + (timeout or self.args.stage_timeout)
        if self.execution_deadline:
            expires = min(expires, self.execution_deadline)
        while time.monotonic() < expires:
            for row in self.observer_rows():
                if row.get("kind") == "failure":
                    raise Failed(f"Actual mobile observer failed: {row.get('message')}")
            result = condition()
            if self.passive_deadline is not None and time.monotonic() >= expires:
                raise Failed("Passive observation deadline reached")
            if result:
                return result
            time.sleep(min(0.4, max(0, expires - time.monotonic())) if self.passive_deadline is not None else 0.4)
        raise Failed(f"Timed out waiting for {description}; execution is not accepted")

    def wait_game(self, stage: str) -> dict:
        return self.wait(f"executed Ren'Py checkpoint {stage}", lambda: next(
            (row for row in self.game_rows() if is_script_checkpoint(row, stage, self.run_id)), None))

    def wait_observer(self, kind: str, **fields) -> dict:
        return self.wait(f"native observer {kind} {fields}", lambda: next(
            (row for row in self.observer_rows() if row.get("kind") == kind
             and all(row.get(key) == value for key, value in fields.items())), None))

    def screenshot(self, name: str) -> Path:
        path = self.output / f"screen-{name}.png"
        path.write_bytes(self.command("exec-out", "screencap", "-p"))
        png_pixels(path, deadline=self.passive_deadline)
        return path

    def foreground(self) -> None:
        window = self.shell("dumpsys", "window", "windows").decode(errors="replace")
        (self.output / "window-last.txt").write_text(window)
        focused = [line for line in window.splitlines() if "mCurrentFocus=" in line or "mFocusedApp=" in line]
        if not any(self.args.package in line for line in focused):
            raise Failed("The installed application is not foreground on the cloud device")

    def capture(self, stage: str, *, screenshot_name: str | None = None) -> tuple[dict, tuple]:
        row = self.wait_observer("provider_frame", stage=stage)
        if row.get("source") != "native-provider-rgba":
            raise Failed("Provider image lacks its native RGBA origin")
        native = row.get("provider_debug", {})
        if (native.get("runtime") != "renpy" or native.get("initialized") is not True
                or native.get("exited") is not False or int(row.get("frame_serial", 0)) <= 0):
            raise Failed("Frame lacks live initialized Ren'Py native state and a rendered frame serial")
        relative = "files/renpy-device-evidence/provider-" + stage + ".png"
        provider_path = self.output / ("provider-" + stage + ".png")
        provider_path.write_bytes(self.private(relative, required=True))
        provider = png_pixels(provider_path, deadline=self.passive_deadline)
        self.foreground()
        screen_path = self.screenshot(screenshot_name or stage)
        screen = png_pixels(screen_path, deadline=self.passive_deadline)
        stats = {"provider": image_stats(provider), "os_screenshot": image_stats(screen)}
        box, viewport = row["drawn_box"], row["viewport_size"]
        if min(viewport) <= 0 or min(box[2:]) <= 0:
            raise Failed("Native frame lacks valid on-device presentation geometry")
        matches, count = 0, 0
        # Compare actual game pixels with the OS image, including background
        # regions throughout the scene. A colorful desktop cannot pass this.
        for iy in range(1, 8):
            for ix in range(1, 12):
                u, v = ix / 12, iy / 8
                expected = pixel(provider, int(u * provider[0]), int(v * provider[1]))
                sx = int((box[0] + u * box[2]) * screen[0] / viewport[0])
                sy = int((box[1] + v * box[3]) * screen[1] / viewport[1])
                actual = pixel(screen, sx, sy)
                matches += max(abs(a - b) for a, b in zip(expected, actual)) <= 24
                count += 1
        stats["native_to_os_match"] = {"matching_samples": matches, "samples": count,
                                        "fraction": matches / count, "channel_tolerance": 24}
        game_stage = "post_text_ready" if stage == "resumed_ready" else stage
        checkpoint = self.wait_game(game_stage)
        observed = row.get("game_checkpoint", {})
        if (not is_script_checkpoint(observed, game_stage, self.run_id)
                or observed.get("details") != checkpoint.get("details")):
            raise Failed("Provider capture's landmarks do not match the independently read Ren'Py checkpoint")
        stats["landmarks"] = verify_landmark_pixels(provider, screen, row, checkpoint)
        if stage == "quit_ready":
            if self.waiting_marker is None:
                raise Failed("Missing independently captured native WAIT marker before OS pause")
            stats["resumed_marker_change"] = verify_resumed_marker(*self.waiting_marker, provider, checkpoint)
        (self.output / f"pixels-{screenshot_name or stage}.json").write_text(json.dumps(stats, indent=2) + "\n")
        if matches / count < 0.70:
            raise Failed(f"OS screenshot does not show the native Ren'Py frame at {stage}: {matches}/{count} samples")
        require_landmark_pixels(stats["landmarks"])
        if stage == "quit_ready" and stats["resumed_marker_change"]["fraction"] < 0.70:
            raise Failed("Native marker did not change after actual resumed OS touch; cached WAIT pixels cannot pass")
        if stage == "post_text_ready":
            self.waiting_marker = provider, checkpoint
        if self.passive_deadline is not None and time.monotonic() >= self.passive_deadline:
            raise Failed("Passive capture deadline reached")
        self.summary["checks"].append({"stage": screenshot_name or stage, "native_provider_pixels_and_os_screen": stats})
        return row, screen

    def tap_button(self, frame: dict, screen: tuple) -> None:
        box, viewport = frame["drawn_box"], frame["viewport_size"]
        details = checkpoint_landmarks(frame["game_checkpoint"])
        bx, by, bw, bh = details["button_bounds"]
        u = (bx + bw / 2) / details["logical_canvas"][0]
        v = (by + bh / 2) / details["logical_canvas"][1]
        x = round((box[0] + u * box[2]) * screen[0] / viewport[0])
        y = round((box[1] + v * box[3]) * screen[1] / viewport[1])
        self.shell("input", "tap", str(x), str(y))

    def run(self) -> None:
        if not self.args.cloud_device:
            raise Blocked("--cloud-device is required: this task authorizes only cloud execution/devices")
        missing = []
        if not self.args.apk.is_file():
            missing.append(f"Installable Ren'Py-enabled debug APK is missing: {self.args.apk}")
        if not shutil.which(self.args.adb):
            missing.append("adb is unavailable in the cloud task; provide Android platform-tools and a cloud device/emulator")
        if missing:
            raise Blocked("; ".join(missing))
        state = self.command("get-state", check=False).decode().strip()
        if state != "device":
            raise Blocked(f"Cloud Android device {self.args.serial} is unavailable or unauthorized (state={state!r})")
        self.summary["apk_sha256"] = hashlib.sha256(self.args.apk.read_bytes()).hexdigest()
        self.summary["device_fingerprint"] = self.shell("getprop", "ro.build.fingerprint").decode().strip()
        self.summary["device_abis"] = self.shell("getprop", "ro.product.cpu.abilist").decode().strip()
        install_status = self.summary["actual_status"]["apk_install"]
        install_status["status"] = "failed"
        try:
            install = self.command("install", "-r", str(self.args.apk.resolve()), timeout=180).decode(errors="replace")
        finally:
            install_status["returncode"] = self.last_command_returncode
        (self.output / "install.txt").write_text(install)
        lines = [line.strip() for line in install.splitlines() if line.strip()]
        if (not lines or lines[-1] != "Success" or lines.count("Success") != 1
                or any(line.startswith("Failure") for line in lines)):
            raise Failed(f"Actual APK installation failed: {install.strip()}")
        self.installed = True
        self.summary["apk_installed"] = True
        self.milestone("apk_install", returncode=0, stdout_marker="Success")
        root = self.command("exec-out", "run-as", self.args.package, "pwd", check=False).decode().strip()
        if not root.startswith("/data/") or "\n" in root or " " in root:
            raise Blocked("Installed APK does not permit run-as debug staging; use a debuggable APK for this cloud harness")
        self.data_root = root
        self.game_root = root + "/files/renpy-device-demo"
        self.shell("am", "force-stop", self.args.package)
        self.stage()
        resolved = self.shell("cmd", "package", "resolve-activity", "--brief", self.args.package).decode().splitlines()
        component = next((line.strip() for line in reversed(resolved) if "/" in line and " " not in line), "")
        if not component or not component.startswith(self.args.package + "/"):
            raise Failed("Cannot resolve the installed APK's real launcher activity")
        self.summary["activity"] = component
        self.execution_deadline = time.monotonic() + self.args.overall_timeout
        launch_status = self.summary["actual_status"]["app_launch"]
        launch_status.update(status="failed", activity=component)
        try:
            launch = self.shell("am", "start", "-W", "-n", component, timeout=60).decode(errors="replace")
        finally:
            launch_status["returncode"] = self.last_command_returncode
        (self.output / "launch.txt").write_text(launch)
        if (not re.search(r"(?im)^\s*Status:\s*ok\s*$", launch)
                or re.search(r"(?im)^\s*(?:Error\b|Exception\b|Failure\b)", launch + "\n" + self.last_command_stderr)):
            statuses = re.findall(r"(?im)^\s*Status:\s*(\S+)\s*$", launch)
            if (self.last_command_returncode == 0 and statuses == ["timeout"]
                    and not re.search(r"(?im)^\s*(?:Error\b|Exception\b|Failure\b)", launch + "\n" + self.last_command_stderr)):
                self.observe_timed_out_start(component)
            raise Failed("Actual am start did not report Status: ok without Android errors; inspect launch.txt and commands.jsonl")
        self.pid = self.wait("installed app process", self.observed_pid)
        pids = self.pid.split()
        self.summary["process_started"] = True
        self.milestone("app_launch", returncode=0, activity=component,
                       stdout_marker="Status: ok", pids=pids[:8], pid_count=len(pids))
        self.wait_game("start_ready")
        frame, screen = self.capture("start_ready")
        self.tap_button(frame, screen)
        self.wait_game("touch_received")
        self.wait_game("text_ready")
        keyboard = self.wait_observer("soft_keyboard", active=True)
        if keyboard.get("source") != "native-text-input-state" or not keyboard.get("feature_available"):
            raise Failed("A real native text request and OS virtual keyboard are required")
        keyboard_visible = self.wait_observer("soft_keyboard_visibility", visible=True)
        if keyboard_visible.get("source") != "os-virtual-keyboard-height" or keyboard_visible.get("height", 0) <= 0:
            raise Failed("Android did not report a real visible virtual keyboard")
        ime = self.wait("visible Android system input method", lambda: self.visible_ime())
        (self.output / "input-method.txt").write_text(ime)
        self.screenshot("text-ready-with-os-keyboard")
        typed = "CloudRenPy" + self.run_id[:8]
        self.shell("input", "text", typed)
        self.shell("input", "keyevent", "66")
        text = self.wait_game("text_received")
        if text.get("details", {}).get("text") != typed:
            raise Failed(f"Real Ren'Py text differs from OS input: {text.get('details')}")
        self.wait_game("post_text_ready")
        self.wait_observer("soft_keyboard", active=False)
        self.wait_observer("soft_keyboard_visibility", visible=False)
        self.wait("hidden Android system input method", lambda: not self.visible_ime())
        frame, screen = self.capture("post_text_ready")
        self.shell("input", "keyevent", "3")  # Android Home: real lifecycle pause.
        pause = self.wait_observer("lifecycle", phase="paused")
        if pause.get("result") != 0 or pause.get("provider_debug", {}).get("paused") is not True:
            raise Failed("OS background did not produce an observed native pause")
        self.screenshot("background-home")
        time.sleep(2)
        self.shell("am", "start", "-W", "-n", component, timeout=60)
        resume = self.wait_observer("lifecycle", phase="resumed")
        if resume.get("result") != 0 or resume.get("provider_debug", {}).get("paused") is not False:
            raise Failed("OS foreground did not produce an observed native resume")
        if any(row.get("stage") == "resumed_touch_received" for row in self.game_rows()):
            raise Failed("Ren'Py advanced past its waiting interaction without resumed OS touch")
        frame, screen = self.capture("resumed_ready", screenshot_name="resumed")
        if int(frame.get("frame_serial", 0)) <= int(pause.get("provider_debug", {}).get("frame_serial", 0)):
            raise Failed("OS resume did not produce a new native frame; cached pre-pause pixels cannot pass")
        self.tap_button(frame, screen)
        self.wait_game("resumed_touch_received")
        self.wait_game("quit_ready")
        frame, screen = self.capture("quit_ready")
        self.tap_button(frame, screen)
        self.wait_game("quit_requested")
        exit_row = self.wait_observer("normal_exit")
        if exit_row.get("provider_debug", {}).get("exited") is not True or not exit_row.get("engine_destroyed"):
            raise Failed("Explicit Ren'Py quit did not exit native gameplay and destroy the real engine")
        self.wait("normal app activity exit", self.activity_exited, timeout=20)
        self.summary["host_exit"] = {
            "activity_removed": True,
            "remaining_process_pids": self.shell("pidof", self.args.package, check=False).decode().strip()}
        self.screenshot("normal-exit-os")
        events = self.observer_rows()
        if not any(row.get("kind") == "os_touch" and row.get("action") == 1 and row.get("result") == 0 for row in events):
            raise Failed("No real OS touch-down reached the provider")
        if not any(row.get("kind") == "os_touch" and row.get("action") == 3 and row.get("result") == 0 for row in events):
            raise Failed("No real OS touch-up reached the provider")
        if not any(is_successful_os_return(row) for row in events):
            raise Failed("No real OS Enter key reached the provider")
        self.summary["checks"].extend([
            {"real_os_touch_and_keyboard_text": typed},
            {"real_os_pause_resume": {"pause": pause, "resume": resume}},
            {"explicit_renpy_quit_and_engine_destroy": exit_row}])
        raw = self.private("files/renpy-device-demo/aetherkiri-engine.log", required=True)
        (self.output / "aetherkiri-engine.log").write_bytes(raw)
        self.summary["checks"].append({"native_cleanup_error_log": require_engine_log(raw, self.game_root)})
        self.summary["status"] = "passed"

    def observe_timed_out_start(self, component: str) -> None:
        """One finite read-only observation, never a launch/gameplay retry."""
        started = time.monotonic()
        deadline = min(started + 30, self.execution_deadline)
        report = {"source": "actual-adb-passive-startup-observation", "diagnostic_only": True,
                  "run_id": self.run_id, "package": self.args.package, "serial": self.args.serial,
                  "apk_sha256": self.summary.get("apk_sha256"), "activity": component,
                  "status": "diagnostic_notavailable", "window_seconds": max(0, deadline - started),
                  "start_ready": False, "native_rgba_and_os_pixels": False}
        previous_deadline, previous_passive = self.execution_deadline, self.passive_deadline
        previous_checks = self.summary["checks"]
        install = self.summary["actual_status"]["apk_install"]
        try:
            if (not self.installed or self.summary.get("apk_installed") is not True
                    or install.get("status") != "passed" or install.get("source") != "actual-adb-command"
                    or install.get("package") != self.args.package or install.get("serial") != self.args.serial
                    or type(install.get("returncode")) is not int or install["returncode"] != 0
                    or install.get("stdout_marker") != "Success" or deadline <= started
                    or len(component) > 256 or not re.fullmatch(r"[A-Za-z0-9_.$]+/[A-Za-z0-9_.$]+", component)
                    or not component.startswith(self.args.package + "/")):
                return
            self.execution_deadline = self.passive_deadline = deadline
            self.summary["checks"] = []
            pids = self.observed_pid().split()
            if not pids or len(pids) > 8 or len(set(pids)) != len(pids):
                return
            states = failure_activity_states(self.shell("dumpsys", "activity", "activities"), component)
            if not any(row.get("state") == "RESUMED" for row in states):
                return
            report.update(diagnostic_pids=pids, activity_states=states)
            self.wait_game("start_ready")
            report["start_ready"] = True
            if set(self.observed_pid().split()) != set(pids):
                return
            frame, _ = self.capture("start_ready", screenshot_name="passive-start-ready")
            if set(self.observed_pid().split()) != set(pids) or time.monotonic() >= deadline:
                return
            report.update(status="diagnostic_available", native_rgba_and_os_pixels=True,
                          frame_serial=frame["frame_serial"], pixels=self.summary["checks"])
        except Exception:
            # Optional diagnostics must never replace the original launch
            # failure, including malformed observer data in shared capture.
            report["observation_unavailable"] = True
        finally:
            self.summary["checks"] = previous_checks
            self.execution_deadline, self.passive_deadline = previous_deadline, previous_passive
            report.update(elapsed_seconds=round(time.monotonic() - started, 3),
                          deadline_reached=time.monotonic() >= deadline)
            if report["deadline_reached"]:
                report.update(status="diagnostic_notavailable", native_rgba_and_os_pixels=False)
            self.summary["passive_startup_observation"] = report

    def observed_pid(self) -> str:
        raw = self.shell("pidof", self.args.package, check=False).decode().strip()
        pids = raw.split()
        return raw if (self.last_command_returncode == 0 and pids
                       and all(re.fullmatch(r"[1-9][0-9]{0,9}", pid)
                                   and int(pid) <= 2147483647 for pid in pids)) else ""

    def visible_ime(self) -> str:
        text = self.shell("dumpsys", "input_method").decode(errors="replace")
        return text if re.search(r"(?:mInputShown|isInputViewShown|inputShown|mIsInputViewShown)=true", text) else ""

    def activity_exited(self) -> bool:
        # Android may cache an empty app process after the Activity finishes.
        # Require the actual ActivityRecord to be removed, independently of
        # native gameplay exit/engine teardown, and retain both kinds of evidence.
        text = self.shell("dumpsys", "activity", "activities").decode(errors="replace")
        (self.output / "activities-last.txt").write_text(text)
        return not re.search(r"ActivityRecord\{[^}\n]*\b" + re.escape(self.args.package) + r"/", text)

    def stage(self) -> None:
        fixture = Path(__file__).resolve().parents[1] / "demos/aetherkiri-renpy/game"
        request = {"run_id": self.run_id}
        config = {"probe_script": "res://scripts/renpy_mobile_acceptance.gd", "run_id": self.run_id,
                  "game_path": self.game_root, "timeout_seconds": self.args.overall_timeout}
        # Staging is confined to two test directories plus the existing
        # one-shot debug request. No app data, saves, or external paths are reset.
        self.shell("run-as", self.args.package, "mkdir", "-p", "files")
        self.shell("run-as", self.args.package, "rm", "-rf", "files/renpy-device-demo", "files/renpy-device-evidence")
        with tempfile.TemporaryDirectory(prefix="renpy-cloud-device-") as temporary:
            staging = Path(temporary)
            project = staging / "renpy-device-demo/game"
            project.mkdir(parents=True)
            for source in fixture.iterdir():
                if source.is_file() and source.suffix in (".rpy", ".svg"):
                    shutil.copyfile(source, project / source.name)
            (project / "aether-device-request.json").write_text(json.dumps(request))
            (staging / "aetherkiri-probe-request.json").write_text(json.dumps(config))
            archive = staging / "project.tar"
            with tarfile.open(archive, "w") as tar:
                tar.add(staging / "renpy-device-demo", arcname="renpy-device-demo")
                tar.add(staging / "aetherkiri-probe-request.json", arcname="aetherkiri-probe-request.json")
            remote = "/data/local/tmp/aether-renpy-device-" + self.run_id + ".tar"
            self.command("push", str(archive), remote)
            try:
                self.shell("run-as", self.args.package, "tar", "-xf", remote, "-C", "files")
            finally:
                self.shell("rm", "-f", remote, check=False)

    def collect(self) -> None:
        if not self.installed:
            return
        if self.summary.get("status") != "failed":
            self.collect_complete_evidence()
            return
        started = time.monotonic()
        deadline = started + 10
        snapshot = {"source": "actual-adb-failure-diagnostic", "diagnostic_only": True,
                    "run_id": self.run_id, "package": self.args.package, "serial": self.args.serial,
                    "apk_sha256": self.summary.get("apk_sha256"), "pid_sample": {"status": "not_available"}}
        def capture(*parts, byte_limit=65536):
            return bounded_failure_command(self.device_prefix + list(parts), deadline, byte_limit=byte_limit)
        diagnostic_pid = ""
        if self.summary.get("status") == "failed":
            report, raw = capture("shell", shlex.join(("pidof", self.args.package)), byte_limit=2048)
            pids = raw.decode(errors="replace").split()
            if (report["status"] == "available" and pids
                    and all(re.fullmatch(r"[1-9][0-9]{0,9}", pid) and int(pid) <= 2147483647 for pid in pids)
                    and len(set(pids)) == len(pids)):
                report.update(pids=pids[:8], pid_count=len(pids))
                diagnostic_pid = pids[0]
            elif report["status"] == "available":
                report.update(status="not_available", reason="no_valid_current_pid")
            snapshot["pid_sample"] = report
            if diagnostic_pid:
                report, raw = capture("logcat", "-d", "--pid", diagnostic_pid, "-v", "threadtime", "-t", "100")
                snapshot["process_logcat"] = report
                if raw:
                    (self.output / "android-process-logcat.txt").write_bytes(b"\n".join(raw.splitlines()[:100]) + b"\n")
            component = self.summary.get("activity", "")
            if (len(component) <= 256 and re.fullmatch(r"[A-Za-z0-9_.$]+/[A-Za-z0-9_.$]+", component)
                    and component.startswith(self.args.package + "/")):
                report, raw = capture("shell", shlex.join(("dumpsys", "activity", "activities")))
                report["exact_component"] = component
                report["states"] = failure_activity_states(raw, component) if raw else []
                snapshot["activity_sample"] = report
        report, data = capture("logcat", "-d", "-v", "threadtime", "-t", "100")
        snapshot["system_logcat"] = report
        if data:
            (self.output / "android-system-logcat.txt").write_bytes(b"\n".join(data.splitlines()[:100]) + b"\n")
        # These existing evidence reads share the same absolute budget. They
        # do not retry a denied/failed read and cannot replace the primary error.
        for relative, local in [
            ("files/renpy-device-demo/aetherkiri-engine.log", "aetherkiri-engine.log"),
            ("files/renpy-device-evidence/observer.jsonl", "observer.jsonl"),
            ("files/renpy-device-demo/game/aether-device-checkpoints.jsonl", "renpy-script-checkpoints.jsonl"),
            ("files/renpy-device-demo/log.txt", "renpy-log.txt"),
            ("files/renpy-device-demo/traceback.txt", "renpy-traceback.txt")]:
            _, data = capture("exec-out", "run-as", self.args.package, "cat", relative)
            if data:
                (self.output / local).write_bytes(b"\n".join(data.splitlines()[:200]) + b"\n")
        if self.pid and not diagnostic_pid:
            _, data = capture("logcat", "-d", "--pid", self.pid.split()[0], "-v", "threadtime", "-t", "100")
            if data:
                (self.output / "android-process-logcat.txt").write_bytes(b"\n".join(data.splitlines()[:100]) + b"\n")
        if self.summary.get("status") == "failed":
            snapshot.update(elapsed_seconds=round(time.monotonic() - started, 3),
                            deadline_reached=time.monotonic() >= deadline)
            self.summary["failure_diagnostics"] = snapshot

    def collect_complete_evidence(self) -> None:
        """Preserve the original successful-run evidence without new truncation."""
        for relative, local in [
            ("files/renpy-device-demo/aetherkiri-engine.log", "aetherkiri-engine.log"),
            ("files/renpy-device-evidence/observer.jsonl", "observer.jsonl"),
            ("files/renpy-device-demo/game/aether-device-checkpoints.jsonl", "renpy-script-checkpoints.jsonl"),
            ("files/renpy-device-demo/log.txt", "renpy-log.txt"),
            ("files/renpy-device-demo/traceback.txt", "renpy-traceback.txt")]:
            try:
                data = self.private(relative)
                if data:
                    (self.output / local).write_bytes(data)
            except Failed:
                pass
        if self.pid:
            try:
                (self.output / "android-process-logcat.txt").write_bytes(
                    self.command("logcat", "-d", "--pid", self.pid.split()[0], "-v", "threadtime", check=False))
            except Failed:
                pass
        try:
            (self.output / "android-system-logcat.txt").write_bytes(
                self.command("logcat", "-d", "-v", "threadtime", "-t", "2000", check=False))
        except Failed:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--serial", required=True, help="Explicit cloud device/emulator adb serial")
    parser.add_argument("--cloud-device", action="store_true", help="Confirm execution and selected device are cloud-hosted")
    parser.add_argument("--package", default="org.github.krkr2.aetherkiri")
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--stage-timeout", type=int, default=60)
    parser.add_argument("--overall-timeout", type=int, default=600,
                        help="Bound actual app execution to this many seconds (60..1200)")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.]+", args.package) or not 5 <= args.stage_timeout <= 180:
        parser.error("Invalid package or stage timeout (5..180 seconds)")
    if not 60 <= args.overall_timeout <= 1200:
        parser.error("Invalid overall timeout (60..1200 seconds)")
    acceptance = Acceptance(args)
    code = 0
    try:
        acceptance.run()
    except Blocked as exc:
        acceptance.summary.update(status="not_run", blocker=str(exc))
        code = 2
    except (Failed, KeyError, OSError, ValueError, struct.error, zlib.error) as exc:
        acceptance.summary.update(status="failed", blocker=str(exc))
        code = 1
    finally:
        try:
            acceptance.collect()
        except (Failed, OSError, ValueError):
            # Diagnostics never mask the original execution classification.
            acceptance.summary["failure_diagnostic_error"] = "not_available"
        acceptance.write_result()
    print(json.dumps(acceptance.summary, indent=2))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
