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
import shlex
import signal
import stat
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
    r"://|www\.|eyJ",
    re.IGNORECASE,
)
STARTUP_FILES = ("commands.jsonl", "install.txt", "aetherkiri-engine.log", "renpy-traceback.txt",
                 "renpy-log.txt", "android-process-logcat.txt", "android-system-logcat.txt")
STARTUP_ERROR = re.compile(r"error|exception|traceback|fatal|failed|cannot|could not|not found|"
                           r"undefined symbol|no module|segmentation|renpy_mobile|cooperative_", re.IGNORECASE)
LOGCAT_ROW = re.compile(r"^\d\d-\d\d\s+\S+\s+(\d+)\s+\d+\s+([VDIWEF])\s+([^:]+):\s*(.*)$")
STARTUP_TOKENS = re.compile(r"[A-Za-z0-9_.]+")


def startup_line(raw: str) -> str:
    line = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", raw)
    return re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", line)


def startup_text(lines: list[str]) -> dict:
    # Only selected startup/error records reach this function, never raw EOF tails.
    filtered = ["[redacted environment line]" if re.search(
        r"(?:^|:\s*)(?:env(?:ironment)?\b|export\s|[A-Z_][A-Z0-9_]*\s*=)", line, re.IGNORECASE)
        else line for raw in lines for line in startup_line(raw).splitlines()]
    return bounded_diagnostic("\n".join(filtered), max_chars=512, max_lines=6)


def startup_error_text(lines: list[str], deadline: float | None = None) -> dict:
    # Preserve the first fatal/header and the final specific causes. Long E-tag
    # stacks must not replace a Java loader or Python import error with frames.
    deadline = time.monotonic() + 2 if deadline is None else deadline
    first = fallback = last = None
    causes = []
    timed_out, skipped = time.monotonic() >= deadline, False
    for index, line in enumerate(lines[:5000]):
        if time.monotonic() >= deadline:
            timed_out = True
            break
        if len(line) > 4096:
            skipped = True
            continue
        lower = line.lower()
        is_primary = any(word in lower for word in ("fatal", "traceback", "dlopen failed", "undefined symbol", "no module named"))
        is_cause = any(word in lower for word in ("caused by:", "dlopen failed", "undefined symbol", "no module named"))
        # One token traversal avoids an unanchored greedy suffix regex which
        # rescans a long identifier at every character when no Error is present.
        for token in STARTUP_TOKENS.finditer(line):
            if time.monotonic() >= deadline:
                timed_out = True
                break
            if token.group().lower().endswith(("error", "exception")):
                is_primary = True
                is_cause |= line[token.end():token.end() + 1] == ":"
            if is_primary and is_cause:
                break
        if timed_out:
            break
        if fallback is None:
            fallback = index
        last = index
        if first is None and is_primary:
            first = index
        if is_cause:
            causes = (causes + [index])[-2:]
    chosen = list(dict.fromkeys(([first if first is not None else fallback] if fallback is not None else []) + causes))
    if len(chosen) == 1 and chosen[0] != last:
        chosen.append(last)
    selected = []
    for index in chosen:
        safe = startup_text([lines[index]])["output"]
        selected.append(safe if len(safe) <= 192 else safe[:64] + " ... " + safe[-123:])
    result = bounded_diagnostic("\n".join(selected), max_chars=768, max_lines=6)
    result["truncated"] |= timed_out or skipped or len(chosen) < len(lines) or any(len(lines[index]) > 192 for index in chosen)
    if timed_out:
        result["diagnostic_deadline_reached"] = True
    return result


def read_startup_lines(path: Path, started_ns: int, deadline: float) -> tuple[dict, list[str]]:
    """Read a bounded prefix of a fresh regular file produced by this harness."""
    if time.monotonic() >= deadline:
        return {"status": "diagnostic_notavailable", "reason": "diagnostic_deadline"}, []
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        try:
            details = os.fstat(descriptor)
            if not stat.S_ISREG(details.st_mode) or details.st_mtime_ns < started_ns:
                return {"status": "diagnostic_notavailable", "reason": "not_fresh_regular_file"}, []
            raw = os.read(descriptor, 262144)
        finally:
            os.close(descriptor)
    except OSError:
        return {"status": "diagnostic_notavailable", "reason": "missing_or_unreadable_file"}, []
    bytes_read = len(raw)
    truncated = details.st_size > bytes_read
    if truncated:
        raw = raw.rpartition(b"\n")[0]  # Never expose a cut line with hidden sensitive text.
    lines = raw.decode(errors="replace").splitlines()
    bounded = [startup_line(line) for line in lines[:5000] if len(line) <= 4096]
    return {"status": "available", "bytes_read": bytes_read, "prefix_bytes_processed": len(raw),
            "truncated": truncated or len(lines) > 5000 or len(bounded) != len(lines)}, bounded


