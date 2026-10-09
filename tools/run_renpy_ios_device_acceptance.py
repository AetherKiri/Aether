#!/usr/bin/env python3
"""Install a real Ren'Py Godot app and exercise gameplay on a cloud iOS Simulator.

XCUITest supplies real touches, keyboard text, Home and foreground transitions.
Passing requires native frames visible in OS screenshots, real Ren'Py script
checkpoints, native pause/resume and normal game exit to the real library. Missing Apple
tools/app/runtime reports not_run (2); incomplete execution reports failed (1).
"""

from __future__ import annotations

import argparse
import copy
import errno
import hashlib
import json
import math
import os
import platform
import plistlib
import re
import shutil
import stat
import subprocess
import time
import uuid
from pathlib import Path

from run_renpy_android_device_acceptance import (
    Blocked, Failed, checkpoint_landmarks, image_stats, is_script_checkpoint, is_successful_os_return, pixel, png_pixels,
    read_engine_log_file, require_engine_log, require_landmark_pixels, verify_landmark_pixels, verify_resumed_marker,
)


DIAGNOSTIC_MAX_BYTES = 24 * 1024
DIAGNOSTIC_MAX_RECORDS = 64
DIAGNOSTIC_MAX_JSON_DEPTH = 16
DIAGNOSTIC_MAX_TICKS = (1 << 53) - 1
STARTUP_PHASES = (
    "main_ready_entered", "ui_build_entered", "ui_build_ready",
    "player_create_entered", "player_create_ready", "player_create_failed",
    "ready_frame_pending", "ready_frame_entered", "engine_initialize_entered",
    "engine_initialize_ready", "engine_initialize_failed", "observer_create_entered",
    "observer_create_ready", "observer_start_entered", "observer_start_returned",
)
CHECKPOINT_STAGES = (
    "start_ready", "touch_received", "text_ready", "text_received",
    "post_text_ready", "resumed_touch_received", "quit_ready", "quit_requested",
)
OBSERVER_KINDS = (
    "opening", "startup", "lifecycle", "os_touch", "os_mouse", "os_key",
    "soft_keyboard", "soft_keyboard_visibility", "checkpoint_seen",
    "provider_frame", "normal_exit", "library_return", "failure",
)
DIAGNOSTIC_DOCUMENT_FILES = {
    "startup_trace": "renpy-device-evidence/startup.jsonl",
    "observer": "renpy-device-evidence/observer.jsonl",
    "script_checkpoints": "renpy-device-demo/game/aether-device-checkpoints.jsonl",
    "probe_request": "aetherkiri-probe-request.json",
    "device_request": "renpy-device-demo/game/aether-device-request.json",
    "engine_log": "renpy-device-demo/aetherkiri-engine.log",
    "renpy_log": "renpy-device-demo/log.txt",
    "renpy_traceback": "renpy-device-demo/traceback.txt",
}


def is_actual_xcui_ready(value: object, run_id: str, bundle_id: str) -> bool:
    return (isinstance(value, dict) and value.get("run_id") == run_id
            and value.get("bundle_id") == bundle_id and value.get("ready") is True)


def documents_identity(documents: Path) -> tuple[Path, int, int]:
    """Identify the actual selected directory; publish no paths or inode data."""
    if not documents.is_absolute():
        raise ValueError("Actual app Documents identity requires an absolute container path")
    parent_fd = directory_fd = None
    try:
        parent = documents.parent.resolve(strict=True)
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        parent_fd = os.open(parent, flags)
        directory_fd = os.open(documents.name, flags, dir_fd=parent_fd)
        info = os.fstat(directory_fd)
        return parent / documents.name, info.st_dev, info.st_ino
    finally:
        if directory_fd is not None:
            os.close(directory_fd)
        if parent_fd is not None:
            os.close(parent_fd)


