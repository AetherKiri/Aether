#!/usr/bin/env python3
"""Run portable timing and real-engine iOS Simulator notification tests.

Notification injection verifies the adapter. It is not a physical device audio,
route, or CUA test. Supply an actual booted Simulator UUID from simctl.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    evidence = root / 'out/apple_host/evidence/ios-I3-lifecycle26'
    evidence.mkdir(parents=True, exist_ok=True)
    test = evidence / 'timing-tests'
    run(['clang++', '-std=c++17', '-Wall', '-Wextra', '-Werror',
         '-I' + str(root / 'apps/apple_host/IOSHost'),
         str(root / 'apps/apple_host/Tests/MobileSessionTimingTests.cpp'), '-o', str(test)])
    run([str(test)])
    if not args.skip_build:
        run([sys.executable, str(root / 'tools/apple_host_ios_build.py'),
             '--sdk', 'iphonesimulator', '--probe-app'])
    app = root / 'out/apple_host/ios/simulator/debug/bridge/apple_host/AetherHostIOSProbe.app'
    bundle = 'org.github.aetherkiri.host.iosprobe'
    subprocess.run(['xcrun', 'simctl', 'terminate', args.device, bundle],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run(['xcrun', 'simctl', 'install', args.device, str(app)])
    container = Path(run(['xcrun', 'simctl', 'get_app_container', args.device, bundle, 'data'],
                         capture_output=True).stdout.strip())
    report = container / 'Documents/mobile-lifecycle-test.json'
    old_stamp = report.stat().st_mtime_ns if report.exists() else None
    try:
        run(['xcrun', 'simctl', 'launch', '--stdout=' + str(evidence / 'stdout.log'),
             '--stderr=' + str(evidence / 'stderr.log'), args.device, bundle, '--lifecycle-self-test'])
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if report.exists() and report.stat().st_mtime_ns != old_stamp:
                result = json.loads(report.read_text())
                shutil.copy2(report, evidence / 'result.json')
                metadata = {
                    'sourceCommit': run(['git', '-C', str(root), 'rev-parse', 'HEAD'], capture_output=True).stdout.strip(),
                    'workingTreeDirty': bool(run(['git', '-C', str(root), 'status', '--porcelain'], capture_output=True).stdout.strip()),
                    'deviceUUID': args.device,
                    'simulator': True,
                    'configuration': 'Debug',
                    'providers': ['kirikiri'],
                    'renderer': 'software',
                    'output': 'raw_source',
                    'minimumOS': '18.0',
                    'sdk': run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], capture_output=True).stdout.strip(),
                    'devices': json.loads(run(['xcrun', 'simctl', 'list', 'devices', '-j'], capture_output=True).stdout),
                    'passed': bool(result.get('passed') and result.get('firstResumeDeltaZero')),
                }
                (evidence / 'manifest.json').write_text(json.dumps(metadata, indent=2) + '\n')
                if not result.get('passed') or not result.get('firstResumeDeltaZero'):
                    raise RuntimeError('mobile lifecycle fixture failed; see ' + str(evidence))
                print('PASS: ' + str(len(result['cases'])) + ' real-engine notification cases; ' + str(evidence))
                break
            time.sleep(0.1)
        else:
            raise RuntimeError('fixture report timed out; see ' + str(evidence))
    finally:
        subprocess.run(['xcrun', 'simctl', 'terminate', args.device, bundle], check=False)


if __name__ == '__main__':
    main()
