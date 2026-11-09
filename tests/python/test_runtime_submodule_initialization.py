import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / ".github/scripts/initialize-private-runtime-submodules.sh"
BASH = "C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else "bash"

def initializer_command(test_git_dir=None):
    if os.name == "nt" and test_git_dir is not None:
        return [BASH, "-c", 'export PATH="$(cygpath -u "$1"):$PATH"; exec bash "$2"',
                "bash", str(test_git_dir), SCRIPT.as_posix()]
    return [BASH, SCRIPT.as_posix()]


class RuntimeSubmoduleInitializationTests(unittest.TestCase):
    def test_private_build_initializes_every_pinned_runtime_recursively(self):
        configured = subprocess.check_output(
            ["git", "config", "-f", str(REPO / ".gitmodules"), "--get-regexp",
             r"submodule..*.path"], text=True,
        )
        expected = {line.split(None, 1)[1] for line in configured.splitlines()}
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            key = temporary / "test-key"
            subprocess.run(
                ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                check=True, capture_output=True,
            )
            original = key.read_bytes().replace(b"\r\n", b"\n")
            log = temporary / "git-calls.jsonl"
            git = temporary / "git"
            git.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, shlex, sys\n"
                "from pathlib import Path\n"
                "command = shlex.split(os.environ['GIT_SSH_COMMAND'])\n"
                "key = Path(command[command.index('-i') + 1])\n"
                "data = key.read_bytes()\n"
                "assert b'\\r' not in data and not data.startswith(b'\\xef\\xbb\\xbf')\n"
                "assert data.endswith(b'\\n')\n"
                "assert os.name == 'nt' or key.stat().st_mode & 0o777 == 0o600\n"
                "with open(os.environ['GIT_CALL_LOG'], 'a') as output:\n"
                "    output.write(json.dumps(sys.argv[1:]) + '\\n')\n",
                encoding="utf-8",
            )
            git.chmod(0o755)
            environment = dict(
                os.environ,
                PATH=str(temporary) + os.pathsep + os.environ["PATH"],
                RUNNER_TEMP=temporary.as_posix(),
                GIT_CALL_LOG=str(log),
                AETHER_INTERNAL_DEPLOY_KEY=original.decode(),
                AETHER_SOFTPAL_DEPLOY_KEY=original.decode().replace("\n", "\r\n"),
                AETHER_LEAFTTT_DEPLOY_KEY="\ufeff" + original.decode().replace("\n", "\r\n").rstrip("\r\n"),
            )
            subprocess.run(initializer_command(temporary), env=environment, check=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertFalse(any(temporary.glob("aether-submodules.*")))

        initialized = {argument for call in calls for argument in call if argument.startswith("packages/")}
        self.assertEqual(initialized, expected)
        for runtime in expected - {"packages/AetherSoftPal"}:
            with self.subTest(runtime=runtime):
                self.assertTrue(any(
                    call[:2] == ["submodule", "update"]
                    and "--init" in call and "--recursive" in call and runtime in call
                    for call in calls
                ))

    def test_malformed_key_fails_before_any_fetch(self):
        with tempfile.TemporaryDirectory() as directory:
            environment = dict(os.environ, RUNNER_TEMP=Path(directory).as_posix(),
                               AETHER_INTERNAL_DEPLOY_KEY="invalid-test-key",
                               AETHER_SOFTPAL_DEPLOY_KEY="invalid-test-key",
                               AETHER_LEAFTTT_DEPLOY_KEY="invalid-test-key")
            result = subprocess.run([BASH, SCRIPT.as_posix()], env=environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Invalid private deploy key: internal", result.stderr)
            self.assertFalse(any(Path(directory).glob("aether-submodules.*")))


if __name__ == "__main__":
    unittest.main()
