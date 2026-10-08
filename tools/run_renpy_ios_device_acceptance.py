#!/usr/bin/env python3
"""Install a real Ren'Py Godot app and exercise gameplay on a cloud iOS Simulator.

XCUITest supplies real touches, keyboard text, Home and foreground transitions.
Passing requires native frames visible in OS screenshots, real Ren'Py script
checkpoints, native pause/resume and normal game exit to the real library. Missing Apple
tools/app/runtime reports not_run (2); incomplete execution reports failed (1).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import plistlib
import shutil
import subprocess
import time
import uuid
from pathlib import Path

from run_renpy_android_device_acceptance import (
    Blocked, Failed, checkpoint_landmarks, image_stats, is_script_checkpoint, pixel, png_pixels,
    read_engine_log_file, require_engine_log, require_landmark_pixels, verify_landmark_pixels, verify_resumed_marker,
)


class Acceptance:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output_dir.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.repo = Path(__file__).resolve().parents[1]
        self.run_id = uuid.uuid4().hex
        self.udid = args.udid or ""
        self.created = self.installed = False
        self.bundle_id = ""
        self.documents: Path | None = None
        self.ui_root: Path | None = None
        self.sequence = 0
        self.process: subprocess.Popen | None = None
        self.process_log = None
        self.deadline = 0.0
        self.waiting_marker = None
        self.keyboard_preference: str | None = None
        self.preference_changed = False
        self.summary = {"status": "not_run", "run_id": self.run_id,
                        "source": "actual-godot-app-simctl-xcuitest-cloud-simulator",
                        "checks": [], "blocker": ""}

    def command(self, *parts: str, check: bool = True, timeout: int = 60) -> bytes:
        try:
            result = subprocess.run(parts, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise Failed(f"Cloud command did not complete: {parts[0]}: {exc}") from exc
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"command": parts, "returncode": result.returncode,
                                     "stderr": result.stderr.decode(errors="replace"), "time": time.time()}) + "\n")
        if parts[0] == "xcodebuild" and "build-for-testing" in parts:
            (self.output / "xcuitest-build.log").write_bytes(result.stdout + result.stderr)
        if check and result.returncode:
            raise Failed(f"{' '.join(parts[:4])} failed: {result.stderr.decode(errors='replace').strip()}")
        return result.stdout

    def simctl(self, *parts: str, **kwargs) -> bytes:
        return self.command("xcrun", "simctl", *parts, **kwargs)

    def rows(self, relative: str) -> list[dict]:
        if self.documents is None:
            return []
        path = self.documents / relative
        if not path.is_file():
            return []
        rows = []
        for line in path.read_text(errors="replace").splitlines():
            try:
                value = json.loads(line)
                if isinstance(value, dict) and value.get("run_id") == self.run_id:
                    rows.append(value)
            except ValueError:
                pass
        return rows

    def observer_rows(self) -> list[dict]:
        return self.rows("renpy-device-evidence/observer.jsonl")

    def game_rows(self) -> list[dict]:
        return self.rows("renpy-device-demo/game/aether-device-checkpoints.jsonl")

    def wait(self, description: str, condition, timeout: int | None = None):
        expires = time.monotonic() + (timeout or self.args.stage_timeout)
        if self.deadline:
            expires = min(expires, self.deadline)
        while time.monotonic() < expires:
            for row in self.observer_rows():
                if row.get("kind") == "failure":
                    raise Failed(f"Actual iOS provider observer failed: {row.get('message')}")
            result = condition()
            if result:
                return result
            if self.process is not None and self.process.poll() is not None:
                raise Failed(f"Actual XCUITest finished before {description} (exit={self.process.returncode}); inspect xcuitest.log/xcresult")
            time.sleep(0.25)
        raise Failed(f"Timed out waiting for {description}; no gameplay evidence was synthesized")

    def wait_game(self, stage: str) -> dict:
        return self.wait(f"executed Ren'Py {stage}", lambda: next(
            (r for r in self.game_rows() if is_script_checkpoint(r, stage, self.run_id)), None))

    def wait_observer(self, kind: str, **fields) -> dict:
        return self.wait(f"native observer {kind} {fields}", lambda: next((r for r in self.observer_rows()
                         if r.get("kind") == kind and all(r.get(k) == v for k, v in fields.items())), None))

    def ui(self, operation: str, **fields) -> dict:
        if self.ui_root is None:
            raise Failed("The actual UI test runner has not started")
        self.sequence += 1
        request = {"run_id": self.run_id, "seq": self.sequence, "op": operation, **fields}
        temporary = self.ui_root / "command.pending"
        temporary.write_text(json.dumps(request))
        temporary.replace(self.ui_root / "command.json")

        def acknowledgment():
            try:
                value = json.loads((self.ui_root / "ack.json").read_text())
                return value if value.get("run_id") == self.run_id and value.get("seq") == self.sequence else None
            except (OSError, ValueError):
                return None

        result = self.wait(f"actual XCUITest {operation}", acknowledgment)
        with (self.output / "ui-actions.jsonl").open("a") as stream:
            stream.write(json.dumps({"request": request, "acknowledgment": result}) + "\n")
        if result.get("success") is not True:
            raise Failed(f"Actual UI action {operation} failed: {result}")
        screenshot = self.ui_root / f"{self.sequence}.png"
        if screenshot.is_file():
            shutil.copyfile(screenshot, self.output / f"xcuitest-{self.sequence:02}-{operation}.png")
        return result

    def screenshot(self, stage: str) -> Path:
        path = self.output / f"os-{stage}.png"
        self.simctl("io", self.udid, "screenshot", str(path))
        png_pixels(path)
        return path

    def capture(self, stage: str) -> dict:
        row = self.wait_observer("provider_frame", stage=stage)
        native = row.get("provider_debug", {})
        if (row.get("source") != "native-provider-rgba" or native.get("runtime") != "renpy"
                or native.get("initialized") is not True or native.get("exited") is not False
                or int(row.get("frame_serial", 0)) <= 0):
            raise Failed("Frame lacks live initialized native Ren'Py state and pixels")
        provider_path = self.output / f"provider-{stage}.png"
        shutil.copyfile(self.documents / f"renpy-device-evidence/provider-{stage}.png", provider_path)
        provider = png_pixels(provider_path)
        self.ui("foreground")
        screen = png_pixels(self.screenshot(stage))
        stats = {"provider": image_stats(provider), "os_screenshot": image_stats(screen)}
        box, viewport = row["drawn_box"], row["viewport_size"]
        if min(viewport) <= 0 or min(box[2:]) <= 0:
            raise Failed("Frame lacks real Simulator presentation geometry")
        matches = count = 0
        for iy in range(1, 8):
            for ix in range(1, 12):
                u, v = ix / 12, iy / 8
                expected = pixel(provider, int(u * provider[0]), int(v * provider[1]))
                actual = pixel(screen, int((box[0] + u * box[2]) * screen[0] / viewport[0]),
                               int((box[1] + v * box[3]) * screen[1] / viewport[1]))
                matches += max(abs(a - b) for a, b in zip(expected, actual)) <= 24
                count += 1
        stats["native_to_os_match"] = {"matching_samples": matches, "samples": count,
                                        "fraction": matches / count, "channel_tolerance": 24}
        game_stage = "post_text_ready" if stage == "resumed_ready" else stage
        checkpoint = self.wait_game(game_stage)
        captured_checkpoint = row.get("game_checkpoint", {})
        if (not is_script_checkpoint(captured_checkpoint, game_stage, self.run_id)
                or captured_checkpoint.get("details") != checkpoint.get("details")):
            raise Failed("Native frame is not tied to the independently read executed Ren'Py scene checkpoint")
        stats["landmarks"] = verify_landmark_pixels(provider, screen, row, checkpoint)
        if stage == "quit_ready":
            if self.waiting_marker is None:
                raise Failed("No actual pre-pause native WAIT marker was captured")
            stats["resumed_marker_change"] = verify_resumed_marker(*self.waiting_marker, provider, checkpoint)
        (self.output / f"pixels-{stage}.json").write_text(json.dumps(stats, indent=2) + "\n")
        if matches / count < 0.70:
            raise Failed(f"Actual OS screenshot does not present Ren'Py native pixels at {stage}: {matches}/{count}")
        require_landmark_pixels(stats["landmarks"])
        if stage == "quit_ready" and stats["resumed_marker_change"]["fraction"] < 0.70:
            raise Failed("Native marker did not visibly change after the actual resumed OS touch")
        if stage == "post_text_ready":
            self.waiting_marker = (provider, checkpoint)
        self.summary["checks"].append({"stage": stage, "native_provider_pixels_and_os_screen": stats})
        return row

    def tap_button(self, frame: dict) -> None:
        box, viewport = frame["drawn_box"], frame["viewport_size"]
        details = checkpoint_landmarks(frame["game_checkpoint"])
        bx, by, bw, bh = details["button_bounds"]
        u = (bx + bw / 2) / details["logical_canvas"][0]
        v = (by + bh / 2) / details["logical_canvas"][1]
        self.ui("tap", x=(box[0] + box[2] * u) / viewport[0], y=(box[1] + box[3] * v) / viewport[1])

    def create_simulator(self) -> None:
        runtimes = json.loads(self.simctl("list", "runtimes", "--json"))
        types = json.loads(self.simctl("list", "devicetypes", "--json"))
        (self.output / "simulator-runtimes.json").write_text(json.dumps(runtimes, indent=2))
        available = [r for r in runtimes["runtimes"] if r.get("isAvailable") and ".iOS-" in r["identifier"]]
        if not available:
            raise Blocked("Xcode has no installed available iOS Simulator runtime; provision one on the cloud runner")
        runtime = max(available, key=lambda r: tuple(int(v) for v in r["version"].split(".")))
        device = None
        # simctl performs the authoritative compatibility check. Prefer a
        # supported iPhone from the runtime's own supportedDeviceTypes list.
        supported = runtime.get("supportedDeviceTypes", [])
        if supported:
            device = next((d for d in reversed(supported) if d.get("productFamily") == "iPhone" or d.get("name", "").startswith("iPhone")), None)
        if device is None:
            device = next((d for d in reversed(types["devicetypes"]) if d["name"].startswith("iPhone")), None)
        if device is None:
            raise Blocked("No compatible iPhone Simulator device type is installed on the cloud host")
        self.udid = self.simctl("create", "Aether RenPy gameplay " + self.run_id[:8], device["identifier"], runtime["identifier"]).decode().strip()
        self.created = True
        self.summary["runtime"] = runtime

    def stage(self) -> None:
        self.documents.mkdir(parents=True, exist_ok=True)
        for name in ("renpy-device-demo", "renpy-device-evidence"):
            shutil.rmtree(self.documents / name, ignore_errors=True)
        game = self.documents / "renpy-device-demo/game"
        game.mkdir(parents=True)
        for source in (self.repo / "demos/aetherkiri-renpy/game").iterdir():
            if source.is_file() and source.suffix in (".rpy", ".svg"):
                shutil.copyfile(source, game / source.name)
        (game / "aether-device-request.json").write_text(json.dumps({"run_id": self.run_id}))
        (self.documents / "aetherkiri-probe-request.json").write_text(json.dumps({
            "probe_script": "res://scripts/renpy_mobile_acceptance.gd", "run_id": self.run_id,
            "game_path": str(game.parent), "timeout_seconds": self.args.overall_timeout}))

    def start_xcuitest(self) -> None:
        project = self.repo / "tools/renpy_ios_acceptance/RenPyAcceptance.xcodeproj"
        derived = self.output / "xcode-derived"
        destination = "platform=iOS Simulator,id=" + self.udid
        self.command("xcodebuild", "build-for-testing", "-project", str(project), "-scheme", "RenPyAcceptance",
                     "-configuration", "Debug", "-destination", destination,
                     "-derivedDataPath", str(derived), "CODE_SIGN_IDENTITY=-", timeout=240)
        paths = list((derived / "Build/Products").glob("*.xctestrun"))
        if len(paths) != 1:
            raise Failed("Xcode did not produce one executable UI test configuration")
        configuration = plistlib.loads(paths[0].read_bytes())
        targets = []

        def configure(value):
            if isinstance(value, dict):
                if "TestBundlePath" in value and value.get("IsUITestBundle"):
                    value["UITargetAppPath"] = str(self.args.app.resolve())
                    value["UITargetAppBundleIdentifier"] = self.bundle_id
                    value.setdefault("EnvironmentVariables", {}).update({
                        "AETHER_RENPY_RUN_ID": self.run_id, "AETHER_RENPY_APP_BUNDLE_ID": self.bundle_id,
                        "AETHER_RENPY_TEST_TIMEOUT": str(self.args.overall_timeout)})
                    value.setdefault("DependentProductPaths", []).append(str(self.args.app.resolve()))
                    targets.append(value)
                else:
                    for child in value.values():
                        configure(child)
            elif isinstance(value, list):
                for child in value:
                    configure(child)

        configure(configuration)
        if len(targets) != 1:
            raise Failed("Xcode UI configuration lacks the real UI test target; refusing to substitute a fake host")
        xctestrun = self.output / "RenPyGameplay.xctestrun"
        # __TESTROOT__ is relative to the .xctestrun location.
        def resolve_paths(value):
            if isinstance(value, dict):
                for key, child in value.items():
                    value[key] = resolve_paths(child)
            elif isinstance(value, list):
                return [resolve_paths(child) for child in value]
            elif isinstance(value, str):
                return value.replace("__TESTROOT__", str(paths[0].parent))
            return value

        xctestrun.write_bytes(plistlib.dumps(resolve_paths(configuration)))
        runners = list((derived / "Build/Products").glob("**/RenPyAcceptance-Runner.app/Info.plist"))
        if len(runners) != 1:
            raise Failed("Xcode did not build the real Simulator UI test runner app")
        runner_id = plistlib.loads(runners[0].read_bytes())["CFBundleIdentifier"]
        self.summary["ui_test_runner"] = runner_id
        self.process_log = (self.output / "xcuitest.log").open("wb")
        self.process = subprocess.Popen(["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun),
                                        "-destination", destination, "-resultBundlePath", str(self.output / "gameplay.xcresult"),
                                        "-parallel-testing-enabled", "NO"], stdout=self.process_log, stderr=subprocess.STDOUT)

        def ready():
            data = self.simctl("get_app_container", self.udid, runner_id, "data", check=False).decode().strip()
            if not data:
                return None
            root = Path(data) / "Documents" / ("aether-renpy-ui-" + self.run_id)
            try:
                report = json.loads((root / "ready.json").read_text())
                if report.get("run_id") == self.run_id and report.get("ready") is True:
                    self.ui_root = root
                    return report
            except (OSError, ValueError):
                return None

        self.wait("installed XCUITest runner and actual app launch", ready, timeout=180)

    def run(self) -> None:
        if not self.args.cloud_simulator:
            raise Blocked("--cloud-simulator is required: only cloud-hosted devices are authorized")
        if platform.system() != "Darwin" or not shutil.which("xcrun") or not shutil.which("xcodebuild"):
            raise Blocked("Actual iOS Simulator gameplay requires a cloud macOS host with Xcode and its licensed SDK/runtime")
        if not (self.args.app / "Info.plist").is_file():
            raise Blocked(f"Installable Ren'Py-enabled Simulator .app is missing: {self.args.app}")
        info = plistlib.loads((self.args.app / "Info.plist").read_bytes())
        self.bundle_id = info["CFBundleIdentifier"]
        if "iPhoneSimulator" not in info.get("CFBundleSupportedPlatforms", []):
            raise Blocked("The provided .app targets iPhoneOS; this harness needs an actual Simulator build")
        self.summary["bundle_id"] = self.bundle_id
        self.summary["app_executable_sha256"] = hashlib.sha256((self.args.app / info["CFBundleExecutable"]).read_bytes()).hexdigest()
        self.summary["xcode_version"] = self.command("xcodebuild", "-version").decode().strip()
        if not self.udid:
            self.create_simulator()
        self.summary["udid"] = self.udid
        devices = json.loads(self.simctl("list", "devices", "--json"))
        selected = next((d for group in devices["devices"].values() for d in group if d["udid"] == self.udid and d.get("isAvailable")), None)
        if selected is None:
            raise Blocked(f"Selected cloud iOS Simulator {self.udid} is unavailable")
        if selected["state"] != "Booted":
            self.simctl("boot", self.udid)
        self.simctl("bootstatus", self.udid, "-b", timeout=180)
        self.keyboard_preference = self.command("defaults", "read", "com.apple.iphonesimulator", "ConnectHardwareKeyboard", check=False).decode().strip() or None
        self.command("defaults", "write", "com.apple.iphonesimulator", "ConnectHardwareKeyboard", "-bool", "false")
        self.preference_changed = True
        self.simctl("install", self.udid, str(self.args.app.resolve()), timeout=180)
        self.installed = True
        self.simctl("terminate", self.udid, self.bundle_id, check=False)
        root = self.simctl("get_app_container", self.udid, self.bundle_id, "data").decode().strip()
        self.documents = Path(root) / "Documents"
        self.stage()
        self.deadline = time.monotonic() + self.args.overall_timeout
        self.start_xcuitest()
        self.wait_game("start_ready")
        self.tap_button(self.capture("start_ready"))
        self.wait_game("touch_received")
        self.wait_game("text_ready")
        keyboard = self.wait_observer("soft_keyboard", active=True)
        visible = self.wait_observer("soft_keyboard_visibility", visible=True)
        if keyboard.get("source") != "native-text-input-state" or not keyboard.get("feature_available") or visible.get("height", 0) <= 0:
            raise Failed("Native text input did not show a real iOS virtual keyboard")
        keyboard_ui = self.ui("keyboard")
        if keyboard_ui.get("keyboard_visible") is not True:
            raise Failed("XCUITest could not see the actual iOS software keyboard")
        self.screenshot("text-ready-keyboard")
        typed = "CloudRenPy" + self.run_id[:8]
        self.ui("type", text=typed + "\n")
        text = self.wait_game("text_received")
        if text.get("details", {}).get("text") != typed:
            raise Failed(f"Ren'Py input differs from actual system keyboard text: {text.get('details')}")
        self.wait_game("post_text_ready")
        self.wait_observer("soft_keyboard_visibility", visible=False)
        self.capture("post_text_ready")
        self.ui("home")
        pause = self.wait_observer("lifecycle", phase="paused")
        if pause.get("result") != 0 or pause.get("provider_debug", {}).get("paused") is not True:
            raise Failed("Home did not pause the actual native runtime")
        self.screenshot("background-home")
        self.ui("activate")
        resume = self.wait_observer("lifecycle", phase="resumed")
        if resume.get("result") != 0 or resume.get("provider_debug", {}).get("paused") is not False:
            raise Failed("Foreground did not resume the actual native runtime")
        frame = self.capture("resumed_ready")
        if int(frame.get("frame_serial", 0)) <= int(pause.get("provider_debug", {}).get("frame_serial", 0)):
            raise Failed("Resume presented a cached pre-pause frame")
        if any(r.get("stage") == "resumed_touch_received" for r in self.game_rows()):
            raise Failed("Ren'Py advanced before the real resumed UI touch")
        self.tap_button(frame)
        self.wait_game("resumed_touch_received")
        self.wait_game("quit_ready")
        self.tap_button(self.capture("quit_ready"))
        self.wait_game("quit_requested")
        normal_exit = self.wait_observer("normal_exit")
        if not normal_exit.get("engine_destroyed") or normal_exit.get("provider_debug", {}).get("exited") is not True:
            raise Failed("Explicit Quit did not stop native Ren'Py and destroy its engine")
        library = self.wait_observer("library_return")
        self.verify_library_return(library)
        events = self.observer_rows()
        for action in (1, 3):
            if not any(r.get("kind") == "os_touch" and r.get("action") == action and r.get("result") == 0 for r in events):
                raise Failed(f"Actual iOS touch action {action} never reached the provider")
        if not any(r.get("kind") == "os_key" and r.get("pressed") and r.get("code") == 13 for r in events):
            raise Failed("Actual iOS Enter key never reached the provider")
        self.ui("finish")
        try:
            returncode = self.process.wait(timeout=30)
        except subprocess.TimeoutExpired as exc:
            raise Failed("XCUITest did not finish after complete gameplay") from exc
        if returncode:
            raise Failed(f"Actual XCUITest failed (exit={returncode}); inspect its retained xcresult")
        self.summary["checks"].extend([{"real_ios_touch_and_keyboard_text": typed},
            {"real_ios_pause_resume": {"pause": pause, "resume": resume}},
            {"explicit_renpy_exit_and_actual_library_return": {"native": normal_exit, "library": library}}])
        game_root = self.documents / "renpy-device-demo"
        raw = read_engine_log_file(game_root / "aetherkiri-engine.log")
        (self.output / "aetherkiri-engine.log").write_bytes(raw)
        self.summary["checks"].append({"native_cleanup_error_log": require_engine_log(raw, str(game_root))})
        self.summary["status"] = "passed"

    def verify_library_return(self, report: dict) -> None:
        ui = report.get("ui", {})
        if (report.get("source") != "actual-production-main-scene" or not report.get("engine_destroyed")
                or ui.get("scene_path") != "res://scenes/main.tscn"
                or ui.get("script_path") != "res://scripts/main.gd"
                or not ui.get("shell_visible") or not ui.get("library_visible")
                or ui.get("game_view_visible") is not False or ui.get("route") != "library"
                or ui.get("mode") != "game" or not ui.get("title") or not ui.get("title_visible")
                or not ui.get("search_visible") or not ui.get("native_exited") or ui.get("image_result") != 0
                or not ui.get("library_path", "").endswith("/LibraryView")
                or not ui.get("search_path", "").endswith("/LibrarySearch")):
            raise Failed("Normal game exit did not restore the actual main scene's game library")
        self.ui("foreground")
        actual_path = self.output / "production-library.png"
        shutil.copyfile(self.documents / "renpy-device-evidence/production-library.png", actual_path)
        library = png_pixels(actual_path)
        screen = png_pixels(self.screenshot("actual-library-after-game-exit"))
        stats = {"library_viewport": image_stats(library), "os_screenshot": image_stats(screen)}
        matches = count = 0
        # Prove the restored production library is actually visible in the
        # OS compositor. Only its viewport, never a test-painted label, is
        # used for this final UI comparison; gameplay used native RGBA above.
        for iy in range(1, 10):
            for ix in range(1, 10):
                u, v = ix / 10, iy / 10
                expected = pixel(library, int(u * library[0]), int(v * library[1]))
                actual = pixel(screen, int(u * screen[0]), int(v * screen[1]))
                matches += max(abs(a - b) for a, b in zip(expected, actual)) <= 24
                count += 1
        stats["library_to_os_match"] = {"matching_samples": matches, "samples": count,
                                        "fraction": matches / count, "channel_tolerance": 24}
        (self.output / "pixels-actual-library.json").write_text(json.dumps(stats, indent=2) + "\n")
        if matches / count < 0.70:
            raise Failed("The actual restored LibraryView is absent from the system screenshot")
        self.summary["checks"].append({"actual_library_return_pixels_and_os_screen": stats})

    def collect(self) -> None:
        if self.documents is not None:
            for relative, filename in [
                ("renpy-device-demo/aetherkiri-engine.log", "aetherkiri-engine.log"),
                ("renpy-device-evidence/observer.jsonl", "observer.jsonl"),
                ("renpy-device-demo/game/aether-device-checkpoints.jsonl", "renpy-script-checkpoints.jsonl"),
                ("renpy-device-demo/log.txt", "renpy-log.txt"),
                ("renpy-device-demo/traceback.txt", "renpy-traceback.txt")]:
                try:
                    source = self.documents / relative
                    if source.is_file():
                        shutil.copyfile(source, self.output / filename)
                except OSError as exc:
                    with (self.output / "collection-errors.jsonl").open("a") as stream:
                        stream.write(json.dumps({"path": relative, "error": str(exc)}) + "\n")
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=10)
        if self.process_log is not None:
            self.process_log.close()
        if self.installed:
            try:
                logs = self.simctl("spawn", self.udid, "log", "show", "--last", "10m", "--style", "compact", check=False, timeout=60)
                (self.output / "simulator-system.log").write_bytes(logs)
            except Failed:
                pass
        if self.preference_changed:
            if self.keyboard_preference is None:
                self.command("defaults", "delete", "com.apple.iphonesimulator", "ConnectHardwareKeyboard", check=False)
            else:
                self.command("defaults", "write", "com.apple.iphonesimulator", "ConnectHardwareKeyboard", "-bool", self.keyboard_preference, check=False)
        if self.created:
            self.simctl("shutdown", self.udid, check=False)
            self.simctl("delete", self.udid, check=False)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--cloud-simulator", action="store_true")
    parser.add_argument("--udid", help="Optional existing cloud Simulator; otherwise create and delete a disposable one")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--stage-timeout", type=int, default=60)
    parser.add_argument("--overall-timeout", type=int, default=600)
    args = parser.parse_args()
    if not 1 <= args.stage_timeout <= 180 or not 60 <= args.overall_timeout <= 1200:
        parser.error("stage timeout must be 1..180 and overall timeout 60..1200 seconds")
    acceptance = Acceptance(args)
    result = 1
    try:
        acceptance.run()
        result = 0
    except Blocked as exc:
        acceptance.summary.update(status="not_run", blocker=str(exc))
        result = 2
    except (Failed, OSError, ValueError, KeyError) as exc:
        acceptance.summary.update(status="failed", blocker=str(exc))
    finally:
        try:
            acceptance.collect()
        except (Failed, OSError) as exc:
            acceptance.summary["collection_error"] = str(exc)
        (acceptance.output / "result.json").write_text(json.dumps(acceptance.summary, indent=2) + "\n")
        print(json.dumps(acceptance.summary, indent=2))
    return result


if __name__ == "__main__":
    raise SystemExit(main())
