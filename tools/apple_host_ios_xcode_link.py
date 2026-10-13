#!/usr/bin/env python3
"""Export the actual CMake static dependency closure for the iOS Xcode target.

No hard-coded archive list: File API libraries come from the verified UIKit
probe link. The Xcode application compiles its own HostKit/UI objects.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys


def link_arguments(build):
    reply = build / '.cmake/api/v1/reply'
    index = json.loads(max(reply.glob('index-*.json'), key=lambda p: p.stat().st_mtime_ns).read_text())
    model = json.loads((reply / index['reply']['codemodel-v2']['jsonFile']).read_text())
    target = next(t for t in model['configurations'][0]['targets'] if t['name'] == 'AetherHostIOSProbe')
    info = json.loads((reply / target['jsonFile']).read_text())
    arguments = []
    for item in info['link']['commandFragments']:
        if item['role'] not in ['libraries', 'libraryPath', 'frameworkPath']:
            continue
        for token in shlex.split(item['fragment']):
            if token.startswith('-Wl,-rpath,'):
                continue # Build-machine lookup paths must not enter the App.
            if token.startswith(('-L', '-F')) and len(token) > 2:
                token = token[:2] + str((build / token[2:]).resolve())
            elif token.endswith('.a'):
                path = (build / token).resolve()
                if not path.is_file():
                    raise RuntimeError('missing link archive: ' + str(path))
                token = str(path)
            elif token.startswith('-Wl,'):
                # swiftc does not accept the clang-only spelling.
                parts = token[4:].split(',')
                for part in parts:
                    arguments += ['-Xlinker', part]
                continue
            arguments.append(token)
    if not any(p.endswith('/libaether_apple_host_core.a') for p in arguments):
        raise RuntimeError('host core missing from CMake closure')
    return arguments


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Debug')
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = root / 'out/apple_host/ios/link' / args.configuration
    output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, VCPKG_ROOT=os.environ.get('VCPKG_ROOT', str(root / '.devtools/vcpkg')))
    for platform, sdk in [('device', 'iphoneos'), ('simulator', 'iphonesimulator')]:
        build = root / 'out/apple_host/ios' / platform / args.configuration.lower()
        query = build / '.cmake/api/v1/query'
        query.mkdir(parents=True, exist_ok=True)
        (query / 'codemodel-v2').touch()
        if args.skip_build:
            subprocess.run(['cmake', '-S', str(root), '-B', str(build)], env=env, check=True)
        else:
            subprocess.run([sys.executable, str(root / 'tools/apple_host_ios_build.py'), '--sdk', sdk,
                            '--configuration', args.configuration, '--probe-app'], env=env, check=True)
        tokens = link_arguments(build)
        # Driver response-file quoting, never shell interpolation.
        text = '\n'.join('"' + token.replace('\\', '\\\\').replace('"', '\\"') + '"' for token in tokens) + '\n'
        (output / (sdk + '.rsp')).write_text(text)
        print('exported: ' + str(output / (sdk + '.rsp')))


if __name__ == '__main__':
    main()
