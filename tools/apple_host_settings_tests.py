#!/usr/bin/env python3
"""Build and run the real ShellModel settings tests against the existing host core."""
from pathlib import Path
import subprocess
import os


def main():
    root = Path(__file__).resolve().parents[1]
    project = root / "out/apple_host/settings-behavior-project"
    derived = root / "out/apple_host/settings-behavior-derived"
    project.mkdir(parents=True, exist_ok=True)
    # Paths are serialized as YAML strings; no shell interpolation.
    import json
    q = lambda p: json.dumps(str(p))
    (project / "project.yml").write_text(f"""name: SettingsBehaviorTests
options:
  deploymentTarget:
    macOS: "13.0"
targets:
  SettingsBehaviorTests:
    type: tool
    platform: macOS
    sources:
      - path: {q(root / 'apps/apple_host/AetherHost')}
        excludes: [AetherHostApp.swift]
      - path: {q(root / 'apps/apple_host/HostKit')}
      - path: {q(root / 'apps/apple_host/Tests/SettingsBehaviorTests.swift')}
    settings:
      base:
        ARCHS: arm64
        SWIFT_VERSION: "5.9"
        CLANG_CXX_LANGUAGE_STANDARD: "c++17"
        CODE_SIGNING_ALLOWED: NO
        SWIFT_OBJC_BRIDGING_HEADER: {q(root / 'apps/apple_host/HostKit/AetherHost-Bridging-Header.h')}
        HEADER_SEARCH_PATHS: [{q(root / 'abi/include')}]
        LIBRARY_SEARCH_PATHS: [{q(root / 'out/macos/debug/bridge/apple_host')}, {q(root / 'out/macos/debug/abi')}]
        OTHER_LDFLAGS: [-laether_apple_host_core, -lengine_api, -larchive]
        LD_RUNPATH_SEARCH_PATHS: [{q(root / 'out/macos/debug/bridge/apple_host')}, {q(root / 'out/macos/debug/abi')}]
""", encoding="utf-8")
    subprocess.run(["xcodegen", "generate", "--spec", str(project / "project.yml")], check=True, cwd=root)
    log = project / "build.log"
    with log.open("w") as output:
        result = subprocess.run(["xcodebuild", "-project", str(project / "SettingsBehaviorTests.xcodeproj"),
                                 "-scheme", "SettingsBehaviorTests", "-configuration", "Debug",
                                 "-derivedDataPath", str(derived), "build"], stdout=output, stderr=subprocess.STDOUT, cwd=root)
    if result.returncode:
        raise SystemExit(f"Build failed; see {log}")
    env = os.environ.copy()
    bundle = root / "out/apple_host/derived/Build/Products/Debug/AetherHost.app"
    if not bundle.exists():
        raise SystemExit("Build AetherHost first so bundled documents can be verified")
    env["AETHER_SETTINGS_APP_BUNDLE"] = str(bundle)
    subprocess.run([str(derived / "Build/Products/Debug/SettingsBehaviorTests")], check=True, cwd=root, env=env, timeout=60)
    for test, sources in [
        ("SettingsStore", ["ShellStrings", "SettingsStore"]),
        ("ShellStrings", ["ShellStrings"]),
    ]:
        binary = root / "out/apple_host" / (test + "Tests")
        subprocess.run(["xcrun", "swiftc", *[str(root / f"apps/apple_host/AetherHost/{name}.swift") for name in sources],
                        str(root / f"apps/apple_host/Tests/{test}Tests.swift"), "-o", str(binary)], check=True, cwd=root)
        subprocess.run([str(binary)], check=True, cwd=root, timeout=60)


if __name__ == "__main__":
    main()
