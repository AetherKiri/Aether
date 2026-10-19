"""Exercise the updater's workflow commands against local Git histories."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/submodule-update.yml"
CHECKER = ROOT / ".github/scripts/check-submodule-updates.py"


def workflow_command(name):
    step = WORKFLOW.read_text().split("      - name: " + name + "\n", 1)[1]
    step = step.split("\n      - name:", 1)[0]
    return textwrap.dedent(step.split("        run: |\n", 1)[1])


@unittest.skipUnless(shutil.which("git") and shutil.which("bash"), "Git and Bash are required")
class SubmoduleUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        PYTHONDONTWRITEBYTECODE="1")
        self.commits = {}
        self.repo = self.root / "parent"
        self.init_repo(self.repo)
        for name in ("A", "B"):
            child = self.root / name
            self.init_repo(child)
            commits = []
            for index in range(3):
                (child / "revision.txt").write_text(str(index))
                self.git(child, "add", "revision.txt")
                self.git(child, "commit", "-qm", "Revision " + str(index))
                commits.append(self.git(child, "rev-parse", "HEAD"))
            self.commits[name] = commits
            self.git(self.repo, "config", "-f", ".gitmodules",
                     "submodule.packages/" + name + ".path", "packages/" + name)
            self.git(self.repo, "config", "-f", ".gitmodules",
                     "submodule.packages/" + name + ".url", child.as_uri())
            self.pin(name, commits[0])
        self.git(self.repo, "add", ".gitmodules")
        self.git(self.repo, "commit", "-qm", "Initial pins")
        self.before = self.git(self.repo, "rev-parse", "HEAD")
        for name in ("A", "B"):
            self.pin(name, self.commits[name][1])
            self.git(self.repo, "commit", "-qm", "Update " + name)
        self.after = self.git(self.repo, "rev-parse", "HEAD")
        self.install_checker()

    def git(self, repo, *args):
        return subprocess.check_output(["git", *args], cwd=repo, env=self.env,
                                       text=True, stderr=subprocess.PIPE).strip()

    def init_repo(self, repo):
        repo.mkdir()
        self.git(repo, "init", "-q", "--initial-branch=main")
        self.git(repo, "config", "user.name", "Updater Test")
        self.git(repo, "config", "user.email", "updater@example.invalid")

    def pin(self, name, sha):
        self.git(self.repo, "update-index", "--add", "--cacheinfo",
                 "160000", sha, "packages/" + name)

    def install_checker(self):
        script = self.repo / ".github/scripts/check-submodule-updates.py"
        script.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(CHECKER, script)

    def ordinary_commit(self):
        (self.repo / "README").write_text("An ordinary change after both gitlink updates")
        self.git(self.repo, "add", "README")
        self.git(self.repo, "commit", "-qm", "Update README")
        self.after = self.git(self.repo, "rev-parse", "HEAD")

    def run_check(self, *, event="push", fetch_history=True, **overrides):
        output = self.root / "output"
        summary = self.root / "summary"
        env = dict(self.env, GITHUB_EVENT_NAME=event, PUSH_BEFORE=self.before,
                   PUSH_AFTER=self.after, TARGET_COMMIT="", INPUT_TARGET_COMMIT="",
                   INPUT_FORCE_ALL="false", INPUT_SUBMODULE_PATH="", GITHUB_RUN_NUMBER="7",
                   GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary),
                   RUNNER_TEMP=str(self.root))
        env.update(overrides)
        if fetch_history:
            subprocess.run(["bash", "-euo", "pipefail", "-c",
                            workflow_command("Fetch target commit history")],
                           cwd=self.repo, env=env, check=True, capture_output=True, text=True)
        result = subprocess.run(["bash", "-euo", "pipefail", "-c",
                                 workflow_command("Check submodule updates")],
                                cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def assert_both_updated(self, output):
        self.assertEqual(output["has_updates"], "true")
        self.assertEqual(output["updated_submodules"], "packages/A,packages/B")
        self.assertEqual(output["branch_prefix"], "submodule-update/multi")
        body = Path(output["pr_body_file"]).read_text()
        for name in ("A", "B"):
            self.assertIn("packages/" + name, body)
            staged = self.git(self.repo, "ls-files", "--stage", "packages/" + name).split()[1]
            self.assertEqual(staged, self.commits[name][2])

    def test_push_scans_both_commits_and_prepares_one_combined_pr(self):
        output = self.run_check(fetch_history=False)
        self.assert_both_updated(output)
        self.assertIn(self.before[:8] + ".." + self.after[:8],
                      Path(output["pr_body_file"]).read_text())

    def test_final_ordinary_commit_does_not_hide_earlier_submodule_changes(self):
        self.ordinary_commit()
        self.assert_both_updated(self.run_check())

    def test_shallow_checkout_fetches_push_start_outside_its_history(self):
        source = self.repo
        self.repo = self.root / "shallow"
        self.git(self.root, "clone", "-q", "--depth=1", source.as_uri(), str(self.repo))
        self.install_checker()
        missing = subprocess.run(["git", "cat-file", "-e", self.before + "^{commit}"],
                                 cwd=self.repo, env=self.env, capture_output=True)
        self.assertNotEqual(missing.returncode, 0)
        self.assert_both_updated(self.run_check())

    def test_force_push_compares_the_event_endpoints_instead_of_the_new_parent(self):
        old_tip = self.after
        self.git(self.repo, "checkout", "-qb", "rewritten", self.before)
        self.pin("A", self.commits["A"][1])
        self.git(self.repo, "commit", "-qm", "Rewrite with only A")
        self.before = old_tip
        self.after = self.git(self.repo, "rev-parse", "HEAD")
        # A is unchanged between the two tips. B changed from revision 1
        # back to 0, although the new tip's parent-to-tip diff only changes A.
        output = self.run_check()
        self.assertEqual(output["updated_submodules"], "packages/B")

    def test_manual_default_still_inspects_only_the_target_commit(self):
        output = self.run_check(event="workflow_dispatch")
        self.assertEqual(output["updated_submodules"], "packages/B")

    def test_manual_submodule_selection_is_preserved(self):
        output = self.run_check(event="workflow_dispatch", INPUT_SUBMODULE_PATH="packages/A")
        self.assertEqual(output["updated_submodules"], "packages/A")

    def test_manual_historical_target_selects_that_commits_submodule(self):
        target = self.git(self.repo, "rev-parse", "HEAD^1")
        self.git(self.repo, "remote", "add", "origin", self.repo.as_uri())
        output = self.run_check(event="workflow_dispatch", TARGET_COMMIT=target,
                                INPUT_TARGET_COMMIT=target)
        self.assertEqual(output["updated_submodules"], "packages/A")

    def test_manual_all_scans_every_registered_submodule(self):
        self.ordinary_commit()
        self.assert_both_updated(self.run_check(event="workflow_dispatch", INPUT_FORCE_ALL="true"))

    def test_initial_push_with_zero_before_scans_all_submodules(self):
        self.ordinary_commit()
        self.assert_both_updated(self.run_check(PUSH_BEFORE="0" * 40))

    def test_unchanged_push_range_does_not_prepare_an_update(self):
        output = self.run_check(PUSH_BEFORE=self.after)
        self.assertEqual(output, {"has_updates": "false"})

    def test_unavailable_push_start_fails_instead_of_reporting_no_updates(self):
        self.git(self.repo, "remote", "add", "origin", (self.root / "missing.git").as_uri())
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_check(PUSH_BEFORE="a" * 40)

    def test_explicit_exclusion_wins_over_all_or_explicit_selection(self):
        for selection in (["--all"], ["--submodule", "packages/A"]):
            result = subprocess.run(
                ["python3", str(CHECKER), *selection, "--exclude-submodule", "packages/A",
                 "--github-output", str(self.root / "excluded-output")],
                cwd=self.repo, env=self.env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            output = (self.root / "excluded-output").read_text()
            if selection == ["--all"]:
                self.assertIn("updated_submodules=packages/B", output)
                self.assertNotIn("updated_submodules=packages/A", output)
            else:
                self.assertTrue(output.endswith("has_updates=false\n"))

    def test_missing_push_range_is_rejected(self):
        env = dict(self.env, GITHUB_EVENT_NAME="push", PUSH_BEFORE="", PUSH_AFTER=self.after)
        result = subprocess.run(["bash", "-euo", "pipefail", "-c",
                                 workflow_command("Check submodule updates")],
                                cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing its before/after commit range", result.stderr)


if __name__ == "__main__":
    unittest.main()
