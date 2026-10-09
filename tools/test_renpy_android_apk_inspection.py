#!/usr/bin/env python3
"""Test APK byte diagnostics with ZIP fixtures; no mobile app is executed."""

import json
import os
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from inspect_renpy_android_apk import audit_android_manifest, audit_native_elf, inspect, parse_badging
from validate_renpy_mobile_payload import LIFECYCLE_SYMBOLS


class ApkInspectionTests(unittest.TestCase):
    def test_badging_gate_rejects_wrong_package_sdk_version_debug_and_abi(self):
        # Command output fixture only, never evidence of a real compiled manifest.
        text = """package: name='org.other.app' versionCode='1' versionName='wrong'
sdkVersion:'24'
native-code: 'x86_64'
"""
        expected = {'package': 'org.aetherkiri.renpy.debug', 'version_code': 4501,
                    'version_name': '1.0.7-alpha.3', 'min_sdk': 26}
        with tempfile.TemporaryDirectory() as temporary, \
                patch('inspect_renpy_android_apk.sdk_tool', return_value=Path('/fixture-sdk/aapt2')), \
                patch('inspect_renpy_android_apk.command_evidence', return_value=text):
            report = audit_android_manifest(Path('/fixture.apk'), Path('/fixture-sdk'), expected,
                                            'arm64-v8a', True, Path(temporary))
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(len(report['errors']), 6)

    @unittest.skipUnless(os.environ.get('ANDROID_NDK_HOME'), 'real ELF metadata check requires an existing Android NDK')
    def test_real_ndk_elf_audit_records_closure_and_rejects_missing_dependency(self):
        # Real SDK compile/readelf/nm, but only a tiny ELF contract fixture. It
        # contains no Python/RenPy implementation and is never run as gameplay.
        ndk = Path(os.environ['ANDROID_NDK_HOME'])
        compilers = list(ndk.glob('toolchains/llvm/prebuilt/*/bin/aarch64-linux-android26-clang'))
        self.assertTrue(compilers, 'existing NDK must provide the API26 ARM64 compiler')
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'dependency.c').write_text('int contract_dependency(void) { return 1; }\n')
            symbols = tuple(LIFECYCLE_SYMBOLS) + ('JNI_OnLoad',)
            (root / 'contract.c').write_text('/* ELF metadata contract fixture, not RenPy. */\n'
                + '\n'.join(f'int {symbol}(void) {{ return 0; }}' for symbol in symbols)
                + '\nextern int contract_dependency(void);\nint contract_reference(void) { return contract_dependency(); }\n')
            for command in ([str(compilers[0]), '-shared', '-fPIC', str(root / 'dependency.c'),
                             '-Wl,-soname,libcontract_dependency.so', '-o', str(root / 'libcontract_dependency.so')],
                            [str(compilers[0]), '-shared', '-fPIC', str(root / 'contract.c'), '-L' + str(root),
                             '-lcontract_dependency', '-o', str(root / 'librenpython.so')]):
                subprocess.run(command, check=True, capture_output=True)
            apk = root / 'elf-contract.zip'
            for include_dependency in (False, True):
                with zipfile.ZipFile(apk, 'w') as archive:
                    archive.write(root / 'librenpython.so', 'lib/arm64-v8a/librenpython.so')
                    if include_dependency:
                        archive.write(root / 'libcontract_dependency.so', 'lib/arm64-v8a/libcontract_dependency.so')
                output = root / ('complete' if include_dependency else 'missing')
                output.mkdir()
                with zipfile.ZipFile(apk) as archive:
                    report = audit_native_elf(archive, 'arm64-v8a', ndk, 26, output)
                self.assertEqual(report['status'], 'passed' if include_dependency else 'failed')
                library = report['libraries']['lib/arm64-v8a/librenpython.so']
                self.assertIn('libcontract_dependency.so', library['needed'])
                self.assertTrue(set(symbols) <= set(library['defined_exports']))
                self.assertEqual(library['missing_dependencies'], [] if include_dependency else ['libcontract_dependency.so'])

    def test_badging_parser_keeps_compiled_manifest_fields_separate(self):
        # Parser contract only: this text is not a real aapt execution or APK.
        actual = parse_badging("""package: name='org.aetherkiri.renpy.debug' versionCode='4501' versionName='1.0.7-alpha.3'
sdkVersion:'26'
targetSdkVersion:'35'
application-debuggable
native-code: 'arm64-v8a'
""")
        self.assertEqual(actual, {'package': 'org.aetherkiri.renpy.debug', 'version_code': 4501,
                                 'version_name': '1.0.7-alpha.3', 'min_sdk': 26, 'target_sdk': 35,
                                 'debuggable': True, 'native_abis': ['arm64-v8a']})
        with self.assertRaisesRegex(ValueError, 'lacks package'):
            parse_badging('renpy_version=8.5.3\nnative_abis=arm64-v8a\n')

    def test_current_aapt2_min_sdk_format_and_conflicts(self):
        # Official AOSP aapt2 DumpManifest.cpp prints minSdkVersion; this is a
        # parser regression fixture, not evidence of an executed mobile APK.
        text = """package: name='org.aetherkiri.renpy.debug' versionCode='4501' versionName='1.0.7-alpha.3'
minSdkVersion:'26'
targetSdkVersion:'35'
application-debuggable
native-code: 'arm64-v8a'
"""
        self.assertEqual(parse_badging(text)['min_sdk'], 26)
        self.assertEqual(parse_badging(text + "sdkVersion:'26'\n")['min_sdk'], 26)
        with self.assertRaisesRegex(ValueError, 'conflicting minimum SDK'):
            parse_badging(text + "sdkVersion:'24'\n")
        with self.assertRaisesRegex(ValueError, 'lacks package'):
            parse_badging(text.replace("minSdkVersion:'26'\n", ''))

    def test_stale_native_bytes_and_missing_assets_reject(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            build = root / 'build'
            assets = build / 'renpy_assets/renpy_mobile/private'
            native = build / 'src/main/jniLibs/x86_64'
            assets.mkdir(parents=True)
            native.mkdir(parents=True)
            (assets / 'main.py').write_text('# ZIP contract fixture, not a runtime\n')
            manifest = assets.parent / 'manifest.properties'
            manifest.write_text('staged_native_files=x86_64/librenpython.so\n')
            (native / 'librenpython.so').write_bytes(b'ZIP fixture, not a native runtime')
            apk = root / 'fixture.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.write(manifest, 'assets/renpy_mobile/manifest.properties')
                archive.writestr('lib/x86_64/librenpython.so', b'stale ZIP fixture')
            output = root / 'diagnostics'
            self.assertFalse(inspect(apk, build, 'x86_64', output))
            result = json.loads((output / 'apk-payload-checksums.json').read_text())
            self.assertEqual(result['gameplay'], 'unverified')
            self.assertEqual(result['package_bytes'], 'failed')
            self.assertEqual(len(result['errors']), 2)
            self.assertIn('lib/x86_64/librenpython.so', (output / 'apk-contents.txt').read_text())

    def test_raw_asset_paths_and_identical_bytes_are_recorded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            build = root / 'build'
            assets = build / 'renpy_assets/renpy_mobile/private'
            native = build / 'src/main/jniLibs/arm64-v8a'
            assets.mkdir(parents=True)
            native.mkdir(parents=True)
            (assets / 'main.py').write_text('# ZIP contract fixture, not a runtime\n')
            manifest = assets.parent / 'manifest.properties'
            manifest.write_text('staged_native_files=arm64-v8a/librenpython.so,x86_64/librenpython.so\n')
            (native / 'librenpython.so').write_bytes(b'ZIP fixture, not a native runtime')
            (native / 'libhost.so').write_bytes(b'Unrelated host fixture before stripping')
            apk = root / 'fixture.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.write(assets / 'main.py', 'assets/renpy_mobile/private/main.py')
                archive.write(manifest, 'assets/renpy_mobile/manifest.properties')
                archive.write(native / 'librenpython.so', 'lib/arm64-v8a/librenpython.so')
                archive.writestr('lib/arm64-v8a/libhost.so', b'Unrelated host fixture after stripping')
            output = root / 'diagnostics'
            self.assertTrue(inspect(apk, build, 'arm64-v8a', output))
            result = json.loads((output / 'apk-payload-checksums.json').read_text())
            self.assertEqual(result['gameplay'], 'unverified')
            self.assertTrue(all(row['match'] for row in result['files'].values()))
            self.assertNotIn('lib/arm64-v8a/libhost.so', result['files'])
            self.assertNotIn('lib/x86_64/librenpython.so', result['files'])

    def test_invalid_manifest_native_path_rejects(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            build = root / 'build'
            assets = build / 'renpy_assets/renpy_mobile'
            assets.mkdir(parents=True)
            (assets / 'manifest.properties').write_text('staged_native_files=x86_64/../libhost.so\n')
            apk = root / 'fixture.apk'
            with zipfile.ZipFile(apk, 'w'):
                pass
            output = root / 'diagnostics'
            self.assertFalse(inspect(apk, build, 'x86_64', output))
            result = json.loads((output / 'apk-payload-checksums.json').read_text())
            self.assertIn('Invalid staged native path:', result['errors'][0])


if __name__ == '__main__':
    unittest.main()
