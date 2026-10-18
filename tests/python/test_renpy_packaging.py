import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]


def module(name):
    spec = importlib.util.spec_from_file_location(name, REPO / "tools" / (name + ".py"))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class RenpyPackagingTests(unittest.TestCase):
    def test_android_keeps_the_generated_activity_and_stages_outside_export_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); build = root / "build"; runtime = root / "runtime"
            build.mkdir(); (build / "build.gradle").write_text("plugins {}\n")
            app = build / "src/com/godot/game/GodotApp.java"; app.parent.mkdir(parents=True)
            app.write_text("public class GodotApp extends GodotActivity { public void customLifecycle() {} }")
            for name in ("java", "jni", "assets"):
                (runtime / name).mkdir(parents=True)
                (runtime / name / "fixture").write_text(name)
            stage = module("stage_renpy_android").stage
            stage(build, runtime); stage(build, runtime)
            self.assertIn("extends org.renpy.android.PythonSDLActivity", app.read_text())
            self.assertIn("customLifecycle", app.read_text())
            self.assertEqual((build / "build.gradle").read_text().count("apply from:"), 1)
            for name in ("java", "jni", "assets"):
                self.assertEqual((build / ("aether_renpy_" + name) / "fixture").read_text(), name)

    def test_macos_code_moves_to_frameworks_and_repeated_staging_preserves_import_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); runtime = root / "runtime"; app = root / "Aether.app"
            library = runtime / "lib/py3-mac-universal/librenpython.dylib"
            extension = runtime / "lib/python3.12/site-packages/greenlet/_greenlet.so"
            for file in (library, extension):
                file.parent.mkdir(parents=True, exist_ok=True); file.write_bytes(b"original code")
            (runtime / "renpy.py").write_text("engine entry")
            stage = module("stage_renpy_bundle").stage
            stage("macos", runtime, app); stage("macos", runtime, app)
            packaged = app / "Contents/Resources/renpy-runtime"
            self.assertTrue((packaged / "lib/py3-mac-universal").is_symlink())
            self.assertTrue((packaged / extension.relative_to(runtime)).is_symlink())
            self.assertEqual((packaged / library.relative_to(runtime)).read_bytes(), b"original code")
            self.assertEqual(library.read_bytes(), b"original code")
            self.assertTrue((app / "Contents/Frameworks/renpy-runtime/_greenlet.so").is_file())

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("plutil"), "Xcode project parsing requires macOS")
    def test_ios_export_contains_loose_python_and_both_embedded_frameworks_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); project = root / "Aether.xcodeproj"; project.mkdir()
            runtime = root / "runtime"; (runtime / "renpy-runtime").mkdir(parents=True)
            (runtime / "renpy-runtime/renpy.py").write_text("engine entry")
            for name in ("AetherRenpy", "MetalANGLE"):
                framework = runtime / "Frameworks" / (name + ".framework")
                framework.mkdir(parents=True); (framework / name).write_bytes(b"native code")
            stage_module = module("stage_renpy_ios")
            data = {"archiveVersion":"1", "objectVersion":"56", "rootObject":"PROJECT", "objects": {
                "PROJECT":{"isa":"PBXProject", "targets":["TARGET"], "mainGroup":"GROUP"},
                "GROUP":{"isa":"PBXGroup", "children":[]},
                "TARGET":{"isa":"PBXNativeTarget", "buildPhases":["RESOURCES"]},
                "RESOURCES":{"isa":"PBXResourcesBuildPhase", "files":[]}}}
            file = project / "project.pbxproj"
            file.write_text(stage_module.openstep(data))
            stage_module.stage(project, runtime); stage_module.stage(project, runtime)
            result = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(file)]))
            objects = result["objects"]
            self.assertEqual(len(objects["RESOURCES"]["files"]), 1)
            phases = [objects[item] for item in objects["TARGET"]["buildPhases"]]
            copies = [phase for phase in phases if phase["isa"] == "PBXCopyFilesBuildPhase"]
            self.assertEqual(len(copies), 1); self.assertEqual(len(copies[0]["files"]), 2)
            for item in copies[0]["files"]:
                self.assertIn("CodeSignOnCopy", objects[item]["settings"]["ATTRIBUTES"])
            self.assertTrue((root / "Aether/renpy-runtime/renpy.py").is_file())


if __name__ == "__main__":
    unittest.main()
