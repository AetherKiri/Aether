#!/usr/bin/env python3
"""Validate acceleration/result boundaries and real subprocess cleanup.

No Android emulator, APK, Ren'Py provider or gameplay is executed by this test.
"""

import copy
import hashlib
import io
import json
import os
import selectors
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import zlib
from pathlib import Path
from unittest.mock import patch

from run_renpy_android_emulator_session import (
    Session, Unavailable, acceleration_usable, bounded_diagnostic, diagnostic_file_tail,
    gameplay_result_matches, os_screen_stats, owned_group_exists, owned_group_state,
    terminate_owned_process, wait_owned_group_exit,
)
from run_renpy_android_device_acceptance import Failed, image_stats, png_pixels


def encoded_os_fixture(*, first: int = 0, second: int = 255, rgba: bool = False) -> bytes:
    """Encode real PNG bytes for a two-color OS boundary fixture, not gameplay."""
    channels = 4 if rgba else 3
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = b"".join(b"\0" + (bytes([first if y < 8 else second] * 3)
                                + (b"\xff" if rgba else b"")) * 64 for y in range(64))
    header = struct.pack(">IIBBBBB", 64, 64, 8, 6 if channels == 4 else 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


class OsScreenReadinessTests(unittest.TestCase):
    def session(self, temporary: str, *, apk: Path | None = None) -> Session:
        args = type("Args", (), {"output_dir": Path(temporary), "port": 5554, "apk": apk,
                                "cloud_emulator": True, "sdk_root": temporary})()
        session = Session(args)
        session.boot_started, session.next_boot_progress = 0, 0
        session.emulator_process = type("BoundaryProcess", (), {"poll": lambda _: None})()
        return session

    def test_real_two_color_png_is_os_ready_but_still_rejected_as_a_renpy_scene(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "two-color-os-fixture.png"
            for rgba in (False, True):
                path.write_bytes(encoded_os_fixture(rgba=rgba))
                image = png_pixels(path)
                stats = os_screen_stats(image)
                self.assertEqual((stats["width"], stats["height"], stats["sampled_colors"]), (64, 64, 2))
                self.assertEqual(stats["luma_range"], 255)
                self.assertTrue(stats["ready"])
                with self.assertRaisesRegex(Failed, "Ren'Py scene"):
                    image_stats(image)

    def test_real_uniform_and_low_contrast_pngs_are_not_os_ready(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "unready-os-fixture.png"
            for first, second in ((0, 0), (255, 255), (0, 39), (100, 139)):
                path.write_bytes(encoded_os_fixture(first=first, second=second))
                self.assertFalse(os_screen_stats(png_pixels(path))["ready"], (first, second))
            path.write_bytes(b"invalid PNG fixture")
            with self.assertRaisesRegex(Failed, "not a PNG"):
                png_pixels(path)
        with self.assertRaisesRegex(Failed, "dimensions or pixels"):
            os_screen_stats((64, 64, b"incomplete", 3))

    def test_normal_wakeup_precedes_menu_and_all_readiness_commands_share_the_original_deadline(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = self.session(temporary)
            calls = []
            properties = {"ro.build.fingerprint": "boundary-input-not-a-device",
                          "ro.product.cpu.abilist": "x86_64", "ro.build.version.sdk": "35",
                          "ro.opengles.version": str(0x30000)}
            def boundary_device(label, *parts, **kwargs):
                calls.append((label, parts, kwargs["timeout"]))
                if label.startswith("property-"):
                    output = properties[parts[-1]].encode()
                elif label == "surfaceflinger":
                    output = b"GLES: controlled input boundary\n"
                elif label == "screen-capture":
                    output = encoded_os_fixture()
                else:
                    output = b""
                return subprocess.CompletedProcess([label], 0, output)
            with patch.object(session, "device", side_effect=boundary_device), \
                    patch("run_renpy_android_emulator_session.time.monotonic", return_value=595), \
                    patch("sys.stdout", new_callable=io.StringIO):
                session.validate_booted_device(deadline=600)
            self.assertEqual(calls[0][:2], ("wakeup", ("shell", "input", "keyevent", "224")))
            self.assertEqual(calls[1][:2], ("unlock", ("shell", "input", "keyevent", "82")))
            self.assertTrue(all(timeout == 5 for _, _, timeout in calls))
            self.assertEqual(session.result["os_screen_attempts"], 1)
            self.assertTrue(session.result["actual_os_screen"]["ready"])
            self.assertFalse(session.result["gameplay_attempted"])
            self.assertFalse(session.result["harness_started"])

    def test_unready_frames_reach_original_deadline_without_more_commands_or_harness(self):
        # Controlled clock/ADB responses test orchestration only; no emulator runs.
        with tempfile.TemporaryDirectory() as temporary:
            apk = Path(temporary) / "boundary-only-not-an-apk"
            apk.write_bytes(b"boundary input")
            session = self.session(temporary, apk=apk)
            clock, calls = {"now": 595.0}, []
            def capture(label, *parts, **kwargs):
                self.assertLess(clock["now"], 600)
                calls.append(kwargs["timeout"])
                clock["now"] += 0.5
                return subprocess.CompletedProcess([label], 0, encoded_os_fixture(first=0, second=0))
            def boundary_boot(*_):
                session.execution_started = True
                session.result["boot_completed"] = True
                session.wait_os_screen(deadline=600)
            with patch.object(session, "gate_host", return_value=Path("boundary-emulator")), \
                    patch.object(session, "prepare_sdk", return_value=Path("boundary-manager")), \
                    patch.object(session, "boot", side_effect=boundary_boot), \
                    patch.object(session, "boot_failure_diagnostics"), patch.object(session, "stop"), \
                    patch.object(session, "gameplay") as harness, patch.object(session, "device", side_effect=capture), \
                    patch("run_renpy_android_emulator_session.time.monotonic", side_effect=lambda: clock["now"]), \
                    patch("run_renpy_android_emulator_session.time.sleep", side_effect=lambda seconds: clock.update(now=clock["now"] + seconds)), \
                    patch("sys.stdout", new_callable=io.StringIO):
                with self.assertRaisesRegex(Unavailable, "original boot deadline"):
                    session.run()
                harness.assert_not_called()
            self.assertEqual(clock["now"], 600)
            self.assertEqual(calls, [5, 2.5])
            self.assertEqual(session.result["os_screen_attempts"], 2)
            self.assertEqual(session.result["actual_os_screen"]["sampled_colors"], 1)
            self.assertFalse(session.result["actual_os_screen"]["ready"])
            self.assertEqual(session.result["gameplay_verification"], "not_run")
            self.assertFalse(session.result["gameplay_verified"])

    def test_os_frame_and_numeric_observations_are_retained_until_visible(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = self.session(temporary)
            clock = {"now": 590.0}
            frames = iter((encoded_os_fixture(first=0, second=0), encoded_os_fixture()))
            def capture(label, *parts, **kwargs):
                return subprocess.CompletedProcess([label], 0, next(frames))
            with patch.object(session, "device", side_effect=capture), \
                    patch("run_renpy_android_emulator_session.time.monotonic", side_effect=lambda: clock["now"]), \
                    patch("run_renpy_android_emulator_session.time.sleep", side_effect=lambda seconds: clock.update(now=clock["now"] + seconds)), \
                    patch("sys.stdout", new_callable=io.StringIO) as console:
                session.wait_os_screen(deadline=600)
            self.assertEqual([row["ready"] for row in session.result["os_screen_observations"]], [False, True])
            self.assertEqual([row["elapsed_seconds"] for row in session.result["os_screen_observations"]], [590, 592])
            self.assertEqual(session.result["os_screen_attempts"], 2)
            self.assertEqual((session.output / "actual-android-screen.png").read_bytes(), encoded_os_fixture())
            first = [json.loads(line) for line in console.getvalue().splitlines()
                     if "actual-android-first-os-screen" in line][0]
            self.assertFalse(first["ready"])
            self.assertEqual(first["sampled_colors"], 1)

    def test_ready_frame_cannot_pass_after_capture_exhausts_the_original_deadline(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = self.session(temporary)
            clock = {"now": 599.0}
            def capture(label, *parts, **kwargs):
                self.assertEqual(kwargs["timeout"], 1)
                clock["now"] = 600
                return subprocess.CompletedProcess([label], 0, encoded_os_fixture())
            with patch.object(session, "device", side_effect=capture) as command, \
                    patch("run_renpy_android_emulator_session.time.monotonic", side_effect=lambda: clock["now"]), \
                    patch("sys.stdout", new_callable=io.StringIO):
                with self.assertRaisesRegex(Unavailable, "original boot deadline"):
                    session.wait_os_screen(deadline=600)
            self.assertEqual(command.call_count, 1)
            self.assertTrue(session.result["actual_os_screen"]["ready"])
            self.assertNotEqual(session.result["boot_phase"], "validated-booted-device")

    def test_readiness_permission_or_invalid_png_failure_is_not_retried(self):
        with tempfile.TemporaryDirectory() as temporary:
            session = self.session(temporary)
            broken_compression = bytearray(encoded_os_fixture())
            broken_compression[41] = 0  # Real PNG IHDR, invalid zlib stream in IDAT.
            for failure, captured in ((Unavailable("screen-capture permission denied"), b""),
                                      (None, b"not a PNG"), (None, bytes(broken_compression))):
                with patch.object(session, "device", side_effect=failure,
                                  return_value=subprocess.CompletedProcess(["fixture"], 0, captured)) as command, \
                        patch("run_renpy_android_emulator_session.time.monotonic", return_value=590):
                    with self.assertRaises((Unavailable, Failed)):
                        session.wait_os_screen(deadline=600)
                    self.assertEqual(command.call_count, 1)
            with patch.object(session, "device", side_effect=AssertionError("Expired readiness must not call adb")), \
                    patch("run_renpy_android_emulator_session.time.monotonic", return_value=600):
                with self.assertRaisesRegex(Unavailable, "original boot deadline"):
                    session.boot_device("expired", "get-state", deadline=600)


class AccelerationBoundaryTests(unittest.TestCase):
    def test_google_macos_and_linux_reports_are_distinct(self):
        mac = "accel:\n0\nHypervisor.Framework OS X Version 15.7\naccel\n"
        linux = "accel:\n0\nKVM (version 12) is installed and usable.\naccel\n"
        self.assertTrue(acceleration_usable(mac, "Darwin"))
        self.assertTrue(acceleration_usable(linux, "Linux"))
        self.assertFalse(acceleration_usable(mac, "Linux"))
        self.assertFalse(acceleration_usable(linux, "Darwin"))

    def test_unavailable_and_malformed_hvf_reports_are_rejected(self):
        for description in ("HVF unusable", "HVF is not usable", "HVF is unsupported", "HVF is unavailable",
                            "HVF is not installed and usable", "WHPX is installed and usable"):
            self.assertFalse(acceleration_usable(f"accel:\n0\n{description}\naccel\n", "Darwin"), description)
        self.assertFalse(acceleration_usable("accel:\n1\nHypervisor.Framework OS X Version 15.7\naccel\n", "Darwin"))
        self.assertFalse(acceleration_usable("Hypervisor.Framework OS X Version 15.7\n", "Darwin"))

    def test_linux_kvm_permission_denial_stops_before_any_sdk_command(self):
        # Unit input boundary only: no KVM access or command is performed.
        session = object.__new__(Session)
        session.result = {"checks": []}
        with patch("run_renpy_android_emulator_session.platform.system", return_value="Linux"), \
                patch("run_renpy_android_emulator_session.platform.machine", return_value="x86_64"), \
                patch("run_renpy_android_emulator_session.os.access", return_value=False), \
                patch.object(session, "command", side_effect=AssertionError("SDK must not run")):
            with self.assertRaisesRegex(Unavailable, "no permissions were changed"):
                session.gate_host(Path("/not-a-sdk"))

    def test_arm_mac_stops_before_any_hypervisor_or_sdk_command(self):
        session = object.__new__(Session)
        session.result = {"checks": []}
        with patch("run_renpy_android_emulator_session.platform.system", return_value="Darwin"), \
                patch("run_renpy_android_emulator_session.platform.machine", return_value="arm64"), \
                patch.object(session, "command", side_effect=AssertionError("SDK must not run")):
            with self.assertRaisesRegex(Unavailable, "Intel macOS/HVF"):
                session.gate_host(Path("/not-a-sdk"))


class HarnessResultBoundaryTests(unittest.TestCase):
    def test_return_code_and_all_actual_result_identities_are_required(self):
        summary = {"status": "passed", "source": "actual-apk-adb-cloud-device", "serial": "emulator-5554",
                   "package": "org.aetherkiri.renpy.debug", "apk_sha256": "test-only-hash"}
        arguments = ("org.aetherkiri.renpy.debug", "emulator-5554", "test-only-hash")
        self.assertTrue(gameplay_result_matches(summary, 0, *arguments))
        self.assertFalse(gameplay_result_matches(summary, 1, *arguments))
        self.assertFalse(gameplay_result_matches([], 0, *arguments))
        for name in summary:
            wrong = copy.deepcopy(summary)
            wrong[name] = "different-test-input"
            self.assertFalse(gameplay_result_matches(wrong, 0, *arguments), name)


class CurrentDiagnosticBoundaryTests(unittest.TestCase):
    def test_sensitive_lines_are_removed_and_current_kernel_failure_is_retained(self):
        raw = ("\x1b[31mKernel panic: fixture boot evidence\x1b[0m\n"
               "Authorization: Bearer private-auth-value\naccess_token=private-token-value\n"
               "credential=private-credential-value\ngrpc server key=private-grpc-value\n"
               "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJzZWNyZXQifQ.privateJwtSignature\n"
               "Download https://example.invalid/private-url-value\n"
               "SystemServer: fixture service failed\n")
        result = bounded_diagnostic(raw)
        self.assertEqual(result["redacted_lines"], 6)
        self.assertIn("Kernel panic: fixture boot evidence", result["output"])
        self.assertIn("SystemServer: fixture service failed", result["output"])
        self.assertNotIn("\x1b", result["output"])
        for secret in ("private-", "eyJ", "example.invalid", "Bearer"):
            self.assertNotIn(secret, result["output"])

    def test_tail_limits_do_not_reveal_a_sensitive_line_with_its_header_cut_off(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "only-current-fixture.log"
            log.write_bytes(b"Authorization: " + b"fixture-private-secret" * 5000 + b"\nKernel panic: fixture\n")
            result = diagnostic_file_tail(log, read_limit=1024)
        self.assertTrue(result["truncated"])
        self.assertEqual(result["output"], "Kernel panic: fixture")
        limited = bounded_diagnostic("\n".join(str(i) + "x" * 800 for i in range(100)),
                                     max_chars=300, max_lines=3)
        self.assertLessEqual(len(limited["output"]), 300)
        self.assertLessEqual(len(limited["output"].splitlines()), 3)
        self.assertTrue(limited["truncated"])

    def test_real_ordinary_diagnostic_child_is_bounded_and_its_partial_output_redacted(self):
        # A real ordinary executable validates timeout/capture, not an Android SDK.
        with tempfile.TemporaryDirectory() as temporary:
            fixture = Path(temporary) / "controlled-diagnostic-process"
            fixture.write_text(f"#!{sys.executable}\nimport time\n"
                               "print('token=fixture-private-value', flush=True)\n"
                               "print('fixture-child-ready', flush=True)\ntime.sleep(60)\n")
            fixture.chmod(0o700)
            session = object.__new__(Session)
            session.adb = fixture
            session.environment = dict(os.environ)
            session.result = {"serial": "emulator-5554"}
            started = time.monotonic()
            result = session.diagnostic_command("get-state", timeout=1)
            self.assertLess(time.monotonic() - started, 4)
            self.assertTrue(result["timed_out"])
            self.assertIn("fixture-child-ready", result["output"])
            self.assertNotIn("fixture-private-value", result["output"])
            self.assertEqual(list(Path(temporary).iterdir()), [fixture], "No raw diagnostic log may be created")

    def test_progress_is_throttled_and_last_real_command_response_is_bounded(self):
        # Input/timing boundary only; no emulator is run.
        session = object.__new__(Session)
        session.boot_started, session.next_boot_progress = 100, 0
        session.result = {"serial": "emulator-5554"}
        process = subprocess.CompletedProcess(["fixture"], 0, b"fixture-response")
        with patch.object(session, "emulator_process", create=True) as emulator, \
                patch("run_renpy_android_emulator_session.time.monotonic",
                      side_effect=[100, 101, 129, 130, 159, 160]), patch("sys.stdout", new_callable=io.StringIO) as console:
            emulator.poll.return_value = None
            for _ in range(6):
                session.boot_progress("fixture-progress", response=process)
            rows = [json.loads(line) for line in console.getvalue().splitlines()]
        self.assertEqual([row["elapsed_seconds"] for row in rows], [0, 30, 60])
        self.assertEqual(session.result["last_boot_response"]["output"], "fixture-response")
        self.assertTrue(all(row["gameplay_verification"] == "not_run" for row in rows))

    def test_boot_failure_diagnostics_precede_stop_and_do_not_mask_original_failure(self):
        # Control-flow boundary only; no SDK, AVD or device command is executed.
        with tempfile.TemporaryDirectory() as temporary:
            args = type("Args", (), {"output_dir": Path(temporary), "port": 5554, "apk": None,
                                    "cloud_emulator": True, "sdk_root": temporary})()
            session = Session(args)
            events = []
            def fail_boot(*_):
                session.execution_started = True
                raise Unavailable("fixture original boot failure")
            def fail_diagnostics():
                events.append("diagnostics-before-stop")
                raise OSError("token=fixture-secret")
            with patch.object(session, "gate_host", return_value=Path("fixture-emulator")), \
                    patch.object(session, "prepare_sdk", return_value=Path("fixture-manager")), \
                    patch.object(session, "boot", side_effect=fail_boot), \
                    patch.object(session, "boot_failure_diagnostics", side_effect=fail_diagnostics), \
                    patch.object(session, "stop", side_effect=lambda **_: events.append("stop")):
                with self.assertRaisesRegex(Unavailable, "fixture original boot failure"):
                    session.run()
            self.assertEqual(events, ["diagnostics-before-stop", "stop"])
            self.assertTrue(session.result["boot_failed"])
            self.assertEqual(session.result["gameplay_verification"], "not_run")
            self.assertNotIn("fixture-secret", session.result["boot_failure_diagnostic_error"]["output"])

    def test_boot_failure_and_cleanup_denial_are_preserved_separately(self):
        with tempfile.TemporaryDirectory() as temporary:
            args = type("Args", (), {"output_dir": Path(temporary), "port": 5554, "apk": None,
                                    "cloud_emulator": True, "sdk_root": temporary})()
            session = Session(args)
            events = []
            def fail_boot(*_):
                session.execution_started = True
                raise Unavailable("fixture original boot failure")
            def fail_cleanup(**_):
                events.append("stop")
                raise PermissionError("fixture cleanup permission denied")
            with patch.object(session, "gate_host", return_value=Path("fixture-emulator")), \
                    patch.object(session, "prepare_sdk", return_value=Path("fixture-manager")), \
                    patch.object(session, "boot", side_effect=fail_boot), \
                    patch.object(session, "boot_failure_diagnostics", side_effect=lambda: events.append("diagnostics")), \
                    patch.object(session, "stop", side_effect=fail_cleanup):
                with self.assertRaisesRegex(Unavailable, "fixture original boot failure"):
                    session.run()
            self.assertEqual(events, ["diagnostics", "stop"])
            self.assertEqual(session.result["boot_failure"]["output"], "fixture original boot failure")
            self.assertEqual(session.result["cleanup_error"]["output"], "fixture cleanup permission denied")
            self.assertEqual(session.result["status"], "failed")
            self.assertEqual(session.result["gameplay_verification"], "not_run")

    def test_cleanup_failure_without_primary_still_fails_the_session(self):
        with tempfile.TemporaryDirectory() as temporary:
            args = type("Args", (), {"output_dir": Path(temporary), "port": 5554, "apk": None,
                                    "cloud_emulator": True, "sdk_root": temporary})()
            session = Session(args)
            with patch.object(session, "gate_host", return_value=Path("fixture-emulator")), \
                    patch.object(session, "prepare_sdk", return_value=Path("fixture-manager")), \
                    patch.object(session, "boot"), \
                    patch.object(session, "stop", side_effect=[None, PermissionError("fixture cleanup permission denied")]):
                with self.assertRaisesRegex(PermissionError, "fixture cleanup permission denied"):
                    session.run()
            self.assertEqual(session.result["status"], "failed")
            self.assertEqual(session.result["cleanup_error"]["output"], "fixture cleanup permission denied")


class RealProcessCleanupTests(unittest.TestCase):
    def start(self, ignore_term=False):
        code = "import signal,time; "
        if ignore_term:
            code += "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        code += "print('ready', flush=True); time.sleep(120)"
        process = subprocess.Popen([sys.executable, "-u", "-c", code], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        self.addCleanup(self.cleanup, process)
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(timeout=5), "Real child did not become ready")
            self.assertEqual(process.stdout.readline().strip(), b"ready")
        return process

    @staticmethod
    def cleanup(process):
        if process.poll() is None or owned_group_exists(process):
            terminate_owned_process(process, grace=0.1)
        if process.stdout:
            process.stdout.close()

    def assert_reaped(self, process):
        self.assertIsNotNone(process.poll())
        with self.assertRaises(ProcessLookupError):
            os.kill(process.pid, 0)

    def test_term_stops_and_reaps_an_actual_owned_child(self):
        process = self.start()
        self.assertEqual(terminate_owned_process(process, grace=2), -signal.SIGTERM)
        self.assert_reaped(process)

    def test_term_ignoring_actual_child_is_killed_after_deadline_and_reaped(self):
        process = self.start(ignore_term=True)
        self.assertEqual(terminate_owned_process(process, grace=0.1), -signal.SIGKILL)
        self.assert_reaped(process)

    def start_with_grandchild(self, exit_leader=False):
        temporary = tempfile.TemporaryDirectory(prefix="owned-process-grandchild-")
        self.addCleanup(temporary.cleanup)
        pid_file = Path(temporary.name) / "child.pid"
        child_code = ("import os,signal,sys,time; from pathlib import Path; "
                      "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                      "Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(120)")
        leader_code = ("import subprocess,sys,time; from pathlib import Path; "
                       f"child=subprocess.Popen([sys.executable,'-c',{child_code!r},{str(pid_file)!r}]); "
                       "deadline=time.monotonic()+5\n"
                       f"while not Path({str(pid_file)!r}).exists() and time.monotonic()<deadline: time.sleep(0.01)\n"
                       "print('ready',flush=True)\n" + ("sys.exit(0)\n" if exit_leader else "time.sleep(120)\n"))
        process = subprocess.Popen([sys.executable, "-u", "-c", leader_code], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        self.addCleanup(self.cleanup, process)
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(timeout=6), "Actual leader/grandchild did not become ready")
            self.assertEqual(process.stdout.readline().strip(), b"ready")
        child_pid = int(pid_file.read_text())
        self.assertEqual(os.getpgid(child_pid), process.pid)
        return process, child_pid

    def assert_descendant_cannot_run(self, pid):
        # Orphaned grandchildren cannot be waitpid()'d by this test. Linux
        # container PID1 may retain their zombies; a zombie cannot execute.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            state = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True,
                                   text=True, timeout=2).stdout.strip()
            if not state or state.startswith("Z"):
                return
            time.sleep(0.05)
        self.fail(f"Actual owned grandchild {pid} is still runnable (state {state!r})")

    def test_term_exiting_leader_does_not_leave_term_ignoring_grandchild_running(self):
        process, child_pid = self.start_with_grandchild()
        self.assertEqual(terminate_owned_process(process, grace=0.1), -signal.SIGTERM)
        self.assert_reaped(process)
        self.assert_descendant_cannot_run(child_pid)

    def test_already_exited_leader_does_not_skip_remaining_owned_group(self):
        process, child_pid = self.start_with_grandchild(exit_leader=True)
        self.assertEqual(process.wait(timeout=2), 0)
        self.assertTrue(owned_group_exists(process), "Actual grandchild must still own the original PGID")
        self.assertEqual(terminate_owned_process(process, grace=0.1), 0)
        self.assert_reaped(process)
        self.assert_descendant_cannot_run(child_pid)

    def test_session_stop_refuses_clean_status_with_already_exited_leader_and_live_group(self):
        process, child_pid = self.start_with_grandchild(exit_leader=True)
        self.assertEqual(process.wait(timeout=2), 0)
        session = object.__new__(Session)
        session.emulator_process, session.emulator_log, session.result = process, None, {}
        with patch.object(session, "device", side_effect=AssertionError("No Android command belongs in this process test")):
            with self.assertRaisesRegex(Unavailable, "did not stop cleanly"):
                session.stop(require_clean=True)
        self.assertTrue(session.result["emulator_forced_cleanup"])
        self.assertFalse(session.result["emulator_stopped_cleanly"])
        self.assert_reaped(process)
        self.assert_descendant_cannot_run(child_pid)

    def exited_child(self):
        process = subprocess.Popen([sys.executable, "-c", "pass"], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.addCleanup(self.cleanup, process)
        self.assertEqual(process.wait(timeout=5), 0)
        return process

    def test_eperm_probe_is_unknown_and_not_retried_or_signalled(self):
        process = self.exited_child()
        with patch("run_renpy_android_emulator_session.os.killpg", side_effect=PermissionError("fixture EPERM")) as probe:
            self.assertEqual(owned_group_state(process), "permission_denied")
            self.assertTrue(owned_group_exists(process), "Unknown may not be treated as absent")
            self.assertFalse(wait_owned_group_exit(process, 0.1))
            self.assertEqual(terminate_owned_process(process, grace=0.1), 0)
            probe.assert_called_once_with(process.pid, 0)
        self.assert_reaped(process)

    def test_denied_term_signal_is_not_retried_with_kill(self):
        process = self.exited_child()
        def signal_boundary(_pgid, signum):
            if signum:
                raise PermissionError("fixture signal EPERM")
        with patch("run_renpy_android_emulator_session.os.killpg", side_effect=signal_boundary) as probe:
            self.assertEqual(terminate_owned_process(process, grace=0.1), 0)
            self.assertEqual(owned_group_state(process), "permission_denied")
            self.assertEqual([call.args[1] for call in probe.call_args_list], [0, signal.SIGTERM])
        self.assert_reaped(process)

    def test_actual_caller_cannot_report_clean_when_group_probe_permission_is_unknown(self):
        process = self.exited_child()
        session = object.__new__(Session)
        session.emulator_process, session.emulator_log = process, None
        session.result = {"blocker": "fixture original boot failure", "gameplay_verification": "not_run"}
        with patch("run_renpy_android_emulator_session.os.killpg", side_effect=PermissionError("fixture EPERM")) as probe:
            with self.assertRaisesRegex(Unavailable, "did not stop cleanly"):
                session.stop(require_clean=True)
            probe.assert_called_once_with(process.pid, 0)
        self.assertFalse(session.result["emulator_stopped_cleanly"])
        self.assertTrue(session.result["emulator_cleanup_permission_denied"])
        self.assertEqual(session.result["emulator_group_state"], "permission_denied")
        self.assertEqual(session.result["blocker"], "fixture original boot failure")
        self.assertEqual(session.result["gameplay_verification"], "not_run")
        self.assert_reaped(process)

    def test_final_unknown_harness_group_cannot_be_upgraded_by_a_passing_summary_fixture(self):
        # Exercise the real caller with an ordinary exited child and local input
        # fixtures only. No APK, Android SDK or gameplay harness is executed.
        process = self.exited_child()
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            apk_fixture = output / "not-an-apk"
            apk_fixture.write_bytes(b"controlled input boundary fixture, not an APK")
            gameplay = output / "gameplay"
            gameplay.mkdir()
            summary = {"status": "passed", "source": "actual-apk-adb-cloud-device", "serial": "emulator-5554",
                       "package": "org.aetherkiri.renpy.debug", "apk_sha256": hashlib.sha256(apk_fixture.read_bytes()).hexdigest()}
            (gameplay / "result.json").write_text(json.dumps(summary))
            args = type("Args", (), {"output_dir": output, "port": 5554, "apk": apk_fixture,
                                    "package": summary["package"], "stage_timeout": 90, "gameplay_timeout": 900})()
            session = Session(args)
            session.adb = Path("no-sdk-executed")
            with patch("run_renpy_android_emulator_session.subprocess.Popen", return_value=process), \
                    patch("run_renpy_android_emulator_session.owned_group_state",
                          side_effect=["absent", "permission_denied"]), patch("sys.stdout", new_callable=io.StringIO):
                with self.assertRaisesRegex(Unavailable, "not confirmed absent"):
                    session.gameplay()
            self.assertTrue(session.result["harness_cleanup_permission_denied"])
            self.assertEqual(session.result["gameplay_verification"], "failed")
            self.assertFalse(session.result["gameplay_verified"])
            self.assertNotIn("gameplay_result", session.result, "Unknown cleanup must stop acceptance before reading the summary")
            self.assertEqual(json.loads((gameplay / "result.json").read_text()), summary)
        self.assert_reaped(process)


if __name__ == "__main__":
    unittest.main()
