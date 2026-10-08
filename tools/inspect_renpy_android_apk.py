#!/usr/bin/env python3
"""Record actual APK contents and compare raw Ren'Py assets/libraries with staging.

This is packaging evidence, never an installation or gameplay acceptance test.
"""

import argparse
import hashlib
import json
import re
import zipfile
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def inspect(apk: Path, build: Path, abi: str, output: Path) -> bool:
    output.mkdir(parents=True, exist_ok=True)
    result = {'artifact_kind': 'diagnostic_apk', 'gameplay': 'unverified',
              'apk': str(apk), 'abi': abi, 'package_bytes': 'failed', 'files': {}, 'errors': []}
    try:
        result['apk_sha256'] = sha256(apk)
        with zipfile.ZipFile(apk) as archive:
            names = archive.namelist()
            (output / 'apk-contents.txt').write_text('\n'.join(sorted(names)) + '\n')
            if len(names) != len(set(names)):
                result['errors'].append('APK contains duplicate ZIP paths')
            expected = {}
            assets = build / 'renpy_assets'
            for source in assets.rglob('*'):
                if source.is_file():
                    expected['assets/' + source.relative_to(assets).as_posix()] = source
            manifest = assets / 'renpy_mobile/manifest.properties'
            registrations = [line.split('=', 1)[1] for line in manifest.read_text().splitlines()
                             if line.startswith('staged_native_files=')]
            if len(registrations) != 1 or not registrations[0]:
                raise ValueError('Staging manifest must register its Ren\'Py native files exactly once')
            for native_file in registrations[0].split(','):
                # Only Ren'Py owns this exact set. Unrelated host libraries may
                # legitimately change bytes under AGP's normal stripping policy.
                if not re.fullmatch(r'(arm64-v8a|x86_64)/lib[A-Za-z0-9_+.-]+\.so', native_file) or '..' in native_file:
                    raise ValueError(f'Invalid staged native path: {native_file}')
                native_abi, name = native_file.split('/')
                if native_abi == abi:
                    expected[f'lib/{abi}/{name}'] = build / 'src/main/jniLibs' / native_file
            for required in ('assets/renpy_mobile/private/main.py', f'lib/{abi}/librenpython.so'):
                if required not in expected:
                    result['errors'].append(f'Staging lacks required input: {required}')
            for name, source in sorted(expected.items()):
                evidence = {'source_sha256': sha256(source), 'source_size': source.stat().st_size}
                if name not in names:
                    result['errors'].append(f'APK lacks staged raw file: {name}')
                    evidence['match'] = False
                else:
                    digest = hashlib.sha256()
                    with archive.open(name) as stream:
                        for block in iter(lambda: stream.read(1024 * 1024), b''):
                            digest.update(block)
                    evidence.update(apk_sha256=digest.hexdigest(), apk_size=archive.getinfo(name).file_size)
                    evidence['match'] = (evidence['source_sha256'] == evidence['apk_sha256'] and
                                         evidence['source_size'] == evidence['apk_size'])
                    if not evidence['match']:
                        result['errors'].append(f'APK file differs from staged input: {name}')
                result['files'][name] = evidence
    except (OSError, zipfile.BadZipFile, RuntimeError, ValueError) as exc:
        result['errors'].append(str(exc))
    passed = not result['errors']
    result['package_bytes'] = 'passed' if passed else 'failed'
    (output / 'apk-payload-checksums.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f"Actual APK raw Ren'Py bytes: {result['package_bytes']}; gameplay unverified. Evidence: {output}")
    for error in result['errors'][:10]:
        print(error)
    return passed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', required=True, type=Path)
    parser.add_argument('--godot-build', required=True, type=Path)
    parser.add_argument('--abi', required=True, choices=('arm64-v8a', 'x86_64'))
    parser.add_argument('--output-dir', required=True, type=Path)
    args = parser.parse_args()
    raise SystemExit(0 if inspect(args.apk, args.godot_build, args.abi, args.output_dir) else 1)


if __name__ == '__main__':
    main()
