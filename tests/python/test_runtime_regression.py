import importlib.util
import json
import plistlib
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace


SPEC = importlib.util.spec_from_file_location(
    "runtime_regression", Path(__file__).resolve().parents[2] / "tools/run_runtime_regression.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class DeviceCompletionTests(unittest.TestCase):
    def test_exported_macos_app_uses_its_own_pack_without_path_override(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Example.app"
            executable = app / "Contents/MacOS/Example"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"fixture")
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Example"}))
            args = SimpleNamespace(app=app, project=None, godot="unused")
            self.assertEqual(RUNNER.macos_command(args), [str(executable.resolve())])
            executable.unlink()
            with self.assertRaises(ValueError):
                RUNNER.macos_command(args)

    def test_editor_launch_retains_project_path(self):
        args = SimpleNamespace(app=None, project=Path("example"), godot="godot")
        self.assertEqual(RUNNER.macos_command(args), ["godot", "--path", str(Path("example").resolve())])

    def test_pass_before_engine_teardown_is_not_completion(self):
        self.assertIsNone(RUNNER.cleanup_result({"events": [{"event": "passed"}]}))

    def test_success_requires_pass_immediately_before_cleanup(self):
        for earlier in ([], [{"event": "failed"}], [{"event": "step_pass"}]):
            with self.subTest(earlier=earlier):
                self.assertIsNone(RUNNER.cleanup_result({"events": earlier + [
                    {"event": "cleanup_complete", "exit_code": 0}]}))
        self.assertEqual(RUNNER.cleanup_result({"events": [
            {"event": "passed"}, {"event": "cleanup_complete", "exit_code": 0}]}), 0)

    def test_failure_can_complete_without_becoming_success(self):
        self.assertEqual(RUNNER.cleanup_result({"events": [
            {"event": "failed"}, {"event": "cleanup_complete", "exit_code": 2}]}), 2)

    def test_partial_or_malformed_completion_is_not_accepted(self):
        for final in (None, {}, {"event": "cleanup_complete"},
                {"event": "cleanup_complete", "exit_code": "0"},
                {"event": "cleanup_complete", "exit_code": False}):
            with self.subTest(final=final):
                self.assertIsNone(RUNNER.cleanup_result({"events": [{"event": "passed"}, final]}))

    def test_invalid_device_report_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            for value in ([], {"events": {}}, {"events": None}):
                with self.subTest(value=value):
                    path.write_text(json.dumps(value))
                    with self.assertRaises(ValueError):
                        RUNNER.read_report(path)


if __name__ == "__main__":
    unittest.main()
