import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


REPO = Path(__file__).resolve().parents[2]


@unittest.skipUnless(shutil.which("bash") and shutil.which("zip"), "requires bash and zip")
class IOSIPAPackagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="aether ipa tests ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.export = self.root / "export with spaces"
        (self.export / "Aether.xcodeproj").mkdir(parents=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        PROJECT_ROOT=str(REPO), CI="true", IPA_FIXTURE=str(self.root),
                        IPA_REAL_ZIP=shutil.which("zip"))
        self.tool("xcodebuild", '''
import json, os, pathlib, sys
args = sys.argv[1:]
build = pathlib.Path(next(a.split('=', 1)[1] for a in args if a.startswith('CONFIGURATION_BUILD_DIR=')))
derived = pathlib.Path(args[args.index('-derivedDataPath') + 1])
derived.mkdir(parents=True, exist_ok=True)
(derived / 'object.o').write_bytes(b'build object')
app = build / 'Aether.app'
(app / 'fonts').mkdir(parents=True, exist_ok=True)
(app / 'Aether').write_bytes(b'linked debug executable')
(app / 'Aether').chmod(0o755)
(app / 'fonts/default.otf').write_bytes(b'font')
(app / 'font-alias').symlink_to('fonts/default.otf')
pathlib.Path(os.environ['IPA_FIXTURE'], 'build.json').write_text(json.dumps({'inode': (app / 'Aether').stat().st_ino, 'derived': str(derived)}))
''')
        self.tool("zip", '''
import json, os, pathlib, sys
root = pathlib.Path(os.environ['IPA_FIXTURE'])
before = json.loads((root / 'build.json').read_text())
assert pathlib.Path('Payload/Aether.app/Aether').stat().st_ino == before['inode'], 'app was copied'
assert pathlib.Path(before['derived']).exists() == (os.environ['CI'] != 'true')
if os.environ.get('IPA_FAIL_ZIP'):
    pathlib.Path(sys.argv[2]).write_bytes(b'incomplete archive')
    sys.exit(23)
os.execv(os.environ['IPA_REAL_ZIP'], [os.environ['IPA_REAL_ZIP'], *sys.argv[1:]])
''')

    def tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + body)
        path.chmod(0o755)

    def package(self):
        # Execute the production function with only xcodebuild substituted;
        # renaming, ZIP creation, permissions and failure recovery are real.
        script = (REPO / "scripts/build_ios.sh").read_text()
        function = script.split("package_ios_unsigned_ipa() {", 1)[1].split("\nwith_ios_only_gdextension()", 1)[0]
        return subprocess.run(["bash", "-c", "set -euo pipefail\npackage_ios_unsigned_ipa() {" + function +
                               '\npackage_ios_unsigned_ipa "$1" debug', "ipa-test", str(self.export)],
                              env=self.env, capture_output=True, text=True)

    def test_ci_packages_existing_bundle_without_copy_and_frees_xcode_objects(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with zipfile.ZipFile(self.export / "Aether-Debug-Unsigned.ipa") as archive:
            self.assertEqual(archive.read("Payload/Aether.app/Aether"), b"linked debug executable")
            self.assertTrue(archive.getinfo("Payload/Aether.app/Aether").external_attr >> 16 & 0o111)
            self.assertEqual(archive.read("Payload/Aether.app/font-alias"), b"fonts/default.otf")
        for name in ("Payload", "build", "DerivedData"):
            self.assertFalse((self.export / name).exists())

    def test_local_packaging_preserves_incremental_xcode_objects(self):
        self.env["CI"] = "false"
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.export / "DerivedData/object.o").read_bytes(), b"build object")

    def test_zip_failure_restores_built_app_and_removes_partial_archive(self):
        self.env["IPA_FAIL_ZIP"] = "1"
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.export / "build/Aether.app/Aether").read_bytes(), b"linked debug executable")
        self.assertFalse((self.export / "Aether-Debug-Unsigned.ipa").exists())


if __name__ == "__main__":
    unittest.main()