def diagnostic_file(root: Path | None, relative: str, *, read: bool = False) -> tuple[dict, bytes | None]:
    """Read fixed caller-selected files without following child symlinks.

    Metadata contains no paths, exceptions or contents. Reads have a 24 KiB
    ceiling; ordinary logs are statted only, never decoded or printed here.
    """
    metadata = {"status": "not_run", "exists": None, "bytes": None}
    if root is None:
        return metadata, None
    parent_fd = directory_fd = file_fd = None
    try:
        root_stat = root.lstat()
        if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
            metadata["status"] = "root_refused"
            return metadata, None
        parts = Path(relative).parts
        if not parts or Path(relative).is_absolute() or any(part in (".", "..") for part in parts):
            metadata["status"] = "path_refused"
            return metadata, None
        # Canonicalize normal host aliases above the selected Documents root.
        # Hold directory descriptors for every component below that boundary.
        directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        # Resolve aliases above Documents only. Opening the selected root's
        # basename through a held parent descriptor atomically refuses a root
        # swapped to a symlink after the preliminary lstat.
        parent_fd = os.open(root.parent.resolve(strict=True), directory_flags)
        directory_fd = os.open(root.name, directory_flags, dir_fd=parent_fd)
        os.close(parent_fd)
        parent_fd = None
        for part in parts[:-1]:
            child_fd = os.open(part, directory_flags, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = child_fd
        file_fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                          dir_fd=directory_fd)
        file_stat = os.fstat(file_fd)
        metadata["exists"] = True
        if not stat.S_ISREG(file_stat.st_mode):
            metadata["status"] = "non_regular_refused"
            return metadata, None
        if not 0 <= file_stat.st_size <= (1 << 63) - 1:
            metadata["status"] = "invalid_metadata"
            return metadata, None
        metadata.update(status="regular", bytes=file_stat.st_size)
        if not read:
            return metadata, None
        if file_stat.st_size > DIAGNOSTIC_MAX_BYTES:
            metadata["status"] = "byte_limit"
            return metadata, None
        data = bytearray()
        while len(data) < DIAGNOSTIC_MAX_BYTES:
            chunk = os.read(file_fd, DIAGNOSTIC_MAX_BYTES - len(data))
            if not chunk:
                break
            data.extend(chunk)
        if os.fstat(file_fd).st_size > DIAGNOSTIC_MAX_BYTES:
            metadata["status"] = "byte_limit"
            return metadata, None
        return metadata, bytes(data)
    except FileNotFoundError:
        metadata.update(status="missing", exists=False)
    except OSError as exc:
        metadata["status"] = ("link_or_directory_refused" if exc.errno in (errno.ELOOP, errno.ENOTDIR)
                              else "read_error")
    except (ValueError, RuntimeError):
        metadata["status"] = "read_error"
    finally:
        if file_fd is not None:
            os.close(file_fd)
        if directory_fd is not None:
            os.close(directory_fd)
        if parent_fd is not None:
            os.close(parent_fd)
    return metadata, None


