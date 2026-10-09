#!/usr/bin/env python3
"""Boot a real official Android emulator using existing cloud KVM access.

This checks device availability only. It never installs an APK, executes a
Ren'Py game, changes security permissions, or accepts new SDK licenses.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import tempfile
import time
from pathlib import Path

from run_renpy_android_device_acceptance import Failed, image_stats, png_pixels


class Unavailable(RuntimeError):
    pass


class Preflight:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.output = args.output_dir.resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.environment = dict(os.environ)
        self.emulator_process = None
        self.emulator_log = None
        self.adb = None
        self.execution_started = False
        self.result = {"status": "not_run", "scope": "actual-cloud-emulator-preflight",
                       "execution_started": False,
                       "gameplay_executed": False, "apk_installed": False,
                       "host": {"system": platform.system(), "machine": platform.machine()},
                       "serial": f"emulator-{args.port}", "checks": [], "blocker": ""}

    def command(self, label: str, command: list[str], *, timeout: int = 30,
                check: bool = True, input_data: bytes | None = None) -> subprocess.CompletedProcess:
        try:
            streams = {"input": input_data} if input_data is not None else {"stdin": subprocess.DEVNULL}
            completed = subprocess.run(command, **streams, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       timeout=timeout, env=self.environment)
        except subprocess.TimeoutExpired as exc:
            (self.output / f"{label}.log").write_bytes(exc.stdout or b"")
            raise Unavailable(f"{label} timed out; partial real output is preserved: {exc}") from exc
        except OSError as exc:
            raise Unavailable(f"{label} could not complete: {exc}") from exc
        (self.output / f"{label}.log").write_bytes(completed.stdout)
        with (self.output / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps({"label": label, "command": command,
                                     "returncode": completed.returncode, "time": time.time()}) + "\n")
        if check and completed.returncode:
            detail = completed.stdout.decode(errors="replace").strip()[-1800:]
            raise Unavailable(f"{label} failed with exit {completed.returncode}: {detail}")
        return completed

    def device(self, label: str, *parts: str, check: bool = True, timeout: int = 30):
        return self.command(label, [str(self.adb), "-s", self.result["serial"], *parts],
                            check=check, timeout=timeout)

    def run(self) -> None:
        if not self.args.cloud_emulator:
            raise Unavailable("--cloud-emulator is required; only the selected cloud environment is authorized")
        sdk = Path(self.args.sdk_root).resolve() if self.args.sdk_root else None
        kvm = Path("/dev/kvm")
        self.result["kvm"] = {"exists": kvm.exists(), "readable": os.access(kvm, os.R_OK),
                              "writable": os.access(kvm, os.W_OK)}
        if kvm.exists():
            self.result["kvm"]["mode"] = oct(kvm.stat().st_mode & 0o777)
        problems = []
        if platform.system() != "Linux" or platform.machine() != "x86_64":
            problems.append("This official x86_64 emulator preflight requires an existing Linux x86_64 cloud runner")
        if sdk is None or not sdk.is_dir():
            problems.append("Official Android SDK is unavailable; supply its existing ANDROID_SDK_ROOT/ANDROID_HOME")
        emulator = sdk / "emulator/emulator" if sdk else None
        sdkmanager = sdk / "cmdline-tools/latest/bin/sdkmanager" if sdk else None
        avdmanager = sdk / "cmdline-tools/latest/bin/avdmanager" if sdk else None
        for tool in (sdkmanager, avdmanager):
            if tool is not None and not tool.is_file():
                problems.append(f"Existing official SDK tool is unavailable: {tool}")
        if emulator is not None and emulator.is_file():
            acceleration = self.command("acceleration", [str(emulator), "-accel-check"], check=False)
            self.result["acceleration_exit_code"] = acceleration.returncode
            if acceleration.returncode:
                problems.append("Official emulator reports that existing KVM acceleration is unavailable; see acceleration.log")
        if not all(self.result["kvm"][key] for key in ("exists", "readable", "writable")):
            problems.append("Existing /dev/kvm read/write access is unavailable; no permissions or security settings were changed")
        if problems:
            raise Unavailable("; ".join(problems))
        if not emulator.is_file():
            self.command("official-emulator-install", [str(sdkmanager), "--install", "emulator"], timeout=300)
            if not emulator.is_file():
                raise Unavailable("Official emulator installation did not complete; check SDK download/license logs")
            acceleration = self.command("acceleration", [str(emulator), "-accel-check"], check=False)
            self.result["acceleration_exit_code"] = acceleration.returncode
            if acceleration.returncode:
                raise Unavailable("Official emulator reports existing KVM acceleration is unavailable; see acceleration.log")
        self.result["sdk_root"] = str(sdk)
        self.command("emulator-version", [str(emulator), "-version"])
        image = "system-images;android-35;google_apis;x86_64"
        self.result["system_image"] = image
        # sdkmanager uses its normal official repositories and existing license
        # files. DEVNULL does not automatically approve a license prompt.
        self.command("official-sdk-install", [str(sdkmanager), "--install", "platform-tools", image], timeout=600)
        image_dir = sdk / "system-images/android-35/google_apis/x86_64"
        properties = image_dir / "source.properties"
        if not properties.is_file():
            raise Unavailable("Official system image was not installed; check SDK download/license logs")
        (self.output / "system-image-source.properties").write_bytes(properties.read_bytes())
        self.adb = sdk / "platform-tools/adb"
        if not self.adb.is_file():
            raise Unavailable("Official Android platform-tools installation did not supply adb")
        self.command("adb-version", [str(self.adb), "version"])
        with tempfile.TemporaryDirectory(prefix="renpy-cloud-emulator-preflight-") as temporary:
            avd_root = Path(temporary) / "avd"
            avd_root.mkdir()
            self.environment["ANDROID_AVD_HOME"] = str(avd_root)
            avd_name = "aether-renpy-cloud-preflight"
            self.command("create-official-avd", [str(avdmanager), "create", "avd", "--name", avd_name,
                         "--force", "--device", "pixel_2", "--package", image], input_data=b"no\n", timeout=120)
            config = avd_root / f"{avd_name}.avd/config.ini"
            if not config.is_file():
                raise Unavailable("Official avdmanager did not create a usable virtual device")
            with config.open("a") as stream:
                stream.write("\nhw.keyboard=no\n")
            (self.output / "avd-config.ini").write_bytes(config.read_bytes())
            command = [str(emulator), "-avd", avd_name, "-port", str(self.args.port), "-accel", "on",
                       "-gpu", "swiftshader", "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot",
                       "-memory", "2048", "-camera-front", "none", "-camera-back", "none"]
            self.result["emulator_command"] = command
            self.emulator_log = (self.output / "emulator.log").open("wb")
            self.emulator_process = subprocess.Popen(command, stdout=self.emulator_log, stderr=subprocess.STDOUT,
                                                     stdin=subprocess.DEVNULL, env=self.environment)
            self.execution_started = True
            self.result["execution_started"] = True
            try:
                deadline = time.monotonic() + self.args.boot_timeout
                self.device("adb-wait-for-device", "wait-for-device", timeout=min(180, self.args.boot_timeout))
                while time.monotonic() < deadline:
                    if self.emulator_process.poll() is not None:
                        raise Unavailable(f"Actual emulator exited before Android boot: {self.emulator_process.returncode}; see emulator.log")
                    boot = self.device("boot-completed", "shell", "getprop", "sys.boot_completed", timeout=20)
                    if boot.stdout.decode().strip() == "1":
                        break
                    time.sleep(2)
                else:
                    raise Unavailable(f"Actual emulator did not boot within {self.args.boot_timeout} seconds; see emulator.log")
                self.device("unlock", "shell", "input", "keyevent", "82")
                self.device("device-properties", "shell", "getprop")
                wanted = ["ro.build.fingerprint", "ro.product.cpu.abilist", "ro.build.version.sdk", "ro.opengles.version"]
                values = {}
                for name in wanted:
                    values[name] = self.device("property-" + name, "shell", "getprop", name).stdout.decode().strip()
                self.result["device_properties"] = values
                if "x86_64" not in values["ro.product.cpu.abilist"].split(",") or values["ro.build.version.sdk"] != "35":
                    raise Unavailable("Booted device does not match the requested official Android 35 x86_64 image")
                if int(values["ro.opengles.version"] or "0") < 0x30000:
                    raise Unavailable("Booted device does not advertise the GLES 3.0 required by the application")
                surface = self.device("surfaceflinger", "shell", "dumpsys", "SurfaceFlinger").stdout.decode(errors="replace")
                gles = [line.strip() for line in surface.splitlines() if "GLES:" in line]
                self.result["surfaceflinger_gles"] = gles
                if not gles:
                    raise Unavailable("Actual SurfaceFlinger did not expose a GLES renderer; see surfaceflinger.log")
                screenshot = self.output / "actual-android-screen.png"
                screenshot.write_bytes(self.device("screen-capture", "exec-out", "screencap", "-p").stdout)
                self.result["actual_os_screen"] = image_stats(png_pixels(screenshot))
                self.result["checks"] = ["official-emulator-kvm-usable", "actual-android-boot-completed",
                                         "adb-real-device-properties", "actual-surfaceflinger-gles", "actual-os-screen"]
                self.stop(require_clean=True)
                self.result["checks"].append("actual-emulator-stopped")
                self.result["status"] = "passed"
            finally:
                self.stop(require_clean=False)

    def stop(self, *, require_clean: bool) -> None:
        process = self.emulator_process
        if process is None:
            if self.emulator_log:
                self.emulator_log.close()
                self.emulator_log = None
            return
        clean = True
        if process.poll() is None:
            try:
                stopped = self.device("stop-emulator", "emu", "kill", check=False, timeout=20)
                clean = stopped.returncode == 0
                process.wait(timeout=25)
            except (Unavailable, subprocess.TimeoutExpired):
                clean = False
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
        self.result["emulator_exit_code"] = process.returncode
        self.result["emulator_stopped_cleanly"] = clean and process.returncode == 0
        self.emulator_process = None
        if self.emulator_log:
            self.emulator_log.close()
            self.emulator_log = None
        if require_clean and not self.result["emulator_stopped_cleanly"]:
            raise Unavailable("Actual emulator required forced process cleanup; see stop-emulator.log/emulator.log")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cloud-emulator", action="store_true")
    parser.add_argument("--sdk-root", default=os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME", ""))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--boot-timeout", type=int, default=480)
    parser.add_argument("--port", type=int, default=5554)
    args = parser.parse_args()
    if not 60 <= args.boot_timeout <= 600 or not 5554 <= args.port <= 5682 or args.port % 2:
        parser.error("Boot timeout must be 60..600 seconds; console port must be even, 5554..5682")
    preflight = Preflight(args)
    code = 0
    try:
        preflight.run()
    except (Unavailable, Failed, OSError, ValueError) as exc:
        preflight.result.update(status="failed" if preflight.execution_started else "not_run", blocker=str(exc))
        code = 1 if preflight.execution_started else 2
    finally:
        preflight.stop(require_clean=False)
        (preflight.output / "result.json").write_text(json.dumps(preflight.result, indent=2) + "\n")
    print(json.dumps(preflight.result, indent=2))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
