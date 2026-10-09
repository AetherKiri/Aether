#!/usr/bin/env python3
"""Validate acceleration/result boundaries and real subprocess cleanup.

No Android emulator, APK, Ren'Py provider or gameplay is executed by this test.
"""

import copy
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from run_renpy_android_emulator_session import (
    Session, Unavailable, acceleration_usable, gameplay_result_matches, owned_group_exists, terminate_owned_process,
)


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


if __name__ == "__main__":
    unittest.main()
