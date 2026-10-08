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
import re
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


def png_pixels(path: Path) -> tuple[int, int, bytes, int]:
    """Decode real Android/Godot 8-bit RGB(A) evidence without extra packages."""
    raw = path.read_bytes()
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        raise Failed(f"Evidence is not a PNG: {path.name}")
    offset, compressed = 8, bytearray()
    width = height = channels = 0
    while offset + 12 <= len(raw):
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
    stream = zlib.decompress(compressed)
    stride = width * channels
    if len(stream) != height * (stride + 1):
        raise Failed(f"Incomplete PNG pixels: {path.name}")
    pixels = bytearray(height * stride)
    previous = bytearray(stride)
    for y in range(height):
        start = y * (stride + 1)
        filter_type = stream[start]
        row = bytearray(stream[start + 1:start + 1 + stride])
        for x in range(stride):
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
    return width, height, bytes(pixels), channels


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
        self.execution_deadline = 0.0
        self.summary = {"status": "not_run", "run_id": self.run_id,
                        "source": "actual-apk-adb-cloud-device", "serial": args.serial,
                        "package": args.package, "checks": [], "blocker": ""}

    def command(self, *parts: str, check: bool = True, timeout: int = 20) -> bytes:
        command = self.device_prefix + list(parts)
        try:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise Failed(f"Device command did not complete: {parts[0]}: {exc}") from exc
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
            if result:
                return result
            time.sleep(0.4)
        raise Failed(f"Timed out waiting for {description}; execution is not accepted")

    def wait_game(self, stage: str) -> dict:
        return self.wait(f"executed Ren'Py checkpoint {stage}", lambda: next(
            (row for row in self.game_rows() if row.get("stage") == stage and row.get("source") == "renpy-script"), None))

    def wait_observer(self, kind: str, **fields) -> dict:
        return self.wait(f"native observer {kind} {fields}", lambda: next(
            (row for row in self.observer_rows() if row.get("kind") == kind
             and all(row.get(key) == value for key, value in fields.items())), None))

    def screenshot(self, name: str) -> Path:
        path = self.output / f"screen-{name}.png"
        path.write_bytes(self.command("exec-out", "screencap", "-p"))
        png_pixels(path)
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
        provider = png_pixels(provider_path)
        self.foreground()
        screen_path = self.screenshot(screenshot_name or stage)
        screen = png_pixels(screen_path)
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
        (self.output / f"pixels-{screenshot_name or stage}.json").write_text(json.dumps(stats, indent=2) + "\n")
        if matches / count < 0.70:
            raise Failed(f"OS screenshot does not show the native Ren'Py frame at {stage}: {matches}/{count} samples")
        self.summary["checks"].append({"stage": screenshot_name or stage, "native_provider_pixels_and_os_screen": stats})
        return row, screen

    def tap_button(self, frame: dict, screen: tuple) -> None:
        box, viewport = frame["drawn_box"], frame["viewport_size"]
        # The real fixture's button center is (480, 270) in its logical
        # 960x540 canvas. Native framebuffer pixels may use another physical
        # resolution, so address the displayed center through normalized UV.
        x = round((box[0] + 0.5 * box[2]) * screen[0] / viewport[0])
        y = round((box[1] + 0.5 * box[3]) * screen[1] / viewport[1])
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
        install = self.command("install", "-r", str(self.args.apk.resolve()), timeout=180).decode(errors="replace")
        (self.output / "install.txt").write_text(install)
        if "Success" not in install:
            raise Failed(f"Actual APK installation failed: {install.strip()}")
        self.installed = True
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
        self.shell("am", "start", "-W", "-n", component, timeout=60)
        self.pid = self.wait("installed app process", lambda: self.shell("pidof", self.args.package, check=False).decode().strip())
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
        if not any(row.get("kind") == "os_key" and row.get("pressed") and row.get("code") == 13 for row in events):
            raise Failed("No real OS Enter key reached the provider")
        self.summary["checks"].extend([
            {"real_os_touch_and_keyboard_text": typed},
            {"real_os_pause_resume": {"pause": pause, "resume": resume}},
            {"explicit_renpy_quit_and_engine_destroy": exit_row}])
        self.summary["status"] = "passed"

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
        for relative, local in [
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
            # Startup/linker crashes may occur before pidof can observe a PID.
            # Preserve actual logs from this disposable cloud image as well.
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
        acceptance.collect()
        (acceptance.output / "result.json").write_text(json.dumps(acceptance.summary, indent=2) + "\n")
    print(json.dumps(acceptance.summary, indent=2))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
