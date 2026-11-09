import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "tools"))
import stage_ios_game_import as stage
import stage_renpy_ios

spec = importlib.util.spec_from_file_location("ios_signing", REPO / ".github/scripts/configure-ios-signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


@unittest.skipUnless(sys.platform == "darwin", "Requires Apple Foundation and Xcode project tools")
class IOSGameImportTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.project = self.root / "Aether.xcodeproj"
        self.project.mkdir()
        self.bundle = "org.aether.test"
        self.group = "group." + self.bundle + ".game-import"
        stage.write_plist(self.root / "Info.plist", {"CFBundleShortVersionString": "2.0", "CFBundleVersion": "5",
                          "CFBundleDocumentTypes": [{"CFBundleTypeName": "Existing", "LSItemContentTypes": ["public.text"]}]})
        stage.write_plist(self.root / "Host.entitlements", {"com.apple.developer.existing": True})
        settings = {"PRODUCT_BUNDLE_IDENTIFIER": self.bundle, "INFOPLIST_FILE": "Info.plist",
                    "CODE_SIGN_ENTITLEMENTS": "Host.entitlements", "OTHER_LDFLAGS": ["-force_load", "engine.a"]}
        stage.write_project(self.project, {"archiveVersion": "1", "objectVersion": "56", "rootObject": "ROOT", "objects": {
            "ROOT": {"isa": "PBXProject", "targets": ["APP"], "mainGroup": "GROUP", "productRefGroup": "PRODUCTS"},
            "GROUP": {"isa": "PBXGroup", "children": ["PRODUCTS"]},
            "PRODUCTS": {"isa": "PBXGroup", "children": []},
            "APP": {"isa": "PBXNativeTarget", "productType": "com.apple.product-type.application",
                    "buildConfigurationList": "CONFIGS", "buildPhases": ["RESOURCES"], "dependencies": []},
            "RESOURCES": {"isa": "PBXResourcesBuildPhase", "files": []},
            "CONFIGS": {"isa": "XCConfigurationList", "buildConfigurations": ["DEBUG", "RELEASE"]},
            "DEBUG": {"isa": "XCBuildConfiguration", "name": "Debug", "buildSettings": settings},
            "RELEASE": {"isa": "XCBuildConfiguration", "name": "Release", "buildSettings": settings},
        }})

    def test_staging_is_idempotent_and_embeds_a_separately_signed_extension(self):
        stage.stage(self.project)
        first = (self.project / "project.pbxproj").read_bytes()
        stage.stage(self.project)
        self.assertEqual(first, (self.project / "project.pbxproj").read_bytes())
        data = stage.read_project(self.project)
        objects = data["objects"]
        self.assertEqual(len(objects["ROOT"]["targets"]), 2)
        app = objects["APP"]
        dependency = objects[app["dependencies"][0]]
        extension = objects[dependency["target"]]
        self.assertEqual(extension["productType"], "com.apple.product-type.app-extension")
        for config in stage.configurations(objects, extension):
            self.assertEqual(config["buildSettings"]["PRODUCT_BUNDLE_IDENTIFIER"], self.bundle + ".GameImport")
            self.assertEqual(config["buildSettings"]["OTHER_LDFLAGS"], [])
            self.assertEqual(config["buildSettings"]["MARKETING_VERSION"], "2.0")
            self.assertEqual(config["buildSettings"]["CURRENT_PROJECT_VERSION"], "5")
        phases = [objects[key] for key in app["buildPhases"]]
        self.assertEqual(sum(p.get("dstSubfolderSpec") == "13" for p in phases), 1)
        host_entitlements = plistlib.loads((self.root / "Host.entitlements").read_bytes())
        self.assertTrue(host_entitlements["com.apple.developer.existing"])
        self.assertEqual(host_entitlements[stage.GROUP_KEY], [self.group])
        info = plistlib.loads((self.root / "Info.plist").read_bytes())
        self.assertEqual(len(info["CFBundleDocumentTypes"]), 2)
        self.assertIn("public.folder", info["CFBundleDocumentTypes"][1]["LSItemContentTypes"])
        self.assertEqual(info["AetherImportAppGroup"], self.group)
        # Ren'Py staging must still select the app after adding an extension.
        runtime = self.root / "runtime"
        (runtime / "renpy-runtime").mkdir(parents=True)
        (runtime / "Frameworks").mkdir()
        stage_renpy_ios.stage(self.project, runtime)

    def profiles(self, include_group=True):
        paths = []
        for index, bundle in enumerate((self.bundle, self.bundle + ".GameImport")):
            path = self.root / f"profile-{index}.plist"
            stage.write_plist(path, {"UUID": f"profile-{index}", "TeamIdentifier": ["TEAM"],
                                   "Entitlements": {"application-identifier": "TEAM." + bundle,
                                                    stage.GROUP_KEY: [self.group] if include_group else []}})
            paths.append(path)
        return paths

    def test_signing_assigns_each_profile_to_its_own_bundle(self):
        stage.stage(self.project)
        options = self.root / "ExportOptions.plist"
        signing.configure(self.project, self.bundle, "TEAM", self.profiles(), options)
        exported = plistlib.loads(options.read_bytes())
        self.assertEqual(exported["provisioningProfiles"], {self.bundle: "profile-0", self.bundle + ".GameImport": "profile-1"})
        data = stage.read_project(self.project)
        for index, key in enumerate(data["objects"]["ROOT"]["targets"]):
            for config in stage.configurations(data["objects"], data["objects"][key]):
                self.assertEqual(config["buildSettings"]["PROVISIONING_PROFILE_SPECIFIER"], f"profile-{index}")

    def test_missing_group_fails_before_changing_project(self):
        stage.stage(self.project)
        original = (self.project / "project.pbxproj").read_bytes()
        with self.assertRaisesRegex(ValueError, "must include App Group"):
            signing.configure(self.project, self.bundle, "TEAM", self.profiles(False), self.root / "export.plist")
        self.assertEqual(original, (self.project / "project.pbxproj").read_bytes())
        self.assertFalse((self.root / "export.plist").exists())

    @unittest.skipUnless(shutil.which("xcrun"), "Requires Swift")
    def test_native_folder_copy_and_crash_recovery(self):
        executable = self.root / "store-tests"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(REPO / "bridge/ios_game_import/GameImportStore.swift"),
                        str(REPO / "tests/ios/GameImportStoreTests.swift"), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    unittest.main()
