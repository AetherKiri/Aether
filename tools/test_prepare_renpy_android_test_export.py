#!/usr/bin/env python3
"""Verify disposable test export configuration; no Android APK or SDK is run."""

import tempfile
import unittest
from pathlib import Path

from prepare_renpy_android_test_export import prepare, read_android_preset


PRESETS = '''[preset.0]
name="Android Debug"
platform="Android"
[preset.0.options]
package/unique_name="org.github.krkr2.aetherkiri"
package/name="Aether"
version/code=4501
version/name="1.0.7-alpha.3"
gradle_build/min_sdk=26
architectures/arm64-v8a=true
[preset.1]
name="Android Release"
platform="Android"
[preset.1.options]
package/unique_name="org.github.krkr2.aetherkiri"
package/name="Aether"
version/code=4501
version/name="1.0.7-alpha.3"
gradle_build/min_sdk=26
'''


class TestExportTests(unittest.TestCase):
    def test_source_and_release_are_preserved_raw_assets_and_native_are_copied(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, destination = root / 'source', root / 'test-export'
            source.mkdir()
            (source / 'export_presets.cfg').write_text(PRESETS)
            files = ['project.godot', '.godot/fixture-cache',
                     'android/build/renpy_assets/renpy_mobile/private/main.py',
                     'android/build/src/main/jniLibs/arm64-v8a/librenpython.so',
                     'android/build/build/outputs/old.apk', 'android/build/.gradle/cache',
                     'android/build/aether-renpy.gradle']
            for name in files:
                path = source / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('Disposable configuration fixture; not a runtime')
            result = prepare(source, destination, 'Android Debug', 'org.aetherkiri.renpy.debug')
            self.assertEqual(result['product_package'], 'org.github.krkr2.aetherkiri')
            self.assertEqual((source / 'export_presets.cfg').read_text(), PRESETS)
            config, section, debug = read_android_preset(destination / 'export_presets.cfg', 'Android Debug')
            self.assertEqual(debug['package'], 'org.aetherkiri.renpy.debug')
            self.assertEqual(config[section]['package/name'], '"Aether RenPy Test"')
            _, _, release = read_android_preset(destination / 'export_presets.cfg', 'Android Release')
            self.assertEqual(release['package'], 'org.github.krkr2.aetherkiri')
            for name in files:
                expected = not name.startswith(('.godot/', 'android/build/build/', 'android/build/.gradle/'))
                self.assertEqual((destination / name).exists(), expected, name)
            # Copies are independent; modifications cannot write back via a hard link.
            (destination / 'project.godot').write_text('changed')
            self.assertNotEqual((source / 'project.godot').read_text(), 'changed')

    def test_release_product_package_and_nonempty_destination_reject(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source'
            source.mkdir()
            (source / 'export_presets.cfg').write_text(PRESETS)
            for name, package in [('Android Release', 'org.aetherkiri.renpy.debug'),
                                  ('Android Debug', 'org.github.krkr2.aetherkiri'),
                                  ('Android Debug', 'org.bad-package.debug')]:
                with self.assertRaises(ValueError):
                    prepare(source, root / 'test-export', name, package)
            with self.assertRaisesRegex(ValueError, 'outside the source'):
                prepare(source, source / 'inside', 'Android Debug', 'org.aetherkiri.renpy.debug')
            destination = root / 'existing'
            destination.mkdir()
            (destination / 'keep').write_text('existing file')
            with self.assertRaisesRegex(ValueError, 'new or empty'):
                prepare(source, destination, 'Android Debug', 'org.aetherkiri.renpy.debug')
            self.assertEqual((destination / 'keep').read_text(), 'existing file')


if __name__ == '__main__':
    unittest.main()
