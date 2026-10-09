#!/usr/bin/env python3
"""Boot a real cloud Android emulator and optionally run the actual APK harness.

Only existing KVM/HVF access and existing SDK license acceptance are used.
This never changes device permissions, accepts licenses or falls back to a
simulated provider. Session and original gameplay results remain separate.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import signal
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

from preflight_renpy_android_device import Preflight, Unavailable
from run_renpy_android_device_acceptance import Failed, png_pixels


IMAGE = "system-images;android-35;google_apis;x86_64"
SENSITIVE_DIAGNOSTIC = re.compile(
    r"auth|token|credentials?|password|passwd|secret|jwt|grpc|api[_-]?key|"
    r"[a-z][a-z0-9+.-]*://|www\.|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+",
    re.IGNORECASE,
)


def os_screen_stats(image: tuple[int, int, bytes, int]) -> dict:
    """Require visible OS content, without applying the Ren'Py scene palette gate."""
    width, height, data, channels = image
    if width <= 0 or height <= 0 or width * height > 30_000_000 or channels not in (3, 4) \
            or len(data) != width * height * channels:
        raise Failed("Invalid decoded Android OS screenshot dimensions or pixels")
    colors, luma = set(), []
    for y in range(0, height, max(1, height // 64)):
        for x in range(0, width, max(1, width // 64)):
            offset = (y * width + x) * channels
            rgb = tuple(data[offset:offset + 3])
            colors.add(rgb)
            luma.append(sum(rgb) / 3)
    stats = {"width": width, "height": height, "sampled_colors": len(colors),
             "luma_range": max(luma) - min(luma)}
    # A monochrome status bar can be valid OS content. A uniform frame or
    # low-contrast noise cannot demonstrate that the display is ready.
    stats["ready"] = stats["sampled_colors"] >= 2 and stats["luma_range"] >= 40
    return stats


def bounded_diagnostic(raw: bytes | str, *, max_chars: int = 4096, max_lines: int = 32) -> dict:
    """Keep a small sanitized tail of only this session's actual output."""
    text = raw.decode(errors="replace") if isinstance(raw, bytes) else raw
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    lines = text.splitlines()
    selected = lines[-max_lines:]
    output = []
    redacted = 0
    for line in selected:
        line = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", line)
        if SENSITIVE_DIAGNOSTIC.search(line):
            output.append("[redacted sensitive diagnostic line]")
            redacted += 1
        else:
            output.append(line[:512])
    joined = "\n".join(output)
    return {"output": joined[-max_chars:], "redacted_lines": redacted,
            "truncated": len(lines) > max_lines or any(len(line) > 512 for line in selected)
            or len(joined) > max_chars}


def diagnostic_file_tail(path: Path, *, read_limit: int = 65536) -> dict:
    # Never read a previous artifact or an unbounded emulator/kernel log.
    try:
        with path.open("rb") as stream:
            size = stream.seek(0, os.SEEK_END)
            stream.seek(max(0, size - read_limit))
            raw = stream.read(read_limit)
            if size > read_limit:
                # A cut line may have lost its sensitive header. Drop it whole.
                raw = raw.partition(b"\n")[2]
            result = bounded_diagnostic(raw)
        result["truncated"] |= size > read_limit
        return result
    except OSError as exc:
        return {"unavailable": True, **bounded_diagnostic(str(exc), max_chars=256, max_lines=1)}


def acceleration_usable(output: str, system: str) -> bool:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    try:
        start = lines.index("accel:")
    except ValueError:
        return False
    if len(lines) < start + 3 or lines[start + 1] != "0":
        return False
    description = lines[start + 2]
    lower = description.lower()
    if re.search(r"unavailable|unsupported|unusable|not\s+(?:available|installed|usable)|"
                 r"could\s+not|failed|disabled|error", lower):
        return False
    if system == "Darwin":
        documented = re.fullmatch(r"Hypervisor\.Framework OS X Version \d+(?:\.\d+)*", description)
        explicit = re.search(r"\b(?:hvf|hypervisor\.framework)\b", lower) and re.search(
            r"\b(?:installed and usable|available and usable|is usable)\b", lower)
        return bool(documented or explicit)
    return system == "Linux" and bool(re.search(r"\bkvm\b", lower)
                                       and re.search(r"\b(?:installed and usable|is usable)\b", lower))


def owned_group_state(process: subprocess.Popen) -> str:
    """The caller must have created this Popen with start_new_session=True."""
    if getattr(process, "_renpy_group_permission_denied", False):
        return "permission_denied"
    try:
        os.killpg(process.pid, 0)
    except ProcessLookupError:
        return "absent"
    except PermissionError:
        # Unknown is never absent. Do not retry a denied probe or signal.
        process._renpy_group_permission_denied = True
        return "permission_denied"
    return "present"


def owned_group_exists(process: subprocess.Popen) -> bool:
    return owned_group_state(process) != "absent"


def wait_owned_group_exit(process: subprocess.Popen, grace: float) -> bool:
    deadline = time.monotonic() + grace
    while True:
        state = owned_group_state(process)
        if state == "absent":
            return True
        if state == "permission_denied":
            return False
        if time.monotonic() >= deadline:
            return False
        time.sleep(min(0.05, max(0, deadline - time.monotonic())))


def terminate_owned_process(process: subprocess.Popen, grace: float = 10) -> int:
    """Signal all members of our group and reap our direct child.

    The group can outlive its leader. Orphaned descendants are reaped by their
    OS parent, so leader.wait() alone is insufficient to terminate that group.
    """
    if owned_group_state(process) == "present":
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except PermissionError:
            process._renpy_group_permission_denied = True
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    if owned_group_state(process) == "permission_denied" and process.poll() is None:
        raise Unavailable("Owned process-group probe/signal permission was denied; no permission retry was made")
    if not wait_owned_group_exit(process, grace) and owned_group_state(process) != "permission_denied":
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            process._renpy_group_permission_denied = True
    return process.wait(timeout=grace)


def gameplay_result_matches(summary: dict, code: int, package: str, serial: str, apk_hash: str) -> bool:
    return isinstance(summary, dict) and code == 0 and summary.get("status") == "passed" \
        and summary.get("source") == "actual-apk-adb-cloud-device" and summary.get("serial") == serial \
        and summary.get("package") == package and summary.get("apk_sha256") == apk_hash


class Session(Preflight):
    def __init__(self, args: argparse.Namespace):
        super().__init__(args)
        self.harness_process = None
        self.harness_log = None
        self.boot_started = None
        self.next_boot_progress = 0
        self.result.update(scope="actual-cloud-android-emulator-session",
                           gameplay_verification="not_run", gameplay_attempted=False,
                           gameplay_verified=False, harness_started=False,
                           requested_gameplay=args.apk is not None)

    def boot_progress(self, phase: str, *, response: subprocess.CompletedProcess | None = None) -> None:
        now = time.monotonic()
        self.result["boot_elapsed_seconds"] = round(now - self.boot_started, 1)
        self.result["boot_phase"] = phase
        if response is not None:
            self.result["last_boot_response"] = {"returncode": response.returncode,
                                                 **bounded_diagnostic(response.stdout, max_chars=256, max_lines=2)}
        if now >= self.next_boot_progress:
            print(json.dumps({"checkpoint": "actual-android-boot-progress", "phase": phase,
                              "elapsed_seconds": self.result["boot_elapsed_seconds"],
                              "serial": self.result["serial"],
                              "emulator_returncode": self.emulator_process.poll(),
                              "last_boot_response": self.result.get("last_boot_response"),
                              "actual_os_screen": self.result.get("actual_os_screen"),
                              "gameplay_verification": "not_run"}), flush=True)
            self.next_boot_progress = now + 30

    def diagnostic_command(self, *parts: str, timeout: int = 3, max_chars: int = 1024) -> dict:
        started = time.monotonic()
        try:
            completed = subprocess.run([str(self.adb), "-s", self.result["serial"], *parts],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       env=self.environment, timeout=timeout)
            result = {"returncode": completed.returncode,
                      **bounded_diagnostic(completed.stdout, max_chars=max_chars, max_lines=20)}
        except subprocess.TimeoutExpired as exc:
            result = {"timed_out": True, **bounded_diagnostic(exc.stdout or b"", max_chars=max_chars, max_lines=20)}
        except OSError as exc:
            result = {"unavailable": True, **bounded_diagnostic(str(exc), max_chars=256, max_lines=1)}
        result["elapsed_seconds"] = round(time.monotonic() - started, 1)
        return result

    def boot_failure_diagnostics(self) -> None:
        """Read the currently owned AVD before stop; never dump its environment."""
        started = time.monotonic()
        diagnostics = {"checkpoint": "actual-android-boot-failure-diagnostics",
                       "boot_elapsed_seconds": round(started - self.boot_started, 1),
                       "phase": self.result.get("boot_phase"), "serial": self.result["serial"],
                       "emulator_returncode": self.emulator_process.poll(),
                       "last_boot_response": self.result.get("last_boot_response"),
                       "gameplay_verification": "not_run",
                       "emulator_log_tail": diagnostic_file_tail(self.output / "emulator.log")}
        diagnostics["adb_state"] = self.diagnostic_command("get-state")
        diagnostics["boot_properties"] = {
            name: self.diagnostic_command("shell", "getprop", name, max_chars=256)
            for name in ("sys.boot_completed", "dev.bootcomplete", "init.svc.bootanim", "ro.build.version.sdk")
        }
        # Read at most 80 current warning/error entries, without clearing logcat.
        diagnostics["logcat_warning_tail"] = self.diagnostic_command(
            "logcat", "-d", "-t", "80", "-v", "brief", "*:W", timeout=5, max_chars=3072)
        diagnostics["diagnostic_elapsed_seconds"] = round(time.monotonic() - started, 1)
        self.result["boot_failure_diagnostics"] = diagnostics
        print(json.dumps(diagnostics), flush=True)

    def gate_host(self, sdk: Path) -> Path:
        system, machine = platform.system(), platform.machine()
        if machine != "x86_64" or system not in ("Linux", "Darwin"):
            raise Unavailable("An actual Linux x86_64/KVM or Intel macOS/HVF cloud runner is required")
        if system == "Linux":
            kvm = Path("/dev/kvm")
            self.result["kvm"] = {"exists": kvm.exists(), "readable": os.access(kvm, os.R_OK),
                                  "writable": os.access(kvm, os.W_OK)}
            if kvm.exists():
                self.result["kvm"]["mode"] = oct(kvm.stat().st_mode & 0o777)
            if not all(self.result["kvm"][key] for key in ("exists", "readable", "writable")):
                raise Unavailable("Existing /dev/kvm read/write access is unavailable; no permissions were changed")
            self.result["hypervisor"] = "KVM"
        else:
            support = self.command("host-hvf-support", ["/usr/sbin/sysctl", "-n", "kern.hv_support"])
            self.result["kern_hv_support"] = support.stdout.decode(errors="replace").strip()
            if self.result["kern_hv_support"] != "1":
                raise Unavailable("The actual Intel macOS runner does not expose kern.hv_support=1")
            self.result["hypervisor"] = "HVF"
        emulator = sdk / "emulator/emulator"
        if not emulator.is_file() or not os.access(emulator, os.X_OK):
            raise Unavailable(f"The existing official emulator is unavailable: {emulator}; no emulator was downloaded")
        self.command("emulator-version", [str(emulator), "-version"], timeout=45)
        check = self.command("acceleration", [str(emulator), "-accel-check"], check=False, timeout=45)
        output = check.stdout.decode(errors="replace")
        self.result["acceleration"] = {"returncode": check.returncode, "output": output[:1600],
                                       "output_truncated": len(output) > 1600}
        if check.returncode or len(output) > 1600 or not acceleration_usable(output, system):
            raise Unavailable(f"Google's actual acceleration report does not confirm usable {self.result['hypervisor']}")
        self.result["checks"].append("official-emulator-" + self.result["hypervisor"].lower() + "-usable")
        print(json.dumps({"checkpoint": "actual-acceleration-usable", "hypervisor": self.result["hypervisor"],
                          "gameplay_verification": "not_run"}), flush=True)
        return emulator

    def prepare_sdk(self, sdk: Path) -> Path:
        manager, avdmanager = (sdk / "cmdline-tools/latest/bin" / name for name in ("sdkmanager", "avdmanager"))
        for tool in (manager, avdmanager):
            if not tool.is_file() or not os.access(tool, os.X_OK):
                raise Unavailable(f"An existing official SDK tool is missing: {tool}")
        # Inherited command() uses DEVNULL, not 'yes' or sdkmanager --licenses.
        installed = self.command("official-sdk-install", [str(manager), "--install", "platform-tools", IMAGE],
                                 timeout=600, check=False)
        properties = sdk / "system-images/android-35/google_apis/x86_64/source.properties"
        self.adb = sdk / "platform-tools/adb"
        if installed.returncode or not properties.is_file() or not self.adb.is_file():
            detail = installed.stdout.decode(errors="replace")[-1800:]
            if re.search(r"licen[cs]es?.*(?:not accepted|not been accepted)|"
                         r"(?:accept|review).*licen[cs]e", detail, re.IGNORECASE):
                raise Unavailable("Official SDK installation is blocked by missing existing license acceptance; "
                                  "no new license was accepted. See official-sdk-install.log: " + detail)
            raise Unavailable(f"Official SDK installation did not provide the requested image/tools "
                              f"(exit {installed.returncode}); see official-sdk-install.log: {detail}")
        (self.output / "system-image-source.properties").write_bytes(properties.read_bytes())
        self.command("adb-version", [str(self.adb), "version"])
        self.result.update(sdk_root=str(sdk), system_image=IMAGE)
        self.environment["PATH"] = os.pathsep.join((str(sdk / "platform-tools"), str(sdk / "emulator"),
                                                     self.environment.get("PATH", "")))
        return avdmanager

    def boot(self, emulator: Path, avdmanager: Path, avd_root: Path) -> None:
        avd_root.mkdir()
        self.environment["ANDROID_AVD_HOME"] = str(avd_root)
        name = "aether-renpy-cloud-session"
        self.command("create-official-avd", [str(avdmanager), "create", "avd", "--name", name, "--force",
                     "--device", "pixel_2", "--package", IMAGE], input_data=b"no\n", timeout=120)
        config = avd_root / f"{name}.avd/config.ini"
        if not config.is_file():
            raise Unavailable("Official avdmanager did not create the requested AVD")
        with config.open("a") as stream:
            stream.write("\nhw.keyboard=no\n")
        (self.output / "avd-config.ini").write_bytes(config.read_bytes())
        command = [str(emulator), "-avd", name, "-port", str(self.args.port), "-accel", "on",
                   "-gpu", "swiftshader", "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot",
                   "-memory", "3072", "-camera-front", "none", "-camera-back", "none"]
        # Official boot diagnostics only; acceleration, graphics and timeout stay unchanged.
        # https://developer.android.com/studio/run/emulator-commandline
        command.append("-show-kernel")
        self.result["emulator_command"] = command
        self.emulator_log = (self.output / "emulator.log").open("wb")
        self.emulator_process = subprocess.Popen(command, stdout=self.emulator_log, stderr=subprocess.STDOUT,
                                                 stdin=subprocess.DEVNULL, env=self.environment, start_new_session=True)
        self.execution_started = True
        self.result["execution_started"] = True
        self.boot_started = time.monotonic()
        deadline = self.boot_started + self.args.boot_timeout
        adb_deadline = self.boot_started + min(180, self.args.boot_timeout)
        while time.monotonic() < adb_deadline:
            self.boot_progress("waiting-for-adb")
            try:
                self.device("adb-wait-for-device", "wait-for-device",
                            timeout=min(30, max(0.1, adb_deadline - time.monotonic())))
                break
            except Unavailable as exc:
                if not isinstance(exc.__cause__, subprocess.TimeoutExpired):
                    raise
        else:
            raise Unavailable("Actual ADB did not connect within its existing boot wait deadline; see emulator.log")
        while time.monotonic() < deadline:
            self.boot_progress("waiting-for-sys.boot_completed")
            if self.emulator_process.poll() is not None:
                raise Unavailable(f"Actual emulator exited before boot: {self.emulator_process.returncode}; see emulator.log")
            remaining = deadline - time.monotonic()
            completed = self.device("boot-completed", "shell", "getprop", "sys.boot_completed",
                                    timeout=min(20, max(0.1, remaining)), check=False)
            self.boot_progress("waiting-for-sys.boot_completed", response=completed)
            if completed.returncode:
                raise Unavailable(f"Actual ADB boot property read failed (exit {completed.returncode}); see boot-completed.log")
            if completed.stdout.decode().strip() == "1":
                self.result["boot_completed"] = True
                break
            time.sleep(min(2, max(0, deadline - time.monotonic())))
        else:
            raise Unavailable(f"Actual emulator did not boot within {self.args.boot_timeout}s; see emulator.log")
        self.validate_booted_device(deadline)

    def boot_device(self, label: str, *parts: str, deadline: float, timeout: int = 30):
        """Every readiness command uses the original emulator boot deadline."""
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise Unavailable("Actual Android OS display was not verified before the original boot deadline")
        return self.device(label, *parts, timeout=min(timeout, remaining))

    def wait_os_screen(self, deadline: float) -> None:
        screenshot = self.output / "actual-android-screen.png"
        self.result["os_screen_attempts"] = 0
        self.result["os_screen_observations"] = []
        while True:
            captured = self.boot_device("screen-capture", "exec-out", "screencap", "-p", deadline=deadline)
            screenshot.write_bytes(captured.stdout)
            # Failed adb commands, permission errors and malformed PNGs are
            # fatal. Only a real, decoded but not-yet-visible frame is retried.
            try:
                stats = os_screen_stats(png_pixels(screenshot))
            except (struct.error, zlib.error) as exc:
                raise Failed("Actual Android OS screenshot has malformed PNG data") from exc
            self.result["os_screen_attempts"] += 1
            observation = {"attempt": self.result["os_screen_attempts"],
                           "elapsed_seconds": round(time.monotonic() - self.boot_started, 1), **stats}
            self.result["actual_os_screen"] = observation
            self.result["os_screen_observations"] = (self.result["os_screen_observations"] + [observation])[-32:]
            self.boot_progress("waiting-for-os-screen")
            if observation["attempt"] == 1:
                print(json.dumps({"checkpoint": "actual-android-first-os-screen", **observation,
                                  "gameplay_verification": "not_run"}), flush=True)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Unavailable("Actual Android OS display was not verified before the original boot deadline")
            if stats["ready"]:
                self.result["boot_phase"] = "validated-booted-device"
                return
            time.sleep(min(2, remaining))

    def validate_booted_device(self, deadline: float) -> None:
        self.result["boot_phase"] = "validating-booted-device"
        # Ordinary input wakes the screen; it does not change lock/security settings.
        self.boot_device("wakeup", "shell", "input", "keyevent", "224", deadline=deadline)
        self.boot_device("unlock", "shell", "input", "keyevent", "82", deadline=deadline)
        values = {}
        for name in ("ro.build.fingerprint", "ro.product.cpu.abilist", "ro.build.version.sdk", "ro.opengles.version"):
            values[name] = self.boot_device("property-" + name, "shell", "getprop", name,
                                            deadline=deadline).stdout.decode().strip()
        self.result["device_properties"] = values
        if not values["ro.build.fingerprint"] or "x86_64" not in values["ro.product.cpu.abilist"].split(",") \
                or values["ro.build.version.sdk"] != "35":
            raise Unavailable("The booted Android device is not the actual requested Android 35 x86_64 image")
        if int(values["ro.opengles.version"] or "0") < 0x30000:
            raise Unavailable("The actual Android device does not advertise required GLES 3.0")
        surface = self.boot_device("surfaceflinger", "shell", "dumpsys", "SurfaceFlinger",
                                   deadline=deadline).stdout.decode(errors="replace")
        self.result["surfaceflinger_gles"] = [line.strip() for line in surface.splitlines() if "GLES:" in line]
        if not self.result["surfaceflinger_gles"]:
            raise Unavailable("Actual SurfaceFlinger did not report a GLES renderer; see surfaceflinger.log")
        self.wait_os_screen(deadline)
        self.result["checks"].extend(("actual-android-boot-completed", "adb-real-device-properties",
                                      "actual-surfaceflinger-gles", "actual-os-screen"))
        print(json.dumps({"checkpoint": "actual-android-booted", "device_properties": values,
                          "surfaceflinger_gles": self.result["surfaceflinger_gles"],
                          "actual_os_screen": self.result["actual_os_screen"],
                          "gameplay_verification": "not_run"}), flush=True)

    def gameplay(self) -> None:
        output = self.output / "gameplay"
        self.result["harness_result_path"] = "gameplay/result.json"
        command = [sys.executable, str(Path(__file__).with_name("run_renpy_android_device_acceptance.py")),
                   "--apk", str(self.args.apk.resolve()), "--package", self.args.package,
                   "--serial", self.result["serial"], "--adb", str(self.adb), "--cloud-device",
                   "--stage-timeout", str(self.args.stage_timeout), "--overall-timeout", str(self.args.gameplay_timeout),
                   "--output-dir", str(output)]
        self.result["harness_command"] = command
        self.harness_log = (self.output / "gameplay-harness.log").open("wb")
        self.harness_process = subprocess.Popen(command, stdout=self.harness_log, stderr=subprocess.STDOUT,
                                                stdin=subprocess.DEVNULL, env=self.environment, start_new_session=True)
        self.result.update(harness_started=True, gameplay_attempted=True, gameplay_executed=None)
        print(json.dumps({"checkpoint": "actual-apk-harness-started", "deadline_seconds": self.args.gameplay_timeout,
                          "gameplay_verified": False}), flush=True)
        try:
            code = self.harness_process.wait(timeout=self.args.gameplay_timeout)
            self.result["harness_returncode"] = code
        except subprocess.TimeoutExpired as exc:
            self.result.update(harness_timed_out=True, gameplay_verification="failed")
            self.result["harness_returncode"] = terminate_owned_process(self.harness_process)
            raise Unavailable(f"Actual APK harness exceeded its whole-process {self.args.gameplay_timeout}s deadline") from exc
        finally:
            try:
                if self.harness_process.poll() is None or not wait_owned_group_exit(self.harness_process, 1):
                    self.result["harness_forced_cleanup"] = True
                    terminate_owned_process(self.harness_process)
                else:
                    self.harness_process.wait(timeout=10)
            finally:
                group_state = owned_group_state(self.harness_process)
                self.result["harness_group_state"] = group_state
                self.result["harness_group_still_present"] = group_state != "absent"
                if group_state == "permission_denied":
                    self.result.update(harness_cleanup_permission_denied=True, gameplay_verification="failed")
                self.harness_log.close()
                self.harness_log = None
                if self.harness_process.poll() is not None:
                    self.harness_process = None
        if self.result.get("harness_forced_cleanup") or self.result.get("harness_group_state") != "absent" \
                or self.result.get("harness_cleanup_permission_denied"):
            self.result["gameplay_verification"] = "failed"
            raise Unavailable("The actual harness process group is not confirmed absent; cleanup could not be verified")
        summary_path = output / "result.json"
        if not summary_path.is_file():
            raise Unavailable("Actual APK harness did not produce its gameplay result; see gameplay-harness.log")
        summary = json.loads(summary_path.read_text())
        if not isinstance(summary, dict):
            raise Unavailable("Actual APK harness result is not a JSON object")
        self.result["gameplay_result"] = summary
        self.result["gameplay_verification"] = summary.get("status", "failed")
        if summary.get("status") == "not_run":
            self.result["gameplay_executed"] = False
        apk_hash = hashlib.sha256(self.args.apk.read_bytes()).hexdigest()
        if not gameplay_result_matches(summary, code, self.args.package, self.result["serial"], apk_hash):
            self.result["gameplay_verification"] = "not_run" if summary.get("status") == "not_run" else "failed"
            raise Unavailable(f"Actual APK gameplay did not pass (harness exit {code}, result {summary.get('status')}); "
                              "see gameplay/result.json and gameplay-harness.log")
        self.result.update(gameplay_executed=True, gameplay_verified=True, apk_installed=True, apk_sha256=apk_hash)
        self.result["checks"].append("actual-apk-renpy-gameplay-harness-passed")

    def stop(self, *, require_clean: bool) -> None:
        process = self.emulator_process
        if process is None:
            if self.emulator_log:
                self.emulator_log.close()
                self.emulator_log = None
            return
        clean = False
        try:
            if process.poll() is None:
                try:
                    killed = self.device("stop-emulator", "emu", "kill", check=False, timeout=20)
                    clean = killed.returncode == 0 and process.wait(timeout=25) == 0
                except (Unavailable, subprocess.TimeoutExpired):
                    clean = False
            if process.poll() is None or not wait_owned_group_exit(process, 1):
                self.result["emulator_forced_cleanup"] = True
                clean = False
                terminate_owned_process(process)
            else:
                process.wait(timeout=10)
        finally:
            group_state = owned_group_state(process)
            self.result.update(emulator_exit_code=process.returncode,
                               emulator_stopped_cleanly=clean and group_state == "absent")
            self.result["emulator_group_state"] = group_state
            self.result["emulator_group_still_present"] = group_state != "absent"
            if group_state == "permission_denied":
                self.result["emulator_cleanup_permission_denied"] = True
            if self.emulator_log:
                self.emulator_log.close()
                self.emulator_log = None
            if process.poll() is not None:
                self.emulator_process = None
        if require_clean and not self.result["emulator_stopped_cleanly"]:
            raise Unavailable("The actual emulator did not stop cleanly; see stop-emulator.log/emulator.log")

    def run(self) -> None:
        if not self.args.cloud_emulator:
            raise Unavailable("--cloud-emulator is required; only a selected cloud runner is authorized")
        if self.args.apk is not None and not self.args.apk.is_file():
            raise Unavailable(f"The actual installable APK is missing: {self.args.apk}")
        sdk = Path(self.args.sdk_root).resolve() if self.args.sdk_root else None
        if sdk is None or not sdk.is_dir():
            raise Unavailable("Existing official ANDROID_HOME/ANDROID_SDK_ROOT is unavailable")
        emulator = self.gate_host(sdk)
        manager = self.prepare_sdk(sdk)
        with tempfile.TemporaryDirectory(prefix="renpy-cloud-emulator-session-") as temporary:
            primary_failure = None
            try:
                try:
                    self.boot(emulator, manager, Path(temporary) / "avd")
                except (Unavailable, Failed, OSError, ValueError, subprocess.TimeoutExpired) as boot_error:
                    self.result["boot_failure"] = bounded_diagnostic(str(boot_error), max_chars=1024, max_lines=4)
                    if self.execution_started:
                        self.result["boot_failed"] = True
                        try:
                            self.boot_failure_diagnostics()
                        except (OSError, ValueError) as diagnostic_error:
                            self.result["boot_failure_diagnostic_error"] = bounded_diagnostic(str(diagnostic_error))
                    raise
                if self.args.apk is not None:
                    self.gameplay()
                self.stop(require_clean=True)
                self.result["checks"].append("actual-emulator-stopped")
                self.result["status"] = "passed"
            except (Unavailable, Failed, OSError, ValueError, KeyboardInterrupt, subprocess.TimeoutExpired) as exc:
                primary_failure = exc
                raise
            finally:
                try:
                    self.stop(require_clean=False)
                except (Unavailable, OSError, subprocess.TimeoutExpired) as cleanup_error:
                    self.result.update(status="failed", cleanup_error=bounded_diagnostic(
                        str(cleanup_error), max_chars=1024, max_lines=4))
                    if primary_failure is None:
                        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cloud-emulator", action="store_true")
    parser.add_argument("--apk", type=Path, help="Omit only for actual Android boot preflight without gameplay")
    parser.add_argument("--package", default="org.aetherkiri.renpy.debug")
    parser.add_argument("--sdk-root", default=os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT", ""))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--boot-timeout", type=int, default=480)
    parser.add_argument("--gameplay-timeout", type=int, default=900)
    parser.add_argument("--stage-timeout", type=int, default=90)
    parser.add_argument("--port", type=int, default=5554)
    args = parser.parse_args()
    if not 60 <= args.boot_timeout <= 600 or not 60 <= args.gameplay_timeout <= 1200 \
            or not 5 <= args.stage_timeout <= 180 or not 5554 <= args.port <= 5682 or args.port % 2 \
            or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_.]+", args.package):
        parser.error("Invalid timeout, package, or even emulator port")
    def interrupted(signum, _frame):
        raise KeyboardInterrupt(f"Cloud emulator session interrupted by signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    session = Session(args)
    code = 0
    try:
        session.run()
    except (Unavailable, Failed, OSError, ValueError, KeyboardInterrupt, subprocess.TimeoutExpired) as exc:
        session.result.update(status="failed" if session.execution_started else "not_run", blocker=str(exc))
        code = 1 if session.execution_started else 2
    finally:
        try:
            session.stop(require_clean=False)
        except (Unavailable, OSError, subprocess.TimeoutExpired) as exc:
            session.result["status"] = "failed"
            session.result.setdefault("cleanup_error", bounded_diagnostic(str(exc), max_chars=1024, max_lines=4))
            code = 1
        (session.output / "result.json").write_text(json.dumps(session.result, indent=2) + "\n")
    print(json.dumps(session.result, indent=2))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