def _diagnostic_object(pairs: list[tuple]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_key")
        result[key] = value
    return result


def _diagnostic_integer(value: str) -> int:
    if len(value.lstrip("-")) > 16:
        raise ValueError("integer_limit")
    result = int(value)
    if abs(result) > DIAGNOSTIC_MAX_TICKS:
        raise ValueError("integer_limit")
    return result


def _diagnostic_float(value: str) -> float:
    result = float(value)
    if not math.isfinite(result):
        raise ValueError("non_finite_number")
    return result


def _diagnostic_constant(value: str):
    raise ValueError("non_json_constant")


def _diagnostic_depth(data: bytes) -> None:
    # Bound decoder nesting independently of Python's implementation/version.
    # Ignore structural characters in JSON strings, including escaped quotes.
    depth, quoted, escaped = 0, False, False
    for byte in data:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (91, 123):
            depth += 1
            if depth > DIAGNOSTIC_MAX_JSON_DEPTH:
                raise ValueError("nesting_limit")
        elif byte in (93, 125):
            depth -= 1


def diagnostic_rows(data: bytes | None, run_id: str, *, startup: bool = False) -> dict:
    """Expose strict startup fields; other journal rows stay private for counts."""
    report = {"status": "unavailable", "rows": [], "violations": {
        "invalid_json": 0, "foreign_run": 0, "invalid_schema": 0,
        "invalid_order": 0, "record_limit": 0, "byte_limit": 0}}
    if data is None:
        return report
    if len(data) > DIAGNOSTIC_MAX_BYTES:
        report["status"] = "byte_limit"
        report["violations"]["byte_limit"] = 1
        return report
    lines = [line for line in data.splitlines() if line.strip()]
    if len(lines) > DIAGNOSTIC_MAX_RECORDS:
        report["status"] = "record_limit"
        report["violations"]["record_limit"] = 1
        return report
    if type(run_id) is not str or not re.fullmatch(r"[0-9a-f]{32}", run_id):
        report["status"] = "invalid_identity"
        report["violations"]["invalid_schema"] = 1
        return report
    last_seq, last_ticks = 0, 0
    for line in lines:
        try:
            _diagnostic_depth(line)
            row = json.loads(line.decode("utf-8"), object_pairs_hook=_diagnostic_object,
                             parse_int=_diagnostic_integer, parse_float=_diagnostic_float,
                             parse_constant=_diagnostic_constant)
        except (ValueError, UnicodeError, RecursionError, OverflowError):
            report["violations"]["invalid_json"] += 1
            continue
        if not isinstance(row, dict):
            report["violations"]["invalid_schema"] += 1
            continue
        if row.get("run_id") != run_id:
            report["violations"]["foreign_run"] += 1
            continue
        if startup:
            required = {"run_id", "seq", "ticks_msec", "phase"}
            seq, ticks, result = row.get("seq"), row.get("ticks_msec"), row.get("result")
            if (not required.issubset(row) or not set(row).issubset(required | {"result"})
                    or row.get("phase") not in STARTUP_PHASES
                    or type(seq) is not int or not 1 <= seq <= DIAGNOSTIC_MAX_RECORDS
                    or type(ticks) is not int or not 0 <= ticks <= DIAGNOSTIC_MAX_TICKS
                    or ("result" in row and (type(result) is not int or not -(1 << 31) <= result < (1 << 31)))):
                report["violations"]["invalid_schema"] += 1
                continue
            if seq <= last_seq or ticks < last_ticks:
                report["violations"]["invalid_order"] += 1
                continue
            last_seq, last_ticks = seq, ticks
        report["rows"].append(row)
    report["status"] = "partial" if any(report["violations"].values()) else "valid"
    return report


def configure_destination_artifacts(configuration: dict, test_root: Path, runner_app: Path,
                                    bundle_id: str, run_id: str, overall_timeout: int) -> tuple[dict, str]:
    """Bind a genuine built UI runner for the documented preinstalled mode.

    xcodebuild.xctestrun(5), UseDestinationArtifacts: exclude host artifact
    paths and supply destination bundle identities plus the installed test
    bundle path. __TESTHOST__/__TESTBUNDLE__ must remain device placeholders.
    This configuration validation does not prove Apple test execution.
    """
    if (not isinstance(configuration, dict)
            or not isinstance(bundle_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,254}", bundle_id)
            or not isinstance(run_id, str) or not re.fullmatch(r"[0-9a-f]{32}", run_id)
            or type(overall_timeout) is not int or not 60 <= overall_timeout <= 1200):
        raise Failed("Invalid actual UI destination configuration identity")
    metadata = configuration.get("__xctestrun_metadata__")
    if metadata is not None and (not isinstance(metadata, dict)
                                 or type(metadata.get("FormatVersion")) is not int
                                 or metadata["FormatVersion"] not in (1, 2)):
        raise Failed("Unsupported actual UI test configuration format")
    if runner_app.is_symlink() or not runner_app.is_dir() or runner_app.suffix != ".app":
        raise Failed("The built UI runner must be a real application directory")
    runner = runner_app.resolve(strict=True)
    info_path = runner / "Info.plist"
    if info_path.is_symlink() or not info_path.is_file():
        raise Failed("The built UI runner lacks its actual bundle metadata")
    runner_info = plistlib.loads(info_path.read_bytes())
    runner_id = runner_info.get("CFBundleIdentifier")
    runner_platforms = runner_info.get("CFBundleSupportedPlatforms")
    if (not isinstance(runner_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,254}", runner_id)
            or runner_id == bundle_id or not isinstance(runner_platforms, list)
            or "iPhoneSimulator" not in runner_platforms):
        raise Failed("The built UI runner lacks a real Simulator bundle identity")
    result = copy.deepcopy(configuration)
    targets = []

    def find_targets(value):
        if isinstance(value, dict):
            if "TestBundlePath" in value or "TestBundleDestinationRelativePath" in value:
                targets.append(value)
            else:
                for child in value.values():
                    find_targets(child)
        elif isinstance(value, list):
            for child in value:
                find_targets(child)

    find_targets(result)
    if len(targets) != 1 or targets[0].get("IsUITestBundle") is not True:
        raise Failed("The actual configuration must contain exactly one UI test target")
    target = targets[0]
    environment = target.get("TestingEnvironmentVariables")
    if (not isinstance(environment, dict)
            or any(not isinstance(key, str) or not isinstance(value, str) for key, value in environment.items())):
        raise Failed("The actual UI target lacks its required testing environment")

    def artifact_path(value, *, allow_test_host=False):
        if not isinstance(value, str) or not value or "\0" in value:
            raise Failed("The actual UI target lacks a valid build artifact path")
        expanded = value.replace("__TESTROOT__", str(test_root.resolve(strict=True)))
        if allow_test_host:
            expanded = expanded.replace("__TESTHOST__", str(runner))
        path = Path(expanded)
        if (re.search(r"__[A-Z0-9_]+__", expanded) or not path.is_absolute()
                or ".." in path.parts):
            raise Failed("The actual UI target has an unsupported build artifact path")
        return path

    host = artifact_path(target.get("TestHostPath")).resolve(strict=True)
    if host != runner or ("TestHostBundleIdentifier" in target
                          and target["TestHostBundleIdentifier"] != runner_id):
        raise Failed("The actual UI test host does not match the selected built runner")
    original_bundle = artifact_path(target.get("TestBundlePath"), allow_test_host=True)
    test_bundle = original_bundle.resolve(strict=True)
    try:
        relative = test_bundle.relative_to(runner)
    except ValueError as exc:
        raise Failed("The actual test bundle is outside its installed UI runner") from exc
    if (len(relative.parts) < 2 or relative.parts[0] != "PlugIns"
            or test_bundle.suffix != ".xctest" or not test_bundle.is_dir()):
        raise Failed("The actual UI test bundle must be embedded in its runner PlugIns")
    # Reject links within the installed bundle. Host filesystem aliases above
    # the application directory were canonicalized separately.
    original_host = next((parent for parent in original_bundle.parents
                          if parent.resolve(strict=True) == runner), None)
    if original_host is None or original_host.is_symlink():
        raise Failed("The actual test bundle is not a direct descendant of its built runner")
    component = original_host
    for part in original_bundle.relative_to(original_host).parts:
        component = component / part
        if component.is_symlink():
            raise Failed("The actual installed test bundle cannot traverse a symlink")
    bundle_info = test_bundle / "Info.plist"
    if bundle_info.is_symlink() or not bundle_info.is_file():
        raise Failed("The actual embedded UI test bundle lacks its bundle metadata")
    test_bundle_id = plistlib.loads(bundle_info.read_bytes()).get("CFBundleIdentifier")
    if not isinstance(test_bundle_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,254}", test_bundle_id):
        raise Failed("The actual embedded UI test bundle lacks its bundle identity")
    target.update(UseDestinationArtifacts=True, TestHostBundleIdentifier=runner_id,
                  TestBundleDestinationRelativePath="__TESTHOST__/" + relative.as_posix(),
                  UITargetAppBundleIdentifier=bundle_id)
    launch_environment = target.setdefault("EnvironmentVariables", {})
    if (not isinstance(launch_environment, dict)
            or any(not isinstance(key, str) or not isinstance(value, str) for key, value in launch_environment.items())):
        raise Failed("The actual UI target has an invalid launch environment")
    launch_environment.update({
        "AETHER_RENPY_RUN_ID": run_id, "AETHER_RENPY_APP_BUNDLE_ID": bundle_id,
        "AETHER_RENPY_TEST_TIMEOUT": str(overall_timeout)})
    for key in ("TestBundlePath", "TestHostPath", "UITargetAppPath", "DependentProductPaths"):
        target.pop(key, None)

    def relocate_test_root(value):
        if isinstance(value, dict):
            return {key: relocate_test_root(child) for key, child in value.items()}
        if isinstance(value, list):
            return [relocate_test_root(child) for child in value]
        if isinstance(value, str):
            return value.replace("__TESTROOT__", str(test_root.resolve(strict=True)))
        return value

    return relocate_test_root(result), runner_id


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
        self.staged_documents_identity: tuple[Path, int, int] | None = None
        self.container_identity_checked = False
        self.container_identity_same: bool | None = None
        self.ui_root: Path | None = None
        self.sequence = 0
        self.process: subprocess.Popen | None = None
        self.process_log = None
        self.prepared_xctestrun: Path | None = None
        self.ui_runner_id = ""
        self.test_artifact_mode = "not_prepared"
        self.runner_installed = self.destination_bindings_verified = False
        self.deadline = 0.0
        self.waiting_marker = None
        self.keyboard_preference: str | None = None
        self.preference_changed = False
        self.started_monotonic = time.monotonic()
        self.request_staged = self.xcui_ready = False
        self.install_elapsed_msec = self.xcui_ready_elapsed_msec = None
        self.diagnostics_collected = False
        self.summary = {"status": "not_run", "run_id": self.run_id,
                        "source": "actual-godot-app-simctl-xcuitest-cloud-simulator",
                        "checks": [], "blocker": ""}
        self.summary["startup_diagnostics"] = self.startup_gate_diagnostics()

    def elapsed_msec(self) -> int:
        return max(0, min(DIAGNOSTIC_MAX_TICKS,
                          int((time.monotonic() - self.started_monotonic) * 1000)))

    def startup_gate_diagnostics(self) -> dict:
        return {"schema_version": 1, "diagnostic_status": "not_collected",
                "install_passed": self.installed, "install_elapsed_msec": self.install_elapsed_msec,
                "xcui_ready_passed": self.xcui_ready, "xcui_ready_elapsed_msec": self.xcui_ready_elapsed_msec,
                "request_staged": self.request_staged,
                "test_artifact_mode": self.test_artifact_mode,
                "runner_install_passed": self.runner_installed,
                "destination_bindings_verified": self.destination_bindings_verified,
                "container_identity_checked": self.container_identity_checked,
                "container_identity_same": self.container_identity_same}

    def snapshot_startup_diagnostics(self) -> None:
        """Collect fixed same-run facts before cleanup; never change acceptance.

        Only strict startup rows are exposed. Other journals supply counts,
        ordinary logs supply metadata, and missing request files prove absence
        only (not which component removed them). Diagnostic failures stay local.
        """
        if self.diagnostics_collected:
            return
        self.diagnostics_collected = True
        report = self.startup_gate_diagnostics()
        report.update(diagnostic_status="collected", read_errors=0,
                      test_process_before_cleanup={"state": "not_started", "returncode": None})
        self.summary["startup_diagnostics"] = report
        try:
            if self.process is not None:
                try:
                    returncode = self.process.poll()
                    if returncode is None:
                        report["test_process_before_cleanup"]["state"] = "running"
                    elif type(returncode) is int and -(1 << 31) <= returncode < (1 << 31):
                        report["test_process_before_cleanup"].update(state="exited", returncode=returncode)
                    else:
                        report["test_process_before_cleanup"]["state"] = "unavailable"
                        report["read_errors"] += 1
                except Exception:
                    report["test_process_before_cleanup"]["state"] = "unavailable"
                    report["read_errors"] += 1
            files, journals = {}, {}
            for label, relative in DIAGNOSTIC_DOCUMENT_FILES.items():
                read = label in ("startup_trace", "observer", "script_checkpoints")
                try:
                    metadata, data = diagnostic_file(self.documents, relative, read=read)
                except Exception:
                    metadata, data = {"status": "read_error", "exists": None, "bytes": None}, None
                if metadata["status"] == "read_error":
                    report["read_errors"] += 1
                files[label] = metadata
                if read:
                    parsed = diagnostic_rows(data, self.run_id, startup=label == "startup_trace")
                    if metadata["status"] == "byte_limit":
                        parsed["status"] = "byte_limit"
                        parsed["violations"]["byte_limit"] = 1
                    journals[label] = parsed
            report["files"] = files
            trace = journals["startup_trace"]
            report["startup_trace"] = {"status": trace["status"], "rows": trace["rows"],
                                       "records": len(trace["rows"]), "violations": trace["violations"]}
            observer = journals["observer"]
            report["observer"] = {
                "status": observer["status"], "records": len(observer["rows"]),
                "violations": observer["violations"],
                "kind_counts": {kind: sum(row.get("kind") == kind for row in observer["rows"])
                                for kind in OBSERVER_KINDS},
                "unknown_kind_records": sum(row.get("kind") not in OBSERVER_KINDS
                                            for row in observer["rows"])}
            checkpoints = journals["script_checkpoints"]
            report["script_checkpoints"] = {
                "status": checkpoints["status"], "records": len(checkpoints["rows"]),
                "violations": checkpoints["violations"],
                "stage_counts": {stage: sum(is_script_checkpoint(row, stage, self.run_id)
                                             for row in checkpoints["rows"])
                                 for stage in CHECKPOINT_STAGES},
                "unrecognized_records": sum(not any(is_script_checkpoint(row, stage, self.run_id)
                                                     for stage in CHECKPOINT_STAGES)
                                            for row in checkpoints["rows"])}
            report["probe_request_exists"] = files["probe_request"]["exists"]
            report["device_request_exists"] = files["device_request"]["exists"]
            report["probe_request_absent_after_staging"] = (
                self.request_staged and files["probe_request"]["status"] == "missing")
            if self.documents is None:
                report["diagnostic_status"] = "unavailable"
            elif (report["read_errors"] or any(journal["status"] != "valid" for journal in journals.values())
                  or any(metadata["status"] not in ("regular", "missing") for metadata in files.values())):
                report["diagnostic_status"] = "partial"
        except Exception:
            # In particular, never mask the original gameplay failure with a
            # diagnostic read/parser exception or publish its arbitrary text.
            report["diagnostic_status"] = "internal_error"
            report["read_errors"] += 1

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
        self.staged_documents_identity = documents_identity(self.documents)
        self.request_staged = True
        self.summary["startup_diagnostics"]["request_staged"] = True

    def prepare_xcuitest(self) -> None:
        project = self.repo / "tools/renpy_ios_acceptance/RenPyAcceptance.xcodeproj"
        derived = self.output / "xcode-derived"
        destination = "platform=iOS Simulator,id=" + self.udid
        self.command("xcodebuild", "build-for-testing", "-project", str(project), "-scheme", "RenPyAcceptance",
                     "-configuration", "Debug", "-destination", destination,
                     "-derivedDataPath", str(derived), "CODE_SIGN_IDENTITY=-", timeout=240)
        paths = list((derived / "Build/Products").glob("*.xctestrun"))
        if len(paths) != 1:
            raise Failed("Xcode did not produce one executable UI test configuration")
        runners = list((derived / "Build/Products").glob("**/RenPyAcceptance-Runner.app/Info.plist"))
        if len(runners) != 1:
            raise Failed("Xcode did not build the real Simulator UI test runner app")
        configuration, runner_id = configure_destination_artifacts(
            plistlib.loads(paths[0].read_bytes()), paths[0].parent, runners[0].parent,
            self.bundle_id, self.run_id, self.args.overall_timeout)
        xctestrun = self.output / "RenPyGameplay.xctestrun"
        xctestrun.write_bytes(plistlib.dumps(configuration))
        self.destination_bindings_verified = True
        self.test_artifact_mode = "destination"
        self.summary["startup_diagnostics"].update(
            test_artifact_mode="destination", destination_bindings_verified=True)
        # Both genuine apps are installed before querying/staging the target
        # data container. The ensuing test action cannot reinstall artifacts.
        self.simctl("install", self.udid, str(runners[0].parent.resolve()), timeout=180)
        self.runner_installed = True
        self.summary["startup_diagnostics"]["runner_install_passed"] = True
        self.summary["ui_test_runner"] = runner_id
        self.ui_runner_id = runner_id
        self.prepared_xctestrun = xctestrun

    def start_xcuitest(self) -> None:
        if (self.prepared_xctestrun is None or not self.runner_installed
                or not self.destination_bindings_verified):
            raise Failed("Actual destination UI test artifacts were not prepared and installed")
        destination = "platform=iOS Simulator,id=" + self.udid
        runner_id = self.ui_runner_id
        self.process_log = (self.output / "xcuitest.log").open("wb")
        self.process = subprocess.Popen(["xcodebuild", "test-without-building", "-xctestrun", str(self.prepared_xctestrun),
                                        "-destination", destination, "-resultBundlePath", str(self.output / "gameplay.xcresult"),
                                        "-parallel-testing-enabled", "NO"], stdout=self.process_log, stderr=subprocess.STDOUT)

        def ready():
            data = self.simctl("get_app_container", self.udid, runner_id, "data", check=False).decode().strip()
            if not data:
                return None
            root = Path(data) / "Documents" / ("aether-renpy-ui-" + self.run_id)
            try:
                report = json.loads((root / "ready.json").read_text())
                if is_actual_xcui_ready(report, self.run_id, self.bundle_id):
                    self.ui_root = root
                    return True
            except (OSError, ValueError):
                return None

        self.wait("installed XCUITest runner and actual app launch", ready, timeout=180)
        self.xcui_ready = True
        self.xcui_ready_elapsed_msec = self.elapsed_msec()
        self.summary["startup_diagnostics"].update(
            xcui_ready_passed=True, xcui_ready_elapsed_msec=self.xcui_ready_elapsed_msec)
        # The real test process has launched the bound app. Requery rather
        # than assuming the prelaunch container survived the test action.
        current = self.simctl("get_app_container", self.udid, self.bundle_id, "data").decode().strip()
        self.verify_staged_documents(Path(current) / "Documents")

    def verify_staged_documents(self, current_documents: Path) -> None:
        self.container_identity_checked = False
        self.container_identity_same = None
        self.summary["startup_diagnostics"].update(container_identity_checked=False, container_identity_same=None)
        if self.staged_documents_identity is None:
            raise Failed("The actual app Documents container was not bound during staging")
        try:
            current_identity = documents_identity(current_documents)
        except (OSError, ValueError, RuntimeError) as exc:
            raise Failed("The actual app Documents container cannot be verified after UI launch") from exc
        self.container_identity_checked = True
        self.container_identity_same = current_identity == self.staged_documents_identity
        self.summary["startup_diagnostics"].update(
            container_identity_checked=True, container_identity_same=self.container_identity_same)
        if not self.container_identity_same:
            raise Failed("The actual app data container changed after staging; refusing stale gameplay evidence")

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
        self.install_elapsed_msec = self.elapsed_msec()
        self.summary["startup_diagnostics"].update(
            install_passed=True, install_elapsed_msec=self.install_elapsed_msec)
        self.simctl("terminate", self.udid, self.bundle_id, check=False)
        # Preserve the existing overall budget: it still includes the real
        # build-for-testing work, now before data-container staging.
        self.deadline = time.monotonic() + self.args.overall_timeout
        self.prepare_xcuitest()
        root = self.simctl("get_app_container", self.udid, self.bundle_id, "data").decode().strip()
        self.documents = Path(root) / "Documents"
        self.stage()
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
        if not any(is_successful_os_return(r) for r in events):
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
        self.snapshot_startup_diagnostics()
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
