#!/usr/bin/env python3
"""Run the actual UIKit host in a disposable app on a booted iOS Simulator.

--game takes the original fixture prepared by tools/tyrano_smoke.py. Neither
the upstream engine nor game assets are added to the repository or app product.
"""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import uuid


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--device", required=True, help="An already booted simulator UDID")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    token = uuid.uuid4().hex[:12]
    output = (args.output or repo / "out/diagnostics/tyrano" / f"ios-{token}").resolve()
    output.mkdir(parents=True, exist_ok=False)
    bundle = "org.aether.tests.tyrano." + token
    app = output / "TyranoHostProbe.app"
    app.mkdir()
    shutil.copytree(args.game.resolve(), app / "Game", symlinks=True, ignore=shutil.ignore_patterns(".git", "outside.txt", ".DS_Store"))
    script = (repo / "bridge/tyrano_runtime/host.js").read_text()
    (output / "tyrano_host_script.h").write_text('#pragma once\nstatic const char *const kAetherTyranoHostScript = R"TYRANOHOST(' + script + ')TYRANOHOST";\n')
    plist = {"CFBundleIdentifier":bundle, "CFBundleName":"Tyrano Host Probe", "CFBundleExecutable":"Probe",
             "CFBundlePackageType":"APPL", "CFBundleVersion":"1", "CFBundleShortVersionString":"1.0",
             "MinimumOSVersion":"16.0", "LSRequiresIPhoneOS":True, "UIDeviceFamily":[1,2],
             "UILaunchScreen":{}, "UISupportedInterfaceOrientations":["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]}
    (app / "Info.plist").write_bytes(plistlib.dumps(plist))
    sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], capture_output=True).stdout.strip()
    run(["xcrun", "--sdk", "iphonesimulator", "clang++", "-std=c++17", "-fobjc-arc", "-x", "objective-c++",
         "-target", "arm64-apple-ios16.0-simulator", "-isysroot", sdk, "-I", str(output), "-I", str(repo / "bridge/godot_extension/src"),
         str(repo / "tests/tyrano_mobile/ios_host_smoke.mm"), str(repo / "bridge/godot_extension/src/tyrano_webview.mm"),
         "-framework", "UIKit", "-framework", "Foundation", "-framework", "WebKit", "-framework", "CoreGraphics", "-framework", "UniformTypeIdentifiers", "-o", str(app / "Probe")])
    run(["codesign", "--force", "--sign", "-", str(app)])
    installed = False
    try:
        run(["xcrun", "simctl", "install", args.device, str(app)])
        installed = True
        log = output / "console.log"
        run(["xcrun", "simctl", "launch", "--stdout=" + str(log), "--stderr=" + str(log), args.device, bundle])
        container = Path(run(["xcrun", "simctl", "get_app_container", args.device, bundle, "data"], capture_output=True).stdout.strip())
        result = container / "Documents/tyrano-mobile-result.json"
        for _attempt in range(90):
            if result.exists():
                report = json.loads(result.read_text())
                (output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
                if not report["passed"]:
                    raise RuntimeError(report["error"])
                print("TYRANO_IOS_HOST_OK", flush=True)
                return
            time.sleep(1)
        raise RuntimeError(f"No result from the UIKit probe. See {log}")
    finally:
        if installed:
            subprocess.run(["xcrun", "simctl", "terminate", args.device, bundle], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            run(["xcrun", "simctl", "uninstall", args.device, bundle])


if __name__ == "__main__":
    main()
