#!/usr/bin/env python3
"""Check production xctestrun transformation using real host filesystem fixtures.

The fixture plist/bundle directories exercise configuration and containment;
they are not compiled Apple bundles. No SDK, Simulator installation, XCTest,
native runtime, graphics, input or gameplay success is simulated or claimed.
"""

from __future__ import annotations

import ast
import argparse
import copy
import plistlib
import tempfile
import unittest
from pathlib import Path

import run_renpy_ios_device_acceptance as production


RUN_ID = "0123456789abcdef0123456789abcdef"
RUNNER_ID = "org.aetherkiri.renpy-ios-acceptance.xctrunner"
APP_ID = "org.aetherkiri.renpy-simulator.debug"


class DestinationArtifacts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="aether-ios-destination-artifacts-")
        self.root = Path(self.temporary.name)
        self.products = self.root / "Products with spaces"
        self.products.mkdir()
        self.runner = self.products / "Debug-iphonesimulator/RenPyAcceptance-Runner.app"
        self.test_bundle = self.runner / "PlugIns/RenPyAcceptance.xctest"
        self.test_bundle.mkdir(parents=True)
        (self.runner / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": RUNNER_ID, "CFBundleSupportedPlatforms": ["iPhoneSimulator"]}))
        (self.test_bundle / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.aetherkiri.renpy-ios-acceptance"}))
        self.target = {
            "BlueprintName": "RenPyAcceptance", "IsUITestBundle": True,
            "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/RenPyAcceptance-Runner.app",
            "TestBundlePath": "__TESTHOST__/PlugIns/RenPyAcceptance.xctest",
            "TestHostBundleIdentifier": RUNNER_ID,
            "UITargetAppPath": "__TESTROOT__/Aether.app",
            "DependentProductPaths": ["__TESTROOT__/Aether.app", "__TESTHOST__/PlugIns/RenPyAcceptance.xctest"],
            "TestingEnvironmentVariables": {
                "DYLD_FRAMEWORK_PATH": "__TESTROOT__/Debug-iphonesimulator:__PLATFORMS__/Developer/Library/Frameworks",
                "XCInjectBundleInto": "__TESTHOST__/RenPyAcceptance-Runner",
                "TEST_BUNDLE": "__TESTBUNDLE__",
                "SHARED_FRAMEWORKS": "__SHAREDFRAMEWORKS__"},
            "EnvironmentVariables": {"EXISTING_PARAMETER": "preserved"},
        }

    def tearDown(self):
        self.temporary.cleanup()

    def transform(self, configuration=None, runner=None, **kwargs):
        return production.configure_destination_artifacts(
            configuration if configuration is not None else {"RenPyAcceptance": self.target},
            self.products, runner or self.runner,
            kwargs.get("bundle_id", APP_ID), kwargs.get("run_id", RUN_ID), kwargs.get("overall_timeout", 600))

    def assert_destination(self, target):
        self.assertIs(target["UseDestinationArtifacts"], True)
        self.assertEqual(target["TestHostBundleIdentifier"], RUNNER_ID)
        self.assertEqual(target["UITargetAppBundleIdentifier"], APP_ID)
        self.assertEqual(target["TestBundleDestinationRelativePath"],
                         "__TESTHOST__/PlugIns/RenPyAcceptance.xctest")
        for key in ("TestHostPath", "TestBundlePath", "UITargetAppPath", "DependentProductPaths"):
            self.assertNotIn(key, target)
        self.assertEqual(target["EnvironmentVariables"], {
            "EXISTING_PARAMETER": "preserved", "AETHER_RENPY_RUN_ID": RUN_ID,
            "AETHER_RENPY_APP_BUNDLE_ID": APP_ID, "AETHER_RENPY_TEST_TIMEOUT": "600"})
        environment = target["TestingEnvironmentVariables"]
        self.assertEqual(environment["XCInjectBundleInto"], "__TESTHOST__/RenPyAcceptance-Runner")
        self.assertEqual(environment["TEST_BUNDLE"], "__TESTBUNDLE__")
        self.assertEqual(environment["SHARED_FRAMEWORKS"], "__SHAREDFRAMEWORKS__")
        self.assertEqual(environment["DYLD_FRAMEWORK_PATH"], str(self.products.resolve())
                         + "/Debug-iphonesimulator:__PLATFORMS__/Developer/Library/Frameworks")

    def test_legacy_original_configuration_becomes_destination_only(self):
        original = {"RenPyAcceptance": copy.deepcopy(self.target)}
        # The previous normal configuration still supplies installation paths;
        # it does not meet the documented destination-only contract.
        self.assertNotIn("UseDestinationArtifacts", original["RenPyAcceptance"])
        self.assertIn("UITargetAppPath", original["RenPyAcceptance"])
        result, runner_id = self.transform(original)
        self.assertEqual(runner_id, RUNNER_ID)
        self.assert_destination(result["RenPyAcceptance"])
        self.assertEqual(original["RenPyAcceptance"], self.target)
        # Exercise the actual plist serialization that production hands Xcode.
        self.assertEqual(plistlib.loads(plistlib.dumps(result)), result)

    def test_version_two_and_testroot_bundle_path(self):
        target = copy.deepcopy(self.target)
        target["TestBundlePath"] = "__TESTROOT__/Debug-iphonesimulator/RenPyAcceptance-Runner.app/PlugIns/RenPyAcceptance.xctest"
        configuration = {
            "TestPlan": {"Name": "actual-format-fixture", "IsDefault": True},
            "TestConfigurations": [{"Name": "Debug", "IsEnabled": True, "TestTargets": [target]}],
            "__xctestrun_metadata__": {"FormatVersion": 2}}
        result, _ = self.transform(configuration)
        self.assert_destination(result["TestConfigurations"][0]["TestTargets"][0])
        self.assertEqual(result["TestPlan"], configuration["TestPlan"])
        self.assertEqual(result["__xctestrun_metadata__"], {"FormatVersion": 2})
        for version in (1, 2):
            with self.subTest(version=version):
                self.assert_destination(self.transform({"RenPyAcceptance": copy.deepcopy(self.target),
                    "__xctestrun_metadata__": {"FormatVersion": version}})[0]["RenPyAcceptance"])

    def test_absolute_paths_and_normal_parent_alias(self):
        alias = self.root / "build-alias"
        alias.symlink_to(self.products, target_is_directory=True)
        target = copy.deepcopy(self.target)
        target["TestHostPath"] = str(alias / self.runner.relative_to(self.products))
        target["TestBundlePath"] = str(alias / self.test_bundle.relative_to(self.products))
        self.assert_destination(self.transform({"RenPyAcceptance": target})[0]["RenPyAcceptance"])

    def test_mandatory_source_paths_testing_environment_and_format(self):
        for key in ("TestHostPath", "TestBundlePath", "TestingEnvironmentVariables"):
            with self.subTest(key=key):
                target = copy.deepcopy(self.target)
                del target[key]
                with self.assertRaises(production.Failed):
                    self.transform({"RenPyAcceptance": target})
        for key in ("TestingEnvironmentVariables", "EnvironmentVariables"):
            for value in (None, [], {"value": 1}, {"value": True}):
                with self.subTest(key=key, value=value):
                    target = copy.deepcopy(self.target)
                    target[key] = value
                    with self.assertRaises(production.Failed):
                        self.transform({"RenPyAcceptance": target})
        for metadata in ([], {}, {"FormatVersion": 3}, {"FormatVersion": True}, {"FormatVersion": "2"}):
            with self.subTest(metadata=metadata), self.assertRaises(production.Failed):
                self.transform({"RenPyAcceptance": copy.deepcopy(self.target), "__xctestrun_metadata__": metadata})

    def test_duplicate_ui_or_additional_non_ui_targets_are_rejected(self):
        for is_ui in (True, False):
            with self.subTest(is_ui=is_ui), self.assertRaises(production.Failed):
                extra = {**copy.deepcopy(self.target), "IsUITestBundle": is_ui}
                self.transform({"RenPyAcceptance": copy.deepcopy(self.target), "Another": extra})
        configuration = {"TestConfigurations": [{"TestTargets": [copy.deepcopy(self.target), copy.deepcopy(self.target)]}],
                         "__xctestrun_metadata__": {"FormatVersion": 2}}
        with self.assertRaises(production.Failed):
            self.transform(configuration)
        for is_ui in (False, 1, "true", None):
            with self.subTest(is_ui=is_ui), self.assertRaises(production.Failed):
                self.transform({"RenPyAcceptance": {**copy.deepcopy(self.target), "IsUITestBundle": is_ui}})

    def test_host_path_and_identity_must_match_selected_actual_runner(self):
        other = self.products / "another.app"
        other.mkdir()
        cases = [str(other), "__TESTHOST__", "__PLATFORMS__/runner.app", "relative.app",
                 "__TESTROOT__/Debug-iphonesimulator/../Debug-iphonesimulator/RenPyAcceptance-Runner.app"]
        for path in cases:
            with self.subTest(path=path), self.assertRaises(production.Failed):
                self.transform({"RenPyAcceptance": {**copy.deepcopy(self.target), "TestHostPath": path}})
        with self.assertRaises(production.Failed):
            self.transform({"RenPyAcceptance": {**copy.deepcopy(self.target), "TestHostBundleIdentifier": "other.runner"}})
        alias = self.products / "runner.app"
        alias.symlink_to(self.runner, target_is_directory=True)
        with self.assertRaises(production.Failed):
            self.transform(runner=alias)

    def test_missing_wrong_platform_and_invalid_bundle_metadata(self):
        runner_info = self.runner / "Info.plist"
        for info in ({}, {"CFBundleIdentifier": RUNNER_ID},
                     {"CFBundleIdentifier": APP_ID, "CFBundleSupportedPlatforms": ["iPhoneSimulator"]},
                     {"CFBundleIdentifier": RUNNER_ID, "CFBundleSupportedPlatforms": ["iPhoneOS"]},
                     {"CFBundleIdentifier": RUNNER_ID, "CFBundleSupportedPlatforms": "iPhoneSimulator"}):
            with self.subTest(info=info):
                runner_info.write_bytes(plistlib.dumps(info))
                with self.assertRaises(production.Failed):
                    self.transform()
        runner_info.write_bytes(plistlib.dumps({"CFBundleIdentifier": RUNNER_ID,
                                               "CFBundleSupportedPlatforms": ["iPhoneSimulator"]}))
        bundle_info = self.test_bundle / "Info.plist"
        for info in ({}, {"CFBundleIdentifier": ""}, {"CFBundleIdentifier": "bad/bundle"}):
            with self.subTest(info=info):
                bundle_info.write_bytes(plistlib.dumps(info))
                with self.assertRaises(production.Failed):
                    self.transform()
        bundle_info.unlink()
        with self.assertRaises(production.Failed):
            self.transform()

    def test_test_bundle_escape_wrong_embedding_and_links_are_rejected(self):
        outside = self.root / "outside.xctest"
        outside.mkdir()
        for path in (str(outside), str(self.runner), str(self.runner / "Info.plist")):
            with self.subTest(path=path), self.assertRaises(production.Failed):
                self.transform({"RenPyAcceptance": {**copy.deepcopy(self.target), "TestBundlePath": path}})
        inside_link = self.runner / "PlugIns/linked.xctest"
        inside_link.symlink_to(self.test_bundle, target_is_directory=True)
        outside_link = self.runner / "PlugIns/escaped.xctest"
        outside_link.symlink_to(outside, target_is_directory=True)
        for link in (inside_link, outside_link):
            with self.subTest(link=link), self.assertRaises(production.Failed):
                self.transform({"RenPyAcceptance": {**copy.deepcopy(self.target), "TestBundlePath": str(link)}})
        # Even a symlink to a valid actual metadata file is refused.
        info = self.test_bundle / "Info.plist"
        moved = self.root / "test-info.plist"
        info.rename(moved)
        info.symlink_to(moved)
        with self.assertRaises(production.Failed):
            self.transform()

    def test_configuration_identity_and_existing_destination_input_are_rejected(self):
        for key, values in (("run_id", ["", "g" * 32, RUN_ID.upper(), 1]),
                            ("bundle_id", ["", "bad/app", 1]),
                            ("overall_timeout", [59, 1201, True, "600"])):
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(production.Failed):
                    self.transform(**{key: value})
        result, _ = self.transform()
        with self.assertRaises(production.Failed):
            self.transform(result)

    def test_actual_directory_identity_alias_replacement_and_missing_guard(self):
        documents = self.root / "Documents"
        documents.mkdir()
        acceptance = production.Acceptance(argparse.Namespace(output_dir=self.root / "output", udid=None))
        acceptance.summary.update(status="failed", blocker="original gameplay failure")
        acceptance.staged_documents_identity = production.documents_identity(documents)
        alias = self.root / "host-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        acceptance.verify_staged_documents(alias / "Documents")
        self.assertTrue(acceptance.summary["startup_diagnostics"]["container_identity_checked"])
        self.assertTrue(acceptance.summary["startup_diagnostics"]["container_identity_same"])
        # Real directory replacement must fail even if the lexical path is
        # unchanged. The original inode remains alive at its renamed path.
        documents.rename(self.root / "old-documents")
        documents.mkdir()
        with self.assertRaises(production.Failed):
            acceptance.verify_staged_documents(documents)
        self.assertFalse(acceptance.summary["startup_diagnostics"]["container_identity_same"])
        self.assertEqual(acceptance.summary["status"], "failed")
        self.assertEqual(acceptance.summary["checks"], [])
        self.assertEqual(acceptance.summary["blocker"], "original gameplay failure")
        with self.assertRaises(production.Failed):
            acceptance.verify_staged_documents(self.root / "missing")
        self.assertFalse(acceptance.summary["startup_diagnostics"]["container_identity_checked"])
        self.assertIsNone(acceptance.summary["startup_diagnostics"]["container_identity_same"])
        with self.assertRaises(production.Failed):
            acceptance.verify_staged_documents(Path("relative/Documents"))
        link = self.root / "linked-documents"
        link.symlink_to(documents, target_is_directory=True)
        with self.assertRaises(production.Failed):
            acceptance.verify_staged_documents(link)
        self.assertNotIn(str(self.root), str(acceptance.summary["startup_diagnostics"]))
        acceptance.staged_documents_identity = None
        with self.assertRaises(production.Failed):
            acceptance.verify_staged_documents(documents)

    def test_production_order_keeps_all_installs_before_stage_and_budget_before_build(self):
        # Static ordering supplements the real transform/filesystem tests; it
        # does not execute or mock an Apple command or its successful result.
        source = Path(production.__file__).read_text()
        tree = ast.parse(source)
        acceptance = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "Acceptance")
        methods = {node.name: node for node in acceptance.body if isinstance(node, ast.FunctionDef)}
        run = methods["run"]
        calls = [(node.lineno, node.func.attr, [arg.value if isinstance(arg, ast.Constant) else None for arg in node.args])
                 for node in ast.walk(run) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                 and isinstance(node.func.value, ast.Name) and node.func.value.id == "self"]
        line = lambda name: next(number for number, operation, _ in calls if operation == name)
        install = next(number for number, operation, args in calls if operation == "simctl" and args[0] == "install")
        container = next(number for number, operation, args in calls if operation == "simctl" and args[0] == "get_app_container")
        deadline = next(node.lineno for node in ast.walk(run) if isinstance(node, ast.Assign)
                        and any(isinstance(target, ast.Attribute) and target.attr == "deadline" for target in node.targets))
        self.assertLess(install, deadline)
        self.assertLess(deadline, line("prepare_xcuitest"))
        self.assertLess(line("prepare_xcuitest"), container)
        self.assertLess(container, line("stage"))
        self.assertLess(line("stage"), line("start_xcuitest"))
        self.assertLess(line("start_xcuitest"), line("wait_game"))
        prepare_calls = [node for node in ast.walk(methods["prepare_xcuitest"]) if isinstance(node, ast.Call)
                         and isinstance(node.func, ast.Attribute) and node.func.attr == "simctl"]
        self.assertEqual(len(prepare_calls), 1)
        self.assertEqual(prepare_calls[0].args[0].value, "install")
        self.assertFalse(any(key.arg == "check" and isinstance(key.value, ast.Constant)
                             and key.value.value is False for key in prepare_calls[0].keywords))
        self.assertNotIn("build-for-testing", ast.get_source_segment(source, methods["start_xcuitest"]))
        self.assertIn("test-without-building", ast.get_source_segment(source, methods["start_xcuitest"]))
        startup = methods["start_xcuitest"]
        verification = next(node.lineno for node in ast.walk(startup) if isinstance(node, ast.Call)
                            and isinstance(node.func, ast.Attribute) and node.func.attr == "verify_staged_documents")
        ready_wait = next(node.lineno for node in ast.walk(startup) if isinstance(node, ast.Call)
                          and isinstance(node.func, ast.Attribute) and node.func.attr == "wait")
        self.assertLess(ready_wait, verification)


if __name__ == "__main__":
    unittest.main(verbosity=2)
