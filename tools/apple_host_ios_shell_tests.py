#!/usr/bin/env python3
"""Run isolated mobile shell/gate tests in Debug and Release semantics on macOS.

This is model/store coverage, not a Simulator UI or agreement acceptance run.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
output = root / 'out/apple_host/evidence/ios-I1-product-shell'
output.mkdir(parents=True, exist_ok=True)
sources = [root / 'apps/apple_host/AetherHost' / (name + '.swift')
           for name in ['ShellStrings', 'LegalAcceptance', 'SettingsDocumentView']]
sources += [root / 'apps/apple_host/IOSApp/MobileShellState.swift',
            root / 'apps/apple_host/Tests/MobileShellFlowTests.swift']
for configuration in ['Debug', 'Release']:
    binary = output / ('model-tests-' + configuration.lower())
    flags = ['-DDEBUG'] if configuration == 'Debug' else []
    subprocess.run(['swiftc', *flags, '-parse-as-library', *map(str, sources), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary)], check=True, text=True, capture_output=True)
    (output / (configuration.lower() + '.log')).write_text(result.stdout)
    print(configuration + ': ' + result.stdout.strip())
