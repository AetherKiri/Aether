#!/usr/bin/env python3
"""Run an opt-in runtime regression on macOS or a connected iOS device.

Cases and writable-state seeds are local inputs. No images are captured.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid


PROBE = "res://scripts/runtime_regression_probe.gd"


def read_report(path):
    report = json.loads(path.read_text())
    if not isinstance(report, dict) or not isinstance(report.get("events", []), list):
        raise ValueError("Invalid regression result")
    return report


def cleanup_result(report):
    """Only an explicit event after engine destruction completes a device run."""
    events = report.get("events", [])
    if not events or not isinstance(events[-1], dict):
        return None
    final = events[-1]
    if final.get("event") != "cleanup_complete":
        return None
    code = final.get("exit_code")
    if type(code) is not int:
        return None
    if code == 0 and (len(events) < 2 or not isinstance(events[-2], dict)
            or events[-2].get("event") != "passed"):
        return None
    return code


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", type=Path)
    parser.add_argument("--platform", choices=("macos", "ios"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seed", type=Path, help="Copy this writable-state tree into the isolated run")
    parser.add_argument("--game", help="Override the case's game_path on this host or device")
    parser.add_argument("--pointer-input", choices=("mouse", "touch"),
        help="Use the app's ScreenTouch handler for clicks instead of direct player pointer input")
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--device")
    parser.add_argument("--bundle", help="Installed development app bundle ID")
    parser.add_argument("--prepare-only", action="store_true",
        help="iOS: queue a one-shot case for the app's next normal launch")
    parser.add_argument("--project", type=Path, help="Godot project containing the probe")
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--user-data-dir", type=Path, help="The project's macOS user:// directory")
    return parser.parse_args()


def main():
    args = arguments()
    if args.platform == "ios" and (not args.device or not args.bundle):
        raise SystemExit("iOS requires --device and --bundle")
    if args.platform == "macos" and (not args.project or not args.user_data_dir):
        raise SystemExit("macOS requires --project and --user-data-dir")
    if args.timeout <= 0:
        raise SystemExit("--timeout must be positive")
    if args.prepare_only and args.platform != "ios":
        raise SystemExit("--prepare-only requires iOS")
    config = json.loads(args.case.read_text())
    if not isinstance(config, dict) or not isinstance(config.get("steps"), list) or not config["steps"]:
        raise SystemExit("Case must contain a nonempty steps array")
    run_id = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8]
    output = args.output.resolve() / run_id
    output.mkdir(parents=True)
    config["writable_root"] = "user://regressions/" + run_id
    config["probe_script"] = PROBE
    if args.game:
        config["game_path"] = args.game
    if args.pointer_input:
        config["pointer_input"] = args.pointer_input
    (output / "case.json").write_text(json.dumps(config, ensure_ascii=False, indent=2))
    isolated = output / "seed"
    if args.seed:
        shutil.copytree(args.seed, isolated)
    else:
        isolated.mkdir()
    # A seeded result must never be accepted as evidence of this execution.
    (isolated / "regression-result.json").unlink(missing_ok=True)
    env = os.environ.copy()
    env["AETHERKIRI_CLI_PROBE_SCRIPT"] = PROBE
    env["AETHERKIRI_TEST_CONFIG_JSON"] = json.dumps(config, ensure_ascii=False)
    env["AETHERKIRI_DIAGNOSTICS"] = "1"

    def device(*command, name, check=True):
        with (output / (name + ".log")).open("w") as log:
            return subprocess.run(["xcrun", "devicectl", *command,
                "--json-output", str(output / (name + ".json"))],
                env=env, stdout=log, stderr=subprocess.STDOUT, check=check, timeout=45)

    if args.platform == "ios":
        remote = "Documents/regressions/" + run_id
        device("device", "copy", "to", "--device", args.device,
            "--domain-type", "appDataContainer", "--domain-identifier", args.bundle,
            "--source", str(isolated), "--destination", remote, name="seed-copy")
        if args.prepare_only:
            device("device", "copy", "from", "--device", args.device,
                "--domain-type", "appDataContainer", "--domain-identifier", args.bundle,
                "--source", "Documents/aetherkiri-probe-request.json",
                "--destination", str(output / "previous-request.json"),
                name="previous-request", check=False)
            device("device", "copy", "to", "--device", args.device,
                "--domain-type", "appDataContainer", "--domain-identifier", args.bundle,
                "--source", str(output / "case.json"),
                "--destination", "Documents/aetherkiri-probe-request.json", name="queue-case")
            summary = {"prepared": True, "passed": None, "run_id": run_id,
                "result_source": remote + "/regression-result.json", "artifacts": str(output)}
            (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
            print(json.dumps(summary, ensure_ascii=False), flush=True)
            return 0
        launch_env = {key: env[key] for key in ("AETHERKIRI_CLI_PROBE_SCRIPT", "AETHERKIRI_TEST_CONFIG_JSON", "AETHERKIRI_DIAGNOSTICS")}
        result_path = output / "regression-result.json"
        device("device", "process", "launch", "--device", args.device,
            "--terminate-existing", "--environment-variables", json.dumps(launch_env),
            args.bundle, name="launch")
        launched = json.loads((output / "launch.json").read_text())["result"]["process"]
        launch_pid = int(launched["processIdentifier"])
        if launch_pid <= 0:
            raise SystemExit("Launch did not return a valid process ID")
    else:
        writable = args.user_data_dir.resolve() / "regressions" / run_id
        shutil.copytree(isolated, writable)
        result_path = writable / "regression-result.json"
        command = [args.godot, "--path", str(args.project.resolve())]

    print(f"Running {config.get('name', args.case.stem)} on {args.platform}; artifacts: {output}", flush=True)
    timed_out = False
    process_exit_code = None
    device_cleanup_code = None
    device_stopped = True
    if args.platform == "ios":
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            device("device", "copy", "from", "--device", args.device,
                "--domain-type", "appDataContainer", "--domain-identifier", args.bundle,
                "--source", remote + "/regression-result.json", "--destination", str(result_path),
                name="result-copy", check=False)
            try:
                device_cleanup_code = cleanup_result(read_report(result_path))
            except (OSError, ValueError):
                pass
            if device_cleanup_code is not None:
                break
            time.sleep(2)
        timed_out = device_cleanup_code is None
        # A successful engine teardown need not terminate the iOS app process.
        # Stop only the PID returned by this launch, after checking its identity.
        device("device", "info", "processes", "--device", args.device,
            "--filter", f"processIdentifier == {launch_pid}", name="final-processes")
        running = json.loads((output / "final-processes.json").read_text())["result"]["runningProcesses"]
        for candidate in running:
            if (candidate.get("processIdentifier") == launch_pid
                    and candidate.get("executable") == launched.get("executable")):
                stopped = device("device", "process", "terminate", "--device", args.device,
                    "--pid", str(launch_pid), name="terminate", check=False)
                device_stopped = stopped.returncode == 0
        device("device", "copy", "from", "--device", args.device,
            "--domain-type", "appDataContainer", "--domain-identifier", args.bundle,
            "--source", "Documents/aetherkiri-device-probe.log",
            "--destination", str(output / "device-probe.log"), name="probe-log", check=False)
    else:
        with (output / "console.log").open("w") as log:
            process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + args.timeout
            while process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.25)
            if process.poll() is None:
                timed_out = True
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
        process_exit_code = process.returncode

    if args.platform == "ios":
        device("device", "copy", "from", "--device", args.device,
            "--domain-type", "appDataContainer", "--domain-identifier", args.bundle,
            "--source", remote + "/regression-result.json", "--destination", str(result_path),
            name="result-copy", check=False)
    elif result_path.exists():
        shutil.copy2(result_path, output / result_path.name)

    report_error = None
    try:
        report = read_report(result_path) if result_path.exists() else {}
    except (OSError, ValueError) as error:
        report, report_error = {}, str(error)
    events = report.get("events", [])
    completed = cleanup_result(report)
    if args.platform == "ios":
        passed = not timed_out and device_stopped and completed == 0
    else:
        passed = (not timed_out and process_exit_code == 0 and bool(events)
            and isinstance(events[-1], dict)
            and (events[-1].get("event") == "passed" or completed == 0))
    summary = {"passed": passed, "timed_out": timed_out,
        "process_exit_code": process_exit_code, "run_id": run_id,
        "last_event": {key: value for key, value in events[-1].items() if key != "state"}
            if events and isinstance(events[-1], dict) else None,
        "artifacts": str(output),
        "report_error": report_error}
    if args.platform == "ios":
        summary.update(engine_cleanup_exit_code=completed, device_process_stopped=device_stopped)
    (output / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    print(json.dumps(summary, ensure_ascii=False), flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
