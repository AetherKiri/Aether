#!/usr/bin/env python3
"""Exercise future iOS diagnostic boundaries with real host files/processes.

These are protocol, filesystem and process regressions. No Apple SDK, app
installation, native runtime, scene, input or gameplay is executed here.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import run_renpy_ios_device_acceptance as production


RUN_ID = "0123456789abcdef0123456789abcdef"
BUNDLE_ID = "org.aetherkiri.renpy-simulator.debug"
PRIVATE_CONTENT = "private-path-message-content-must-never-appear"


def row(seq=1, ticks=0, phase=None, **fields):
    return {"run_id": RUN_ID, "seq": seq, "ticks_msec": ticks,
            "phase": phase or production.STARTUP_PHASES[0], **fields}


def jsonl(rows):
    return b"".join(json.dumps(value).encode() + b"\n" for value in rows)


class StartupDiagnostics(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="aether-ios-startup-diagnostics-")
        self.root = Path(self.temporary.name)
        self.documents = self.root / "Documents"
        self.documents.mkdir()

    def tearDown(self):
        self.temporary.cleanup()

    def acceptance(self):
        args = argparse.Namespace(output_dir=self.root / "output", udid=None)
        acceptance = production.Acceptance(args)
        acceptance.run_id = RUN_ID
        acceptance.bundle_id = BUNDLE_ID
        acceptance.summary.update(run_id=RUN_ID, status="failed", blocker="original gameplay failure")
        return acceptance

    def write(self, label, contents):
        path = self.documents / production.DIAGNOSTIC_DOCUMENT_FILES[label]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)
        return path

    def test_producer_contract_and_all_phases(self):
        main = (Path(__file__).resolve().parents[1] / "apps/godot_app/scripts/main.gd").read_text()
        phases = re.search(r"const RENPY_STARTUP_PHASES := \[(.*?)\]", main, re.S)
        self.assertIsNotNone(phases)
        self.assertEqual(tuple(re.findall(r'"([a-z_]+)"', phases.group(1))), production.STARTUP_PHASES)
        self.assertIn("const RENPY_STARTUP_TRACE_MAX_TICKS := 9007199254740991", main)
        values = [row(seq=index + 1, ticks=index, phase=phase)
                  for index, phase in enumerate(production.STARTUP_PHASES)]
        values.append(row(seq=64, ticks=production.DIAGNOSTIC_MAX_TICKS,
                          result=2147483647))
        result = production.diagnostic_rows(jsonl(values), RUN_ID, startup=True)
        self.assertEqual(result["status"], "valid")
        self.assertEqual(result["rows"], values)
        self.assertFalse(any(result["violations"].values()))
        self.assertEqual(production.diagnostic_rows(jsonl([row(result=-2147483648)]), RUN_ID,
                                                   startup=True)["status"], "valid")

    def test_startup_schema_numeric_boundaries(self):
        cases = []
        for key, values in (
                ("seq", [0, 65, True, 1.0, "1", None]),
                ("ticks_msec", [-1, production.DIAGNOSTIC_MAX_TICKS + 1, True, 1.0, "1", None]),
                ("result", [-2147483649, 2147483648, True, 1.0, "1", None])):
            for value in values:
                cases.append({**row(), key: value})
        cases.extend([row(phase=PRIVATE_CONTENT), row(phase=[PRIVATE_CONTENT]),
                      {**row(), "message": PRIVATE_CONTENT}, {"run_id": RUN_ID},
                      [], "arbitrary-json-string"])
        for value in cases:
            with self.subTest(value=value):
                result = production.diagnostic_rows(jsonl([value]), RUN_ID, startup=True)
                self.assertEqual(result["status"], "partial")
                self.assertEqual(result["rows"], [])
                self.assertEqual(sum(result["violations"].values()), 1)
                self.assertNotIn(PRIVATE_CONTENT, json.dumps(result))

    def test_json_identity_and_complexity_boundaries(self):
        invalid = [b'{"run_id":"' + RUN_ID.encode() + b'","run_id":"' + RUN_ID.encode() + b'"}',
                   b'{"run_id":"' + RUN_ID.encode() + b'","nested":{"x":1,"x":2}}',
                   b'{"n":' + b'9' * 10000 + b'}', b'{"n":NaN}', b'{"n":Infinity}',
                   b'{"n":1e9999}', b'["\xff"]', b'not-json',
                   b'[' * 1500 + b'0' + b']' * 1500]
        for value in invalid:
            with self.subTest(bytes=len(value)):
                result = production.diagnostic_rows(value, RUN_ID, startup=True)
                self.assertEqual(result["violations"]["invalid_json"], 1)
                self.assertEqual(result["rows"], [])
        for identity in [None, 123, True, [], {}, "", RUN_ID.upper(), "g" * 32]:
            with self.subTest(identity=identity):
                result = production.diagnostic_rows(jsonl([row()]), identity, startup=True)
                self.assertEqual(result["status"], "invalid_identity")
                self.assertEqual(result["rows"], [])
        foreign = {**row(), "run_id": "f" * 32}
        result = production.diagnostic_rows(jsonl([foreign, row()]), RUN_ID, startup=True)
        self.assertEqual(result["violations"]["foreign_run"], 1)
        self.assertEqual(result["rows"], [row()])
        # The depth bound counts JSON structure, never characters in strings.
        private = {"run_id": RUN_ID, "kind": "opening", "message": '["\\' * 100}
        self.assertEqual(production.diagnostic_rows(jsonl([private]), RUN_ID)["status"], "valid")

    def test_order_record_and_byte_limits(self):
        values = [row(seq=2, ticks=20), row(seq=2, ticks=20), row(seq=3, ticks=19), row(seq=4, ticks=21)]
        result = production.diagnostic_rows(jsonl(values), RUN_ID, startup=True)
        self.assertEqual(result["violations"]["invalid_order"], 2)
        self.assertEqual(result["rows"], [values[0], values[3]])
        result = production.diagnostic_rows(jsonl([row()] * 65), RUN_ID, startup=True)
        self.assertEqual(result["status"], "record_limit")
        self.assertEqual(result["rows"], [])
        result = production.diagnostic_rows(b" " * (production.DIAGNOSTIC_MAX_BYTES + 1), RUN_ID,
                                            startup=True)
        self.assertEqual(result["violations"]["byte_limit"], 1)
        self.assertEqual(result["rows"], [])

    def test_real_file_metadata_and_bounded_reads(self):
        path = self.write("startup_trace", jsonl([row()]))
        relative = production.DIAGNOSTIC_DOCUMENT_FILES["startup_trace"]
        metadata, data = production.diagnostic_file(self.documents, relative, read=True)
        self.assertEqual(metadata, {"status": "regular", "exists": True, "bytes": path.stat().st_size})
        self.assertEqual(data, path.read_bytes())
        path.write_bytes(b"x" * production.DIAGNOSTIC_MAX_BYTES)
        self.assertEqual(len(production.diagnostic_file(self.documents, relative, read=True)[1]),
                         production.DIAGNOSTIC_MAX_BYTES)
        path.write_bytes(b"x" * (production.DIAGNOSTIC_MAX_BYTES + 1))
        metadata, data = production.diagnostic_file(self.documents, relative, read=True)
        self.assertEqual(metadata["status"], "byte_limit")
        self.assertIsNone(data)
        with mock.patch.object(production.os, "read", side_effect=AssertionError("metadata must not read")):
            metadata, data = production.diagnostic_file(self.documents, relative)
        self.assertEqual(metadata["status"], "regular")
        self.assertIsNone(data)
        self.assertEqual(production.diagnostic_file(self.documents, "missing")[0]["exists"], False)
        self.assertEqual(production.diagnostic_file(None, "missing")[0]["status"], "not_run")

    def test_real_symlinks_nonregular_and_paths_are_refused(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "secret").write_text(PRIVATE_CONTENT)
        for name, target in (("leaf", outside / "secret"), ("parent", outside)):
            (self.documents / name).symlink_to(target)
        for relative in ("leaf", "parent/secret"):
            metadata, data = production.diagnostic_file(self.documents, relative, read=True)
            self.assertEqual(metadata["status"], "link_or_directory_refused")
            self.assertIsNone(data)
        alias = self.root / "alias"
        alias.symlink_to(self.documents, target_is_directory=True)
        self.assertEqual(production.diagnostic_file(alias, "leaf", read=True)[0]["status"], "root_refused")
        # Normal host aliases above the selected Documents boundary remain valid.
        above = self.root / "above"
        above.symlink_to(self.root, target_is_directory=True)
        self.write("probe_request", b"safe")
        self.assertEqual(production.diagnostic_file(above / "Documents", "aetherkiri-probe-request.json",
                                                   read=True)[1], b"safe")
        directory = self.documents / "directory"
        directory.mkdir()
        os.mkfifo(self.documents / "fifo")
        for relative in ("directory", "fifo"):
            metadata, data = production.diagnostic_file(self.documents, relative, read=True)
            self.assertEqual(metadata["status"], "non_regular_refused")
            self.assertIsNone(data)
        for relative in ("../outside/secret", str(outside / "secret"), ""):
            self.assertEqual(production.diagnostic_file(self.documents, relative)[0]["status"], "path_refused")

    def test_root_swapped_to_real_symlink_between_lstat_and_open(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "secret").write_text(PRIVATE_CONTENT)
        original_resolve = Path.resolve

        def swap_on_parent_resolve(path, *args, **kwargs):
            if path == self.documents.parent:
                self.documents.rename(self.root / "original-documents")
                self.documents.symlink_to(outside, target_is_directory=True)
            return original_resolve(path, *args, **kwargs)

        with mock.patch.object(Path, "resolve", swap_on_parent_resolve):
            metadata, data = production.diagnostic_file(self.documents, "secret", read=True)
        self.assertEqual(metadata["status"], "link_or_directory_refused")
        self.assertIsNone(data)
        self.assertNotIn(PRIVATE_CONTENT, json.dumps(metadata))

    def test_snapshot_only_fixed_fields_counts_and_current_identity(self):
        acceptance = self.acceptance()
        acceptance.documents = self.documents
        # Gate flags here are fixture inputs, not evidence of an Apple install.
        acceptance.installed = acceptance.xcui_ready = acceptance.request_staged = True
        acceptance.install_elapsed_msec, acceptance.xcui_ready_elapsed_msec = 120, 240
        self.write("startup_trace", jsonl([row(), row(seq=2, ticks=1, result=-7)]))
        self.write("observer", jsonl([
            {"run_id": RUN_ID, "kind": "opening", "message": PRIVATE_CONTENT},
            {"run_id": RUN_ID, "kind": "failure", "message": PRIVATE_CONTENT},
            {"run_id": RUN_ID, "kind": PRIVATE_CONTENT},
            {"run_id": "f" * 32, "kind": "opening"}]))
        self.write("script_checkpoints", jsonl([
            {"run_id": RUN_ID, "source": "renpy-script", "stage": "start_ready", "details": PRIVATE_CONTENT},
            {"run_id": RUN_ID, "source": "host", "stage": "start_ready"},
            {"run_id": "f" * 32, "source": "renpy-script", "stage": "quit_requested"}]))
        self.write("device_request", PRIVATE_CONTENT.encode())
        for label in ("engine_log", "renpy_log", "renpy_traceback"):
            self.write(label, PRIVATE_CONTENT.encode())
        acceptance.snapshot_startup_diagnostics()
        report = acceptance.summary["startup_diagnostics"]
        self.assertTrue(report["install_passed"] and report["xcui_ready_passed"])
        self.assertEqual((report["install_elapsed_msec"], report["xcui_ready_elapsed_msec"]), (120, 240))
        self.assertEqual(report["startup_trace"]["records"], 2)
        self.assertEqual(report["observer"]["records"], 3)
        self.assertEqual(report["observer"]["kind_counts"]["failure"], 1)
        self.assertEqual(report["observer"]["unknown_kind_records"], 1)
        self.assertEqual(report["observer"]["violations"]["foreign_run"], 1)
        self.assertEqual(report["script_checkpoints"]["stage_counts"]["start_ready"], 1)
        self.assertEqual(report["script_checkpoints"]["unrecognized_records"], 1)
        self.assertFalse(report["probe_request_exists"])
        self.assertTrue(report["device_request_exists"])
        self.assertTrue(report["probe_request_absent_after_staging"])
        self.assertNotIn("consumed", json.dumps(report))
        self.assertNotIn(PRIVATE_CONTENT, json.dumps(report))
        self.assertNotIn(str(self.root), json.dumps(report))
        self.assertEqual(acceptance.summary["status"], "failed")
        self.assertEqual(acceptance.summary["checks"], [])
        self.assertEqual(acceptance.summary["blocker"], "original gameplay failure")

    def test_unavailable_and_all_read_exceptions_do_not_mask_failure(self):
        acceptance = self.acceptance()
        acceptance.snapshot_startup_diagnostics()
        self.assertEqual(acceptance.summary["startup_diagnostics"]["diagnostic_status"], "unavailable")
        self.assertFalse(acceptance.summary["startup_diagnostics"]["install_passed"])
        self.assertFalse(acceptance.summary["startup_diagnostics"]["xcui_ready_passed"])
        acceptance = self.acceptance()
        acceptance.documents = self.documents
        with mock.patch.object(production, "diagnostic_file", side_effect=RuntimeError(PRIVATE_CONTENT)):
            acceptance.snapshot_startup_diagnostics()
        report = acceptance.summary["startup_diagnostics"]
        self.assertEqual(report["read_errors"], len(production.DIAGNOSTIC_DOCUMENT_FILES))
        self.assertEqual(report["diagnostic_status"], "partial")
        self.assertNotIn(PRIVATE_CONTENT, json.dumps(report))
        acceptance = self.acceptance()
        with mock.patch.object(production, "diagnostic_rows", side_effect=RuntimeError(PRIVATE_CONTENT)):
            acceptance.snapshot_startup_diagnostics()
        self.assertEqual(acceptance.summary["startup_diagnostics"]["diagnostic_status"], "internal_error")
        self.assertNotIn(PRIVATE_CONTENT, json.dumps(acceptance.summary))
        self.assertEqual(acceptance.summary["status"], "failed")

    def test_real_live_process_is_snapshotted_before_cleanup_termination(self):
        acceptance = self.acceptance()
        process = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.buffer.read()"],
                                   stdin=subprocess.PIPE)
        acceptance.process = process
        try:
            acceptance.collect()
            report = acceptance.summary["startup_diagnostics"]
            self.assertEqual(report["test_process_before_cleanup"], {"state": "running", "returncode": None})
            self.assertIsNotNone(process.returncode)
            self.assertNotEqual(process.returncode, 0)
            # A repeated collection cannot replace the pre-cleanup observation
            # with the signal that this collector itself sent to the child.
            acceptance.collect()
            self.assertEqual(report["test_process_before_cleanup"]["state"], "running")
            self.assertEqual(acceptance.summary["status"], "failed")
            self.assertEqual(acceptance.summary["checks"], [])
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)
            process.stdin.close()

    def test_real_already_exited_process_and_poll_exception(self):
        for returncode in (0, 7):
            with self.subTest(returncode=returncode):
                acceptance = self.acceptance()
                acceptance.process = subprocess.Popen([sys.executable, "-c", f"raise SystemExit({returncode})"])
                acceptance.process.wait(timeout=10)
                acceptance.collect()
                self.assertEqual(acceptance.summary["startup_diagnostics"]["test_process_before_cleanup"],
                                 {"state": "exited", "returncode": returncode})
                self.assertEqual(acceptance.summary["status"], "failed")
        acceptance = self.acceptance()
        acceptance.process = mock.Mock()
        acceptance.process.poll.side_effect = OSError(PRIVATE_CONTENT)
        acceptance.snapshot_startup_diagnostics()
        report = acceptance.summary["startup_diagnostics"]
        self.assertEqual(report["test_process_before_cleanup"]["state"], "unavailable")
        self.assertEqual(report["read_errors"], 1)
        self.assertNotIn(PRIVATE_CONTENT, json.dumps(report))

    def test_actual_ready_requires_both_identities_and_boolean_true(self):
        ready = {"run_id": RUN_ID, "bundle_id": BUNDLE_ID, "ready": True}
        self.assertTrue(production.is_actual_xcui_ready(ready, RUN_ID, BUNDLE_ID))
        for value in [None, [], True, 1, {}, {**ready, "run_id": "f" * 32},
                      {**ready, "bundle_id": "another.app"}, {**ready, "ready": 1},
                      {**ready, "ready": "true"}, {"run_id": RUN_ID, "ready": True}]:
            with self.subTest(value=value):
                self.assertFalse(production.is_actual_xcui_ready(value, RUN_ID, BUNDLE_ID))


if __name__ == "__main__":
    unittest.main(verbosity=2)
