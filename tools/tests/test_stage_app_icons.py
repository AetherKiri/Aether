from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from stage_app_icons import ANDROID, stage_android_icons, stage_ios_icons
from stage_ios_game_import import read_project, write_project


class AppIconPackagingTests(unittest.TestCase):
    def test_android_preserves_launcher_and_adds_disabled_alternates(self):
        name = "{" + ANDROID + "}name"
        app = ET.fromstring(f'''<application xmlns:android="{ANDROID}">
          <activity android:name=".GodotApp" android:exported="false" />
          <activity-alias android:name=".GodotAppLauncher" android:targetActivity=".GodotApp" android:exported="true">
            <intent-filter><action android:name="android.intent.action.MAIN"/><category android:name="android.intent.category.LAUNCHER"/></intent-filter>
          </activity-alias><provider android:name="ExistingProvider" />
        </application>''')
        activity = ET.tostring(app.find("activity"))
        with tempfile.TemporaryDirectory() as folder:
            build = Path(folder)
            stage_android_icons(build, app)
            once = ET.tostring(app)
            stage_android_icons(build, app)
            self.assertEqual(ET.tostring(app), once)
            self.assertEqual(ET.tostring(app.find("activity")), activity)
            self.assertEqual(len(app.findall("activity-alias")), 3)
            primary, classic, dark = app.findall("activity-alias")
            self.assertEqual(primary.get(name), ".GodotAppLauncher")
            self.assertEqual(primary.get("{" + ANDROID + "}enabled"), "true")
            self.assertEqual(classic.get("{" + ANDROID + "}enabled"), "false")
            self.assertEqual(dark.get(name), "com.godot.game.AetherAstryxDarkLauncher")
            self.assertEqual(dark.get("{" + ANDROID + "}enabled"), "false")
            self.assertEqual(dark.get("{" + ANDROID + "}icon"), "@mipmap/aether_astryx_dark")
            self.assertEqual(ET.tostring(primary.find("intent-filter")), ET.tostring(classic.find("intent-filter")))
            self.assertEqual(ET.tostring(primary.find("intent-filter")), ET.tostring(dark.find("intent-filter")))
            self.assertTrue((build / "src/main/res/mipmap-anydpi-v26/aether_classic.xml").is_file())
            self.assertTrue((build / "src/main/res/drawable-nodpi/aether_astryx_task.png").is_file())
            self.assertTrue((build / "src/main/res/drawable-nodpi/aether_astryx_dark_task.png").is_file())
            self.assertTrue((build / "src/main/res/mipmap-anydpi-v26/aether_astryx_dark.xml").is_file())

    def test_ios_includes_ipad_and_phone_alternates_and_keeps_primary(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            project = root / "Aether.xcodeproj"
            project.mkdir()
            info = {"CFBundleIcons": {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}},
                    "CFBundleIcons~ipad": {"CFBundlePrimaryIcon": {"CFBundleIconName": "AppIcon"}},
                    "UIFileSharingEnabled": True}
            (root / "Info.plist").write_bytes(plistlib.dumps(info))
            data = {"rootObject": "ROOT", "objects": {
                "ROOT": {"targets": ["APP"], "mainGroup": "GROUP"},
                "APP": {"productType": "com.apple.product-type.application", "buildConfigurationList": "CONFIGS", "buildPhases": ["RESOURCES"]},
                "CONFIGS": {"buildConfigurations": ["DEBUG", "RELEASE"]},
                "DEBUG": {"buildSettings": {"INFOPLIST_FILE": "Info.plist"}},
                "RELEASE": {"buildSettings": {"INFOPLIST_FILE": "Info.plist"}},
                "GROUP": {"children": []},
                "RESOURCES": {"isa": "PBXResourcesBuildPhase", "files": []}}}
            write_project(project, data)
            stage_ios_icons(project)
            once = read_project(project)
            stage_ios_icons(project)
            self.assertEqual(read_project(project), once)
            output = plistlib.loads((root / "Info.plist").read_bytes())
            for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
                self.assertEqual(output[key]["CFBundlePrimaryIcon"], info[key]["CFBundlePrimaryIcon"])
                self.assertIn("Classic", output[key]["CFBundleAlternateIcons"])
                self.assertIn("AstryxDark", output[key]["CFBundleAlternateIcons"])
            self.assertIn("AetherClassic83.5", output["CFBundleIcons~ipad"]["CFBundleAlternateIcons"]["Classic"]["CFBundleIconFiles"])
            self.assertIn("AetherAstryxDark83.5", output["CFBundleIcons~ipad"]["CFBundleAlternateIcons"]["AstryxDark"]["CFBundleIconFiles"])
            self.assertTrue(output["UIFileSharingEnabled"])
            files = once["objects"]["RESOURCES"]["files"]
            self.assertEqual(len(files), 16)
            for build in files:
                ref = once["objects"][build]["fileRef"]
                self.assertTrue((root / once["objects"][ref]["path"]).is_file())


if __name__ == "__main__":
    unittest.main()
