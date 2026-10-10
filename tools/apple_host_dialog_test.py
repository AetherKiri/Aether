#!/usr/bin/env python3
"""Run pure platform-dialog checks and build an isolated native UI test app."""
import argparse
import plistlib
import subprocess
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('out/apple_host/evidence/m3-dialog'))
    parser.add_argument('--host-abi', action='store_true', help='also test the HostKit wrapper; requires a built Debug host')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    evidence = args.output.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    source = root / 'apps/apple_host'
    binary = evidence / 'platform-dialog-tests'
    subprocess.run(['xcrun', 'swiftc', str(source / 'AetherHost/PlatformDialog.swift'),
                    str(source / 'Tests/PlatformDialogTests.swift'), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True, check=True)
    (evidence / 'tests.log').write_text(result.stdout)
    print(result.stdout.strip())
    app = evidence / 'PlatformDialogTest.app'
    executable = app / 'Contents/MacOS/PlatformDialogTest'
    executable.parent.mkdir(parents=True, exist_ok=True)
    with (app / 'Contents/Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleIdentifier': 'org.github.aetherkiri.dialog-test',
                      'CFBundleName': 'PlatformDialogTest', 'CFBundleExecutable': 'PlatformDialogTest',
                      'CFBundlePackageType': 'APPL', 'NSPrincipalClass': 'NSApplication',
                      'LSMinimumSystemVersion': '13.0'}, stream)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                    *[str(source / name) for name in ('AetherHost/PlatformDialog.swift',
                      'AetherHost/PlatformDialogView.swift', 'AetherHost/ShellStrings.swift',
                      'Tests/PlatformDialogUITestApp.swift')], '-o', str(executable)], check=True)
    if args.host_abi:
        objects = root / 'out/apple_host/derived/Build/Intermediates.noindex/AetherHost.build/Debug/AetherHost.build/Objects-normal/arm64'
        core = root / 'out/macos/debug/bridge/apple_host'
        abi = root / 'out/macos/debug/abi'
        response_test = evidence / 'platform-response-tests'
        subprocess.run(['xcrun', 'clang++', '-std=c++17', '-fobjc-arc', '-I', str(source / 'HostKit'),
                        '-I', str(root / 'abi/include'), str(source / 'Tests/PlatformResponseTests.mm'),
                        str(objects / 'EngineSession.o'), str(objects / 'MetalBridge.o'),
                        '-L', str(core), '-laether_apple_host_core', '-L', str(abi), '-lengine_api',
                        '-framework', 'AppKit', '-framework', 'Metal', '-framework', 'QuartzCore',
                        f'-Wl,-rpath,{core}', f'-Wl,-rpath,{abi}', '-o', str(response_test)], check=True)
        response = subprocess.run([str(response_test), str(evidence / 'abi-cache')], capture_output=True, text=True, check=True)
        (evidence / 'response-tests.log').write_text(response.stdout + response.stderr)
        print(response.stdout.strip())
    print(f'Native UI fixture: {app}')
    print('UI fixture uses test acknowledgments; this does not verify a private runtime provider.')


if __name__ == '__main__':
    main()
