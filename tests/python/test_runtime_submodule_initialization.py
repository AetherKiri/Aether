import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / ".github/scripts/initialize-private-runtime-submodules.sh"


class RuntimeSubmoduleInitializationTests(unittest.TestCase):
    def test_private_build_initializes_every_pinned_runtime_recursively(self):
        configured = subprocess.check_output(
            ["git", "config", "-f", str(REPO / ".gitmodules"), "--get-regexp",
             r"submodule\..*\.path"],
            text=True,
        )
        expected = {line.split(None, 1)[1] for line in configured.splitlines()}
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            log = temporary / "git-calls.jsonl"
            git = temporary / "git"
            git.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, sys\n"
                "with open(os.environ['GIT_CALL_LOG'], 'a') as output:\n"
                "    output.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            )
            git.chmod(0o755)
            environment = dict(
                os.environ,
                PATH=str(temporary) + os.pathsep + os.environ["PATH"],
                RUNNER_TEMP=str(temporary),
                GIT_CALL_LOG=str(log),
                AETHER_INTERNAL_DEPLOY_KEY="test-only-internal-key",
                AETHER_SOFTPAL_DEPLOY_KEY="test-only-softpal-key",
            )
            subprocess.run(["bash", str(SCRIPT)], env=environment, check=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]

        initialized = {
            argument for call in calls for argument in call
            if argument.startswith("packages/")
        }
        self.assertEqual(initialized, expected)
        for runtime in expected - {"packages/AetherSoftPal"}:
            with self.subTest(runtime=runtime):
                self.assertTrue(any(
                    call[:2] == ["submodule", "update"]
                    and "--init" in call and "--recursive" in call
                    and runtime in call for call in calls
                ))


if __name__ == "__main__":
    unittest.main()
