#!/usr/bin/env python3
"""Verify generic text_input protocol and build an isolated native UI fixture."""
import argparse
from pathlib import Path
import plistlib
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=Path('out/apple_host/evidence/m3-text-input'))
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = root / 'apps/apple_host'
    for suite in ['PlatformTextInputTests', 'PlatformDialogTests']:
        binary = output / suite
        subprocess.run(['xcrun', 'swiftc', str(source / 'AetherHost/PlatformDialog.swift'),
                        str(source / 'Tests' / (suite + '.swift')), '-o', str(binary)], check=True)
        with (output / (suite + '.log')).open('w') as log:
            subprocess.run([str(binary)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
        print('PASS ' + suite, flush=True)
    app = output / 'PlatformTextInputTest.app'
    binary = app / 'Contents/MacOS/PlatformTextInputTest'
    binary.parent.mkdir(parents=True, exist_ok=True)
    with (app / 'Contents/Info.plist').open('wb') as stream:
        plistlib.dump({'CFBundleIdentifier': 'org.github.aetherkiri.text-input-test',
                      'CFBundleName': 'PlatformTextInputTest', 'CFBundleExecutable': binary.name,
                      'CFBundlePackageType': 'APPL', 'NSPrincipalClass': 'NSApplication',
                      'LSMinimumSystemVersion': '13.0'}, stream)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *[str(source / name) for name in
                    ['AetherHost/PlatformDialog.swift', 'AetherHost/PlatformDialogView.swift',
                     'AetherHost/ShellStrings.swift', 'Tests/PlatformTextInputUITestApp.swift']], '-o', str(binary)], check=True)
    print(f'UI fixture: {app}')
    print('ACK is a test callback; actual runtime request/response acceptance remains unverified.')


if __name__ == '__main__':
    main()
