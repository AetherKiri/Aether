#!/usr/bin/env python3
"""Test APK byte diagnostics with ZIP fixtures; no mobile app is executed."""

import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from inspect_renpy_android_apk import inspect


class ApkInspectionTests(unittest.TestCase):
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
