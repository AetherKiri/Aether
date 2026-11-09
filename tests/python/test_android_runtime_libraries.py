import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location("stage_android_runtime_libraries",
    Path(__file__).resolve().parents[2] / "tools/stage_android_runtime_libraries.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AndroidRuntimeLibrariesTests(unittest.TestCase):
    def test_configured_providers_are_packaged_and_disabled_providers_are_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build, source = root / "build", root / "staged"
            build.mkdir(); source.mkdir()
            (build / "build.gradle").write_text("plugins {}\n")
            (source / "libprovider.so").write_bytes(b"stripped provider")
            (source / "libdisabled.so").write_bytes(b"stale staging file")
            manifest = root / "runtime-libraries-debug.txt"
            manifest.write_text("/cmake/output/libprovider.so\n")
            module.stage(build, source, manifest, "arm64-v8a")
            module.stage(build, source, manifest, "arm64-v8a")
            output = build / "aether_runtime_jni/arm64-v8a"
            self.assertEqual((output / "libprovider.so").read_bytes(), b"stripped provider")
            self.assertFalse((output / "libdisabled.so").exists())
            self.assertEqual((build / "build.gradle").read_text().count("apply from:"), 1)
            manifest.write_text("")
            module.stage(build, source, manifest, "arm64-v8a")
            self.assertEqual(list(output.iterdir()), [])

    def test_missing_provider_fails_before_changing_the_existing_bundle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "build.gradle").write_text("plugins {}\n")
            manifest = root / "runtime-libraries-debug.txt"
            manifest.write_text("/cmake/output/libmissing.so\n")
            with self.assertRaisesRegex(ValueError, "Missing staged Android runtime"):
                module.stage(root, root, manifest, "arm64-v8a")
            self.assertFalse((root / "aether_runtime_jni").exists())