def read_current_harness_result(path: Path, started_ns: int | None) -> dict:
    """Never accept an old or redirected result, even with an identical APK tuple."""
    if started_ns is None or path.parent.is_symlink():
        raise Unavailable("Current APK harness result ownership could not be verified")
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        try:
            before = os.fstat(descriptor)
            if not stat.S_ISREG(before.st_mode) or before.st_mtime_ns < started_ns:
                raise Unavailable("Actual APK harness result is not a fresh current regular file")
            if before.st_size > 262144:
                raise Unavailable("Actual APK harness result exceeds its 256KiB read limit")
            raw = os.read(descriptor, 262144)
            after = os.fstat(descriptor)
            if after.st_mtime_ns < started_ns or after.st_size != len(raw) \
                    or after.st_mtime_ns != before.st_mtime_ns or after.st_size != before.st_size:
                raise Unavailable("Actual APK harness result changed during its bounded read")
        finally:
            os.close(descriptor)
    except OSError as exc:
        raise Unavailable("Actual APK harness did not provide a readable current result without symlinks") from exc
    try:
        summary = json.loads(raw.decode("utf-8"))
    except (ValueError, RecursionError) as exc:
        raise Unavailable("Actual APK harness current result is not valid bounded JSON") from exc
    if not isinstance(summary, dict):
        raise Unavailable("Actual APK harness current result is not a JSON object")
    return summary


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
        self.harness_started_ns = None
        self.boot_started = None
        self.next_boot_progress = 0
        self.result.update(scope="actual-cloud-android-emulator-session",
                           gameplay_verification="not_run", gameplay_attempted=False,
                           gameplay_verified=False, harness_started=False,
                           process_started=False,
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

    def startup_failure_diagnostics(self) -> None:
        """Print selected fresh local evidence only; this performs no device/network calls."""
        payload = {"checkpoint": "actual-apk-startup-failure-diagnostics", "status": "diagnostic_notavailable",
                   "gameplay_verified": False, "files": {}, "commands": []}
        output = self.output / "gameplay"
        if self.harness_started_ns is None or output.is_symlink():
            payload["reason"] = "no_owned_harness_output"
        else:
            deadline = time.monotonic() + 2
            records = {}
            for name in STARTUP_FILES:
                metadata, lines = read_startup_lines(output / name, self.harness_started_ns, deadline)
                payload["files"][name] = metadata
                records[name] = lines
            own_pids = set()
            prefix = [str(self.adb), "-s", self.result["serial"]]
            for line in records.get("commands.jsonl", []):
                if time.monotonic() >= deadline:
                    payload["diagnostic_deadline_reached"] = True
                    break
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict) or not isinstance(row.get("command"), list) \
                        or row["command"][:3] != prefix or not isinstance(row.get("time"), (int, float)) \
                        or row["time"] < self.harness_started_ns / 1_000_000_000:
                    continue
                parts = row["command"][3:]
                if not all(isinstance(part, str) for part in parts):
                    continue
                if parts[:1] == ["logcat"] and "--pid" in parts:
                    index = parts.index("--pid") + 1
                    if index < len(parts) and re.fullmatch(r"[1-9]\d{0,9}", parts[index]) \
                            and int(parts[index]) <= 2147483647:
                        own_pids.add(parts[index])
                phase = ""
                if parts[:2] == ["install", "-r"] and len(parts) == 3 \
                        and self.args.apk is not None and parts[2] == str(self.args.apk.resolve()):
                    phase = "apk_install"
                elif parts[:1] == ["shell"] and len(parts) == 2:
                    try:
                        remote = shlex.split(parts[1])
                    except ValueError:
                        continue
                    if remote == ["pidof", self.args.package]:
                        phase = "app_pid_observation"
                    elif remote[:4] == ["am", "start", "-W", "-n"] and len(remote) == 5 \
                            and remote[4].startswith(self.args.package + "/") \
                            and re.fullmatch(r"[A-Za-z0-9_.$/]+", remote[4]):
                        phase = "app_start"
                code = row.get("returncode")
                if phase and isinstance(code, int) and not isinstance(code, bool) and -255 <= code <= 255 \
                        and len(payload["commands"]) < 8:
                    payload["commands"].append({"phase": phase, "returncode": code,
                                                "stdout": "not_recorded_by_command_log",
                                                "stderr": startup_text([str(row.get("stderr", ""))])})
            owned_launch = self.result.get("actual_status", {}).get("app_launch", {})
            if owned_launch.get("status") == "passed":
                own_pids.update(owned_launch["pids"])
            payload["observed_process_pids"] = sorted(own_pids)[:8]
            install_lines = records.get("install.txt", [])
            payload["installation_success_marker"] = any(line.strip() == "Success" for line in install_lines)
            for name in STARTUP_FILES[2:]:
                selected = []
                for line in records[name]:
                    if time.monotonic() >= deadline:
                        payload["diagnostic_deadline_reached"] = True
                        break
                    if "logcat" in name:
                        parsed = LOGCAT_ROW.match(line)
                        if not parsed:
                            continue
                        pid, priority, _, message = parsed.groups()
                        if pid not in own_pids and not re.search(
                                r"(?<![A-Za-z0-9_.])" + re.escape(self.args.package) + r"(?![A-Za-z0-9_.])", message):
                            continue
                        if priority not in ("E", "F") and not STARTUP_ERROR.search(message):
                            continue
                    elif not STARTUP_ERROR.search(line) and not ('File "' in line and '", line ' in line):
                        continue
                    selected.append(line)
                extracted = startup_error_text(selected, deadline)
                extracted["truncated"] |= payload["files"][name].get("truncated", False)
                payload["files"][name].update(extracted)
            if any(row["status"] == "available" for row in payload["files"].values()):
                payload["status"] = "diagnostic_available"
        # This console record plus the small retained result metadata stay <8KiB.
        serialized = json.dumps(payload, separators=(",", ":"))
        while len(serialized.encode()) > 6143:
            candidates = [row for row in payload["files"].values() if row.get("output")]
            candidates += [row["stderr"] for row in payload["commands"] if row["stderr"].get("output")]
            if not candidates:
                payload["commands"] = payload["commands"][:2]
            else:
                largest = max(candidates, key=lambda row: len(row["output"]))
                largest["output"] = largest["output"][:len(largest["output"]) // 2]
                largest["truncated"] = True
            serialized = json.dumps(payload, separators=(",", ":"))
        self.result["startup_diagnostics"] = {"status": payload["status"], "console_bytes": len(serialized.encode()) + 1,
                                               "files_available": sum(row["status"] == "available"
                                                                      for row in payload["files"].values()),
                                               "gameplay_verified": False}
        print(serialized, flush=True)

    def retain_partial_milestones(self, summary: dict, apk_hash: str) -> None:
        if summary.get("source") != "actual-apk-adb-cloud-device" or summary.get("package") != self.args.package \
                or summary.get("serial") != self.result["serial"] or summary.get("apk_sha256") != apk_hash:
            return
        stages = summary.get("actual_status")
        if not isinstance(stages, dict):
            return
        mirrored = {}
        for stage, flag, marker in (("apk_install", "apk_installed", "Success"),
                                    ("app_launch", "process_started", "Status: ok")):
            proof = stages.get(stage)
            if not isinstance(proof, dict) or summary.get(flag) is not True or proof.get("status") != "passed" \
                    or proof.get("source") != "actual-adb-command" or proof.get("package") != self.args.package \
                    or proof.get("serial") != self.result["serial"] or not isinstance(proof.get("returncode"), int) \
                    or isinstance(proof.get("returncode"), bool) \
                    or proof.get("returncode") != 0 or proof.get("stdout_marker") != marker:
                continue
            row = {key: proof[key] for key in ("status", "source", "package", "serial", "returncode", "stdout_marker")}
            if stage == "app_launch":
                activity, pids, count = proof.get("activity"), proof.get("pids"), proof.get("pid_count")
                if not self.result["apk_installed"] or not isinstance(activity, str) or len(activity) > 256 \
                        or not activity.startswith(self.args.package + "/") \
                        or not re.fullmatch(r"[A-Za-z0-9_.$/]+", activity) or not isinstance(pids, list) \
                        or not 1 <= len(pids) <= 8 or not all(isinstance(pid, str) and re.fullmatch(r"[1-9]\d{0,9}", pid)
                                                            and int(pid) <= 2147483647
                                                            for pid in pids) \
                        or isinstance(count, bool) or not isinstance(count, int) or not len(pids) <= count <= 1024:
                    continue
                row.update(activity=activity, pids=pids, pid_count=count)
            self.result[flag] = True
            mirrored[stage] = row
        if mirrored:
            self.result["actual_status"] = mirrored

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
        self.harness_started_ns = time.time_ns()
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
        summary = read_current_harness_result(summary_path, self.harness_started_ns)
        self.result["gameplay_result"] = summary
        self.result["gameplay_verification"] = summary.get("status", "failed")
        if summary.get("status") == "not_run":
            self.result["gameplay_executed"] = False
        apk_hash = hashlib.sha256(self.args.apk.read_bytes()).hexdigest()
        self.retain_partial_milestones(summary, apk_hash)
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
                    try:
                        self.gameplay()
                    except (Unavailable, Failed, OSError, ValueError, subprocess.TimeoutExpired):
                        try:
                            self.startup_failure_diagnostics()
                        except (OSError, ValueError) as diagnostic_error:
                            self.result["startup_diagnostic_error"] = bounded_diagnostic(
                                str(diagnostic_error), max_chars=256, max_lines=1)
                        raise
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
