#!/usr/bin/env python3
"""Check that the real Xcode project mutation links AND embeds its runtime."""

import tempfile
import unittest
from pathlib import Path

from patch_renpy_ios_runtime_project import patch


PROJECT = '''// !$*UTF8*$!
{
objects = {
/* Begin PBXBuildFile section */
/* End PBXBuildFile section */
/* Begin PBXFileReference section */
/* End PBXFileReference section */
/* Begin PBXGroup section */
    111111111111111111111111 /* Aether */ = {
        isa = PBXGroup;
        children = (
        );
    };
/* End PBXGroup section */
/* Begin PBXFrameworksBuildPhase section */
    222222222222222222222222 /* Frameworks */ = {
        isa = PBXFrameworksBuildPhase;
        files = (
        );
    };
/* End PBXFrameworksBuildPhase section */
/* Begin PBXCopyFilesBuildPhase section */
    333333333333333333333333 /* Embed Frameworks */ = {
        isa = PBXCopyFilesBuildPhase;
        buildActionMask = 2147483647;
        dstPath = "";
        dstSubfolderSpec = 10;
        files = (
        );
    };
/* End PBXCopyFilesBuildPhase section */
};
}
'''


class RuntimeProjectTests(unittest.TestCase):
    def test_link_embed_and_idempotence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "project.pbxproj"
            framework = root / "AetherRenPyRuntime.framework"
            framework.mkdir()
            project.write_text(PROJECT)
            patch(project, framework)
            actual = project.read_text()
            self.assertIn("CodeSignOnCopy, RemoveHeadersOnCopy", actual)
            self.assertIn("path = Frameworks/AetherRenPyRuntime.framework", actual)
            link = actual.split("/* Begin PBXFrameworksBuildPhase section */")[1].split("/* End PBXFrameworksBuildPhase section */")[0]
            embed = actual.split("/* Begin PBXCopyFilesBuildPhase section */")[1].split("/* End PBXCopyFilesBuildPhase section */")[0]
            self.assertIn("AetherRenPyRuntime.framework in Frameworks */,", link)
            self.assertIn("AetherRenPyRuntime.framework in Embed Frameworks */,", embed)
            patch(project, framework)
            self.assertEqual(project.read_text(), actual)

    def test_missing_embed_phase_rejects_atomic_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "project.pbxproj"
            framework = root / "AetherRenPyRuntime.framework"
            framework.mkdir()
            original = PROJECT.replace("dstSubfolderSpec = 10;", "dstSubfolderSpec = 7;")
            project.write_text(original)
            with self.assertRaisesRegex(ValueError, "embed phase"):
                patch(project, framework)
            self.assertEqual(project.read_text(), original)

    def test_metalangle_is_embedded_without_host_linkage(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "project.pbxproj"
            framework = root / "AetherRenPyRuntime.framework"
            metalangle = root / "MetalANGLE.framework"
            framework.mkdir()
            metalangle.mkdir()
            project.write_text(PROJECT)
            patch(project, framework, metalangle)
            actual = project.read_text()
            link = actual.split("/* Begin PBXFrameworksBuildPhase section */")[1].split("/* End PBXFrameworksBuildPhase section */")[0]
            embed = actual.split("/* Begin PBXCopyFilesBuildPhase section */")[1].split("/* End PBXCopyFilesBuildPhase section */")[0]
            self.assertIn("AetherRenPyRuntime.framework in Frameworks */,", link)
            self.assertNotIn("MetalANGLE", link)
            self.assertIn("MetalANGLE.framework in Embed Frameworks */,", embed)
            patch(project, framework, metalangle)
            self.assertEqual(project.read_text(), actual)

    def test_previous_xcframework_host_link_is_removed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "project.pbxproj"
            framework = root / "AetherRenPyRuntime.framework"
            metalangle = root / "MetalANGLE.framework"
            framework.mkdir()
            metalangle.mkdir()
            project.write_text(PROJECT)
            patch(project, framework, metalangle)
            original = project.read_text().replace("MetalANGLE.framework", "MetalANGLE.xcframework")
            original = original.replace("/* Begin PBXBuildFile section */\n", "/* Begin PBXBuildFile section */\n"
                "A3F003000000000000000003 /* MetalANGLE.xcframework in Frameworks */ = {isa = PBXBuildFile; fileRef = A3F003000000000000000004 /* MetalANGLE.xcframework */; };\n")
            original = original.replace("        isa = PBXFrameworksBuildPhase;\n        files = (\n",
                "        isa = PBXFrameworksBuildPhase;\n        files = (\nA3F003000000000000000003 /* MetalANGLE.xcframework in Frameworks */,\n")
            project.write_text(original)
            patch(project, framework, metalangle)
            actual = project.read_text()
            self.assertNotIn("xcframework", actual)
            self.assertNotIn("MetalANGLE.framework in Frameworks", actual)
            self.assertEqual(actual.count("A3F003000000000000000004 /* MetalANGLE.framework */ ="), 1)


if __name__ == "__main__":
    unittest.main()
