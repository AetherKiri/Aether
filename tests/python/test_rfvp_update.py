"""Offline contract tests: no credentials, network, or upstream execution."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("rfvp_update", ROOT / ".github/scripts/rfvp-update.py")
bot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bot)
BASE, OLD, TARGET, HEAD = (c * 40 for c in "abcd")
REPO = "owner/project"


def pull(number=1, *, target=OLD, managed=False, files=None, **overrides):
    paths = files or [bot.PATH]
    state = {"base": BASE, "target": target, "head": HEAD}
    pr = {"number": number, "user": {"login": bot.BOT if managed else "human"},
          "head": {"sha": HEAD, "ref": "rfvp-update/test" if managed else "manual",
                   "repo": {"full_name": REPO}}, "base": {"ref": "main"},
          "draft": True, "changed_files": len(paths),
          "title": "chore(rfvp): update upstream to " + target[:12],
          "body": bot.description({"base": BASE, "target": target, "current": OLD}, HEAD,
                                  "success", "https://example.invalid/run") if managed else "",
          "_files": [{"filename": path} for path in paths], "_pin": target}
    pr.update(overrides)
    return pr


class API:
    repo = REPO

    def __init__(self, prs=()):
        self.prs = list(prs)
        self.base, self.target, self.current = BASE, TARGET, OLD
        self.status = "ahead"
        self.writes = []
        self.branch_exists = False
        self.ref_head = HEAD

    def get(self, suffix, repo=None):
        if suffix == "git/ref/heads/main":
            return {"object": {"sha": self.target if repo == bot.UPSTREAM else self.base}}
        if suffix.startswith("compare/"):
            return {"status": self.status}
        if suffix.startswith("pulls/"):
            return copy.deepcopy(next(p for p in self.prs if p["number"] == int(suffix.split('/')[1])))
        if suffix.startswith("git/ref/heads/"):
            if self.branch_exists or self.prs:
                return {"object": {"sha": self.ref_head}}
            raise HTTPError("https://api.github.com", 404, "missing", {}, None)
        if suffix.startswith("git/commits/"):
            return {"tree": {"sha": "e" * 40}}
        raise AssertionError(suffix)

    def pages(self, suffix):
        if suffix == "pulls?state=open":
            return iter(self.prs)
        return iter(self.get(suffix)["_files"])

    def pin(self, repo, commit):
        if commit == self.base:
            return self.current
        return next(p["_pin"] for p in self.prs if p["head"]["sha"] == commit)

    def write(self, suffix, data, method="POST"):
        self.writes.append((suffix, data, method))
        if suffix.startswith("git/refs/heads/"):
            for pr in self.prs:
                pr["head"]["sha"] = data["sha"]
        return {"sha": "f" * 40, "html_url": "https://github.com/owner/project/pull/2"}


class PlanningTests(unittest.TestCase):
    def test_up_to_date(self):
        api = API(); api.current = TARGET
        self.assertEqual(bot.plan(api)["action"], "skip")

    def test_new_sha_creates_only_rfvp_branch(self):
        p = bot.plan(API())
        self.assertEqual(p["action"], "create")
        self.assertEqual(p["branch"], bot.PREFIX + BASE[:12] + "-" + TARGET[:12])

    def test_same_sha_manual_pr_deduplicated(self):
        p = bot.plan(API([pull(target=TARGET)]))
        self.assertEqual(p["action"], "skip")
        self.assertIn("already covers", p["reason"])

    def test_old_manual_adaptation_blocks_update(self):
        self.assertEqual(bot.plan(API([pull()]))["action"], "skip")

    def test_multi_pr_and_bridge_only_pr_block(self):
        for files in ([bot.PATH, "other.txt"], ["bridge/rfvp_runtime/Cargo.lock"]):
            with self.subTest(files=files):
                self.assertEqual(bot.plan(API([pull(files=files)]))["action"], "skip")

    def test_non_main_pr_also_blocks(self):
        self.assertEqual(bot.plan(API([pull(base={"ref": "integration"})]))["action"], "skip")

    def test_bot_draft_unmodified_can_advance(self):
        p = bot.plan(API([pull(managed=True)]))
        self.assertEqual(p["action"], "update")
        self.assertEqual(p["head"], HEAD)

    def test_upstream_rewrite_relative_to_existing_bot_pin_is_rejected(self):
        for status in ("behind", "diverged"):
            api = API([pull(managed=True, target="e" * 40)])
            original = api.get
            def compare(suffix, repo=None):
                if suffix.startswith("compare/" + "e" * 40):
                    return {"status": status}
                return original(suffix, repo)
            api.get = compare
            with self.assertRaisesRegex(ValueError, "existing bot pin"):
                bot.plan(api)

    def test_ready_bot_pr_human_changes_or_changed_main_are_untouched(self):
        variants = [pull(managed=True, draft=False), pull(managed=True, body="edited"),
                    pull(managed=True, files=[bot.PATH, "manual.txt"]),
                    pull(managed=True, auto_merge={"merge_method": "squash"})]
        human_commit = pull(managed=True)
        human_commit["head"]["sha"] = "e" * 40
        variants.append(human_commit)
        changed_base = pull(managed=True)
        changed_base["body"] = changed_base["body"].replace(BASE, "e" * 40)
        variants.append(changed_base)
        for pr in variants:
            with self.subTest(pr=pr):
                self.assertEqual(bot.plan(API([pr]))["action"], "skip")

    def test_preserves_human_title_and_notes_even_with_marker_intact(self):
        for field in ("title", "body"):
            pr = pull(managed=True)
            pr[field] += "Human notes"
            self.assertEqual(bot.plan(API([pr]))["action"], "skip")
        pr = pull(managed=True)
        pr["body"] = "Human note\n" + pr["body"]
        self.assertEqual(bot.plan(API([pr]))["action"], "skip")

    def test_non_forward_history_fails_closed(self):
        for status in ("behind", "diverged", "identical"):
            api = API(); api.status = status
            with self.assertRaisesRegex(ValueError, "forward descendant"):
                bot.plan(api)

    def test_truncated_files_fail_closed(self):
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            bot.plan(API([pull(changed_files=3001)]))

    def test_unavailable_head_repo_fails_closed(self):
        pr = pull(); pr["head"]["repo"] = None
        with self.assertRaisesRegex(ValueError, "unavailable"):
            bot.plan(API([pr]))

    def test_existing_orphan_branch_is_not_overwritten(self):
        api = API(); api.branch_exists = True
        self.assertEqual(bot.plan(api)["action"], "skip")
        self.assertFalse(api.writes)

    def test_marker_parsing_is_not_code_and_invalid_is_unowned(self):
        for body in (None, "", bot.MARKER + "[] -->", bot.MARKER + "{broken} -->"):
            self.assertIsNone(bot.state_from_body(body))

    def test_api_failure_is_not_no_update(self):
        api = API()
        with patch.object(api, "get", side_effect=HTTPError("", 403, "denied", {}, None)):
            with self.assertRaises(HTTPError):
                bot.plan(api)


class PublishingTests(unittest.TestCase):
    def test_create_only_gitlink_and_draft(self):
        api = API(); p = bot.plan(api)
        bot.publish(api, p, "success", "https://github.com/owner/project/actions/runs/1")
        tree = api.writes[0][1]
        self.assertEqual(tree["base_tree"], "e" * 40)
        self.assertEqual(tree["tree"], [{"path": bot.PATH, "mode": "160000", "type": "commit", "sha": TARGET}])
        self.assertEqual(api.writes[1][1]["parents"], [BASE])
        self.assertTrue(api.writes[-1][1]["draft"])
        self.assertIn("**success**", api.writes[-1][1]["body"])
        self.assertFalse(any("merge" in path for path, _, _ in api.writes))

    def test_failed_verification_stays_draft_with_failure_disclosed(self):
        api = API(); bot.publish(api, bot.plan(api), "failure", "https://example.invalid/run")
        self.assertTrue(api.writes[-1][1]["draft"])
        self.assertIn("**failure**", api.writes[-1][1]["body"])

    def test_managed_update_uses_observed_parent_and_no_force(self):
        api = API([pull(managed=True)])
        bot.publish(api, bot.plan(api), "success", "https://example.invalid/run")
        self.assertEqual(api.writes[1][1]["parents"], [HEAD])
        self.assertEqual(api.writes[2][1], {"sha": "f" * 40, "force": False})
        self.assertEqual(api.writes[2][2], "PATCH")

    def test_rediscovery_must_exactly_match(self):
        for key in ("base", "target"):
            api = API(); expected = bot.plan(api)
            setattr(api, key, "e" * 40)
            with self.assertRaises(ValueError):
                bot.publish(api, expected, "success", "https://example.invalid/run")
            self.assertFalse(api.writes)
        api = API(); expected = bot.plan(api); api.prs = [pull()]
        with self.assertRaises(ValueError):
            bot.publish(api, expected, "success", "https://example.invalid/run")
        self.assertFalse(api.writes)

    def test_branch_rewind_before_ref_update_stops_publication(self):
        api = API([pull(managed=True)]); p = bot.plan(api); api.ref_head = BASE
        with self.assertRaisesRegex(ValueError, "changed before publication"):
            bot.publish(api, p, "success", "https://example.invalid/run")
        self.assertEqual(len(api.writes), 2)  # unattached tree/commit only

    def test_human_notes_during_ref_update_are_preserved(self):
        api = API([pull(managed=True)]); p = bot.plan(api); original = api.write
        def edit(path, data, method="POST"):
            result = original(path, data, method)
            if path.startswith("git/refs/heads/"):
                api.prs[0]["body"] += "Human notes"
            return result
        api.write = edit
        with self.assertRaisesRegex(ValueError, "description untouched"):
            bot.publish(api, p, "success", "https://example.invalid/run")
        self.assertFalse(any(path.startswith("pulls/") for path, _, _ in api.writes))

    def test_concurrent_human_commit_ref_rejection_does_not_edit_pr(self):
        api = API([pull(managed=True)]); p = bot.plan(api)
        original = api.write
        def conflict(path, data, method="POST"):
            if path.startswith("git/refs/heads/"):
                raise HTTPError("", 422, "not fast forward", {}, None)
            return original(path, data, method)
        api.write = conflict
        with self.assertRaises(HTTPError):
            bot.publish(api, p, "success", "https://example.invalid/run")
        self.assertEqual(len(api.writes), 2)


class PaginationTests(unittest.TestCase):
    def test_pagination_follows_more_than_one_hundred_prs_and_files(self):
        for suffix in ("pulls?state=open", "pulls/1/files"):
            api = bot.GitHub(REPO, "unused")
            with patch.object(api, "get", side_effect=[list(range(100)), [100]]) as get:
                self.assertEqual(list(api.pages(suffix)), list(range(101)))
                self.assertIn("page=2", get.call_args.args[0])


class WorkflowTests(unittest.TestCase):
    def test_security_contract(self):
        workflow = (ROOT / ".github/workflows/rfvp-update.yml").read_text()
        self.assertIn("cron: '23 1 * * *'", workflow)
        self.assertIn("cache-mode: none", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertNotIn("pull_request_target", workflow)
        self.assertNotIn("upload-artifact", workflow)
        self.assertNotIn("download-artifact", workflow)
        self.assertNotIn("persist-credentials: true", workflow)
        self.assertIn("github.ref == 'refs/heads/main'", workflow)
        self.assertIn("always() && !cancelled()", workflow)
        verify = workflow.split("  verify:\n")[1].split("  publish:\n")[0]
        self.assertIn("contents: read", verify)
        self.assertNotIn(": write", verify)
        self.assertIn("cache-mode: none", verify)
        self.assertIn("cargo check --locked", verify)
        self.assertIn("ctest --test-dir", verify)
        self.assertIn("cmp bridge/rfvp_runtime/Cargo.lock", verify)
        publish = workflow.split("  publish:\n")[1]
        self.assertIn("ref: ${{ needs.discover.outputs.base }}", publish)
        self.assertNotIn("needs.verify.outputs", publish)

    def test_all_secret_bearing_build_jobs_block_bot_branches_and_dispatch(self):
        build = (ROOT / ".github/workflows/build.yml").read_text().split("jobs:\n")[1]
        for name in ("android", "ios", "macos", "linux"):
            job = build.split("  " + name + ":\n")[1].split("    name:")[0]
            self.assertIn("!startsWith(github.head_ref, 'rfvp-update/')", job)
            self.assertIn("!startsWith(github.ref_name, 'rfvp-update/')", job)
            self.assertIn("github.event.pull_request.user.login != 'github-actions[bot]'", job)

    def test_generic_updater_cannot_publish_rfvp(self):
        workflow = (ROOT / ".github/workflows/submodule-update.yml").read_text()
        self.assertIn("--exclude-submodule packages/rfvp", workflow)


if __name__ == "__main__":
    unittest.main()
