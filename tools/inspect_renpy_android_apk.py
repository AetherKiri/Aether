#!/usr/bin/env python3
"""Record actual APK contents and compare raw Ren'Py assets/libraries with staging.

This is packaging evidence, never an installation or gameplay acceptance test.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import tempfile
import zipfile
from pathlib import Path

from prepare_renpy_android_test_export import read_android_preset
from validate_renpy_mobile_payload import LIFECYCLE_SYMBOLS


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def parse_badging(text: str) -> dict:
    package = re.search(r'^package:\s*(.*)$', text, re.MULTILINE)
    minimum = re.search(r"^sdkVersion:'(\d+)'", text, re.MULTILINE)
    native = re.search(r'^native-code:\s*(.*)$', text, re.MULTILINE)
    if not package or not minimum or not native:
        raise ValueError('aapt badging lacks package, minimum SDK, or native ABI metadata')
    fields = dict(re.findall(r"(\w+)='([^']*)'", package.group(1)))
    target = re.search(r"^targetSdkVersion:'(\d+)'", text, re.MULTILINE)
    return {'package': fields['name'], 'version_code': int(fields['versionCode']),
            'version_name': fields['versionName'], 'min_sdk': int(minimum.group(1)),
            'target_sdk': int(target.group(1)) if target else None,
            'debuggable': bool(re.search(r'^application-debuggable\s*$', text, re.MULTILINE)),
            'native_abis': re.findall(r"'([^']+)'", native.group(1))}


def sdk_tool(root: Path, pattern: str) -> Path:
    tools = [path for path in root.glob(pattern) if path.is_file() and os.access(path, os.X_OK)]
    if not tools:
        raise ValueError(f'An installed Android SDK tool is required: {root}/{pattern}')
    return sorted(tools, key=lambda path: [int(token) for token in re.findall(r'\d+', str(path))])[-1]


def command_evidence(command: list[str], path: Path) -> str:
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=60)
    path.write_text(result.stdout)
    if result.returncode:
        raise ValueError(f'SDK command failed ({result.returncode}); see {path}')
    return result.stdout


def audit_android_manifest(apk: Path, sdk: Path, expected: dict, abi: str,
                           debuggable: bool, output: Path) -> dict:
    try:
        tool = sdk_tool(sdk, 'build-tools/*/aapt2')
    except ValueError:
        tool = sdk_tool(sdk, 'build-tools/*/aapt')
    actual = parse_badging(command_evidence([str(tool), 'dump', 'badging', str(apk)],
                                           output / 'apk-android-badging.txt'))
    expected = dict(expected, debuggable=debuggable, native_abis=[abi])
    errors = [f'Compiled AndroidManifest {key}: expected {value!r}, got {actual.get(key)!r}'
              for key, value in expected.items() if actual.get(key) != value]
    return {'status': 'failed' if errors else 'passed', 'tool': str(tool),
            'actual': actual, 'expected': expected, 'errors': errors}


def audit_native_elf(archive: zipfile.ZipFile, abi: str, ndk: Path,
                     minimum_sdk: int, output: Path) -> dict:
    reader = sdk_tool(ndk, 'toolchains/llvm/prebuilt/*/bin/llvm-readelf')
    nm = reader.with_name('llvm-nm')
    if not nm.is_file() or not os.access(nm, os.X_OK):
        raise ValueError(f'Installed Android NDK llvm-nm is required: {nm}')
    triple, machine = {'arm64-v8a': ('aarch64-linux-android', 183),
                       'x86_64': ('x86_64-linux-android', 62)}[abi]
    platform_libs = reader.parent.parent / 'sysroot/usr/lib' / triple / str(minimum_sdk)
    if not platform_libs.is_dir():
        raise ValueError(f'NDK platform stubs are unavailable for SDK {minimum_sdk}: {platform_libs}')
    system = {path.name for path in platform_libs.glob('*.so')}
    names = [name for name in archive.namelist() if name.startswith(f'lib/{abi}/') and name.endswith('.so')]
    packaged = {Path(name).name for name in names}
    libraries, errors = {}, []
    with tempfile.TemporaryDirectory(prefix='aether-apk-native-audit-') as temporary:
        work = Path(temporary)
        for name in sorted(names):
            basename = name.removeprefix(f'lib/{abi}/')
            if not re.fullmatch(r'lib[A-Za-z0-9_+.-]+\.so', basename) or '..' in basename:
                raise ValueError(f'Unsafe APK native path: {name}')
            library = work / basename
            with archive.open(name) as source, library.open('wb') as destination:
                shutil.copyfileobj(source, destination)
            with library.open('rb') as stream:
                header = stream.read(20)
            if len(header) < 20 or header[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<HH', header, 16) != (3, machine):
                raise ValueError(f'APK native library is not little-endian ELF64 DYN for {abi}: {name}')
            dynamic = command_evidence([str(reader), '--file-header', '--dynamic', str(library)],
                                       output / (basename + '.readelf.txt'))
            listing = command_evidence([str(nm), '-D', '--defined-only', str(library)],
                                       output / (basename + '.exports.txt'))
            needed = sorted(set(re.findall(r'\(NEEDED\).*\[([^]]+)\]', dynamic)))
            exports = sorted({line.split()[-1] for line in listing.splitlines() if line.split()})
            missing = set(needed) - system - packaged
            if missing:
                errors.append(f'Unpackaged native dependencies for {name}: {sorted(missing)}')
            if basename == 'librenpython.so':
                required = set(LIFECYCLE_SYMBOLS) | {'JNI_OnLoad'}
                absent = required - set(exports)
                leaks = [symbol for symbol in exports if symbol.startswith(('SDL_', 'avcodec_', 'avformat_', 'Py_', '_Py_'))]
                if absent:
                    errors.append(f'RenPy native entrypoints missing: {sorted(absent)}')
                if leaks:
                    errors.append(f'RenPy private implementations exported: {leaks[:12]}')
            libraries[name] = {'sha256': sha256(library), 'size': library.stat().st_size,
                               'elf_machine': machine, 'needed': needed, 'defined_exports': exports,
                               'missing_dependencies': sorted(missing)}
    if f'lib/{abi}/librenpython.so' not in libraries:
        errors.append('APK has no selected-ABI RenPy native library')
    return {'status': 'failed' if errors else 'passed', 'readelf': str(reader),
            'ndk_platform_sdk': minimum_sdk, 'libraries': libraries, 'errors': errors}


def inspect(apk: Path, build: Path, abi: str, output: Path, *,
            export_presets: Path | None = None, export_preset: str | None = None,
            build_type: str | None = None, android_sdk: Path | None = None,
            android_ndk: Path | None = None) -> bool:
    output.mkdir(parents=True, exist_ok=True)
    result = {'artifact_kind': 'diagnostic_apk', 'gameplay': 'unverified',
              'apk': str(apk), 'abi': abi, 'package_bytes': 'failed', 'files': {}, 'errors': [],
              'android_manifest': {'status': 'not_run'}, 'native_elf': {'status': 'not_run'}}
    try:
        result['apk_sha256'] = sha256(apk)
        with zipfile.ZipFile(apk) as archive:
            names = archive.namelist()
            (output / 'apk-contents.txt').write_text('\n'.join(sorted(names)) + '\n')
            if len(names) != len(set(names)):
                result['errors'].append('APK contains duplicate ZIP paths')
            if 'assets/renpy_mobile/manifest.properties' in names:
                raw_manifest = archive.read('assets/renpy_mobile/manifest.properties').decode('utf-8')
                (output / 'apk-renpy-manifest.properties').write_text(raw_manifest)
                result['renpy_payload_manifest'] = raw_manifest
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
            result['package_bytes'] = 'failed' if result['errors'] else 'passed'
            if export_presets is not None:
                if not export_preset or build_type not in ('debug', 'release') or android_sdk is None or android_ndk is None:
                    raise ValueError('Compiled manifest audit requires export preset, build type, installed SDK and NDK')
                _, _, expected = read_android_preset(export_presets, export_preset)
                result['android_manifest'] = {'status': 'failed'}
                result['android_manifest'] = audit_android_manifest(apk, android_sdk, expected, abi,
                                                                    build_type == 'debug', output)
                result['errors'].extend(result['android_manifest']['errors'])
                result['native_elf'] = {'status': 'failed'}
                result['native_elf'] = audit_native_elf(archive, abi, android_ndk, expected['min_sdk'], output)
                result['errors'].extend(result['native_elf']['errors'])
    except (OSError, zipfile.BadZipFile, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        result['errors'].append(str(exc))
    passed = not result['errors']
    (output / 'apk-payload-checksums.json').write_text(json.dumps(result, indent=2) + '\n')
    print(f"Actual APK raw Ren'Py bytes: {result['package_bytes']}; gameplay unverified. Evidence: {output}")
    if export_presets is not None:
        print('Actual compiled AndroidManifest:', json.dumps(result['android_manifest']))
        print('Actual packaged native ELF audit:', result['native_elf']['status'])
        native = result['native_elf'].get('libraries', {}).get(f'lib/{abi}/librenpython.so')
        if native:
            print('Actual librenpython.so SHA256 / DT_NEEDED / exports:', json.dumps(native))
    for error in result['errors'][:10]:
        print(error)
    return passed


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', required=True, type=Path)
    parser.add_argument('--godot-build', required=True, type=Path)
    parser.add_argument('--abi', required=True, choices=('arm64-v8a', 'x86_64'))
    parser.add_argument('--output-dir', required=True, type=Path)
    parser.add_argument('--export-presets', type=Path,
                        help='require a real SDK compiled-manifest and packaged ELF audit')
    parser.add_argument('--export-preset')
    parser.add_argument('--build-type', choices=('debug', 'release'))
    parser.add_argument('--android-sdk', type=Path)
    parser.add_argument('--android-ndk', type=Path)
    args = parser.parse_args()
    audit_arguments = (args.export_presets, args.export_preset, args.build_type, args.android_sdk, args.android_ndk)
    if any(argument is not None for argument in audit_arguments) and not all(argument is not None for argument in audit_arguments):
        parser.error('compiled APK audit requires all --export-presets/--export-preset/--build-type/--android-sdk/--android-ndk options')
    raise SystemExit(0 if inspect(args.apk, args.godot_build, args.abi, args.output_dir,
                                export_presets=args.export_presets, export_preset=args.export_preset,
                                build_type=args.build_type, android_sdk=args.android_sdk,
                                android_ndk=args.android_ndk) else 1)


if __name__ == '__main__':
    main()
