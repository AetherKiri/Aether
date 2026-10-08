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


if __name__ == "__main__":
    unittest.main()
