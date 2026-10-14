#!/usr/bin/env python3
"""Install only the isolated native probe and collect its JSON/log diagnostics."""
import argparse
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    apk = args.apk
    if apk.is_dir():
        candidates = list(apk.glob("*.apk"))
        if len(candidates) != 1: parser.error("Expected exactly one APK in " + str(apk))
        apk = candidates[0]
    if not apk.is_file(): parser.error("APK not found: " + str(apk))
    package = "org.aether.tests.renpy"
    subprocess.run(["adb", "install", "-r", str(apk)], check=True)
    subprocess.run(["adb", "logcat", "-c"], check=True)
    subprocess.run(["adb", "shell", "am", "start", "-W", "-n", package + "/com.godot.game.GodotApp"], check=True)
    passed = False
    try:
        for _ in range(150):
            time.sleep(2)
            log = subprocess.check_output(["adb", "logcat", "-d"], text=True, errors="replace")
            (args.output / "logcat.txt").write_text(log)
            if "RENPY_NATIVE_GODOT_FAILED" in log or "FATAL EXCEPTION" in log or "Fatal signal" in log: break
            if "RENPY_NATIVE_GODOT_OK" in log:
                passed = True
                break
    finally:
        with (args.output / "app-files.tar").open("wb") as file:
            subprocess.run(["adb", "exec-out", "run-as", package, "tar", "-cf", "-", "files"], stdout=file, check=False)
    if not passed:
        raise RuntimeError("Native Android scenario failed; see " + str(args.output / "logcat.txt"))
    print("RENPY_ANDROID_SMOKE_OK")


if __name__ == "__main__":
    main()
