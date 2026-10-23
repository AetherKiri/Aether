#!/usr/bin/env python3
"""Plan/publish a conservative RFVP-only update. Never execute upstream code here."""
import argparse
import hashlib
import json
import os
import re
import sys
import urllib.error
import urllib.request

PATH = "packages/rfvp"
UPSTREAM = "xmoezzz/rfvp"
PREFIX = "rfvp-update/"
MARKER = "<!-- rfvp-update-state: "
BOT = "github-actions[bot]"
SHA = re.compile(r"^[0-9a-f]{40}$")


class GitHub:
    def __init__(self, repo, token):
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
            raise ValueError("Invalid repository")
        self.repo, self.token = repo, token

    def request(self, path, data=None, method=None):
        req = urllib.request.Request(
            "https://api.github.com" + path,
            data=None if data is None else json.dumps(data).encode(),
            method=method,
            headers={"Authorization": "Bearer " + self.token,
                     "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28"},
        )
        with urllib.request.urlopen(req, timeout=60) as response:
            return json.load(response)

    def get(self, suffix, repo=None):
        return self.request(f"/repos/{repo or self.repo}/{suffix}")

    def write(self, suffix, data, method="POST"):
        return self.request(f"/repos/{self.repo}/{suffix}", data, method)

    def pages(self, suffix):
        separator = "&" if "?" in suffix else "?"
        page = 1
        while True:
            rows = self.get(f"{suffix}{separator}per_page=100&page={page}")
            yield from rows
            if len(rows) < 100:
                return
            page += 1

    def pin(self, repo, commit):
        # Contents API returns submodules as file/submodule depending on API version.
        item = self.get(f"contents/{PATH}?ref={commit}", repo)
        if not item.get("submodule_git_url") or not SHA.fullmatch(item.get("sha", "")):
            raise ValueError("RFVP path is not a valid submodule")
        return item["sha"]


def state_from_body(body):
    match = re.search(re.escape(MARKER) + r"(\{[^\n]*\}) -->", body or "")
    if not match:
        return None
    try:
        value = json.loads(match.group(1))
        return value if isinstance(value, dict) else None
    except (ValueError, TypeError):
        return None


def unedited_description(pr, state):
    body = pr.get("body") or ""
    marker = re.search(re.escape(MARKER) + r"(\{[^\n]*\}) -->", body)
    if not marker or body[marker.end():] != "\n":
        return False
    digest = hashlib.sha256((pr["title"] + "\n" + body[:marker.start()]).encode()).hexdigest()
    return state.get("description_sha256") == digest


def relevant(path):
    return path == PATH or path.startswith("bridge/rfvp_runtime/")


def plan(api):
    base = api.get("git/ref/heads/main")["object"]["sha"]
    target = api.get("git/ref/heads/main", UPSTREAM)["object"]["sha"]
    current = api.pin(api.repo, base)
    result = {"base": base, "target": target, "current": current, "action": "skip"}
    if current == target:
        return dict(result, reason="main already pins upstream main")
    compare = api.get(f"compare/{current}...{target}", UPSTREAM)
    if compare["status"] != "ahead":
        raise ValueError("Upstream main is not a forward descendant; manual review required")
    managed = []
    blockers = []
    # Do not filter by title, branch prefix, or author: multi/manual PRs count too.
    for pr in api.pages("pulls?state=open"):
        pr = api.get(f"pulls/{pr['number']}")
        files = list(api.pages(f"pulls/{pr['number']}/files"))
        if len(files) != pr["changed_files"]:
            raise ValueError("Incomplete PR file listing; refusing duplicate detection")
        if not any(relevant(f["filename"]) or relevant(f.get("previous_filename", "")) for f in files):
            continue
        head_repo = pr["head"].get("repo")
        if not head_repo:
            raise ValueError("Relevant PR head repository is unavailable")
        head = pr["head"]["sha"]
        pin = api.pin(head_repo["full_name"], head)
        state = state_from_body(pr.get("body"))
        owned = (pr["user"]["login"] == BOT and head_repo["full_name"] == api.repo
                 and pr["head"]["ref"].startswith(PREFIX) and state
                 and state.get("head") == head and state.get("base") == base
                 and state.get("target") == pin and unedited_description(pr, state)
                 and [f["filename"] for f in files] == [PATH]
                 and pr["base"]["ref"] == "main" and pr["draft"]
                 and not pr.get("auto_merge"))
        if pin == target:
            blockers.append(f"PR #{pr['number']} already covers upstream {target[:12]}")
        elif owned:
            pr["rfvp_pin"] = pin
            managed.append(pr)
        else:
            blockers.append(f"PR #{pr['number']} has ongoing RFVP work; leave it untouched")
    if blockers:
        return dict(result, reason="; ".join(blockers))
    if len(managed) > 1:
        return dict(result, reason="Multiple managed RFVP PRs need manual reconciliation")
    if managed:
        pr = managed[0]
        advance = api.get(f"compare/{pr['rfvp_pin']}...{target}", UPSTREAM)
        if advance["status"] != "ahead":
            raise ValueError("Upstream main does not advance the existing bot pin; manual review required")
        return dict(result, action="update", branch=pr["head"]["ref"],
                    head=pr["head"]["sha"], number=pr["number"], reason="Advance unmodified bot draft")
    branch = PREFIX + base[:12] + "-" + target[:12]
    try:
        api.get("git/ref/heads/" + branch)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    else:
        return dict(result, reason="Candidate branch already exists without a managed PR; inspect manually")
    return dict(result, action="create", branch=branch, head=base, number=0,
                reason="New upstream main commit")


def description(p, head, verification, run_url):
    state = {"base": p["base"], "target": p["target"], "head": head}
    content = f"""## Daily RFVP upstream check

Updates only `{PATH}` from `{p['current']}` to `{p['target']}`.
[Upstream changes](https://github.com/{UPSTREAM}/compare/{p['current']}...{p['target']}).

Secretless standalone verification: **{verification}** ([run]({run_url})).
The verification checks the existing isolated host overlay, locked Cargo graph,
provider build, CTest regressions, clean submodule and unchanged bridge lockfile.
A failure requires manual adaptation; the bot does not rewrite overlays or Cargo.lock.
Full product builds, Apple packaging and real-game compatibility are not certified.
This stays a draft; no automatic merge or release. Full product workflows are
blocked on `rfvp-update/` branches to keep unreviewed upstream code away from secrets.
If adaptation is needed, take over in a reviewed human branch; the daily bot then skips it.

"""
    title = "chore(rfvp): update upstream to " + p["target"][:12]
    state["description_sha256"] = hashlib.sha256((title + "\n" + content).encode()).hexdigest()
    return content + MARKER + json.dumps(state, sort_keys=True) + " -->\n"


def publish(api, expected, verification, run_url):
    fresh = plan(api)
    if fresh != expected or fresh["action"] == "skip":
        raise ValueError("Repository/upstream/PR state changed since discovery; wait for next run")
    p = fresh
    # Only a gitlink is written; no content/artifacts from the verification runner.
    parent = api.get("git/commits/" + p["head"])
    tree = api.write("git/trees", {"base_tree": parent["tree"]["sha"], "tree": [
        {"path": PATH, "mode": "160000", "type": "commit", "sha": p["target"]}]})
    commit = api.write("git/commits", {
        "message": "chore(rfvp): update upstream to " + p["target"][:12],
        "tree": tree["sha"], "parents": [p["head"]]})
    head = commit["sha"]
    body = description(p, head, verification, run_url)
    if p["action"] == "create":
        api.write("git/refs", {"ref": "refs/heads/" + p["branch"], "sha": head})
        return api.write("pulls", {"base": "main", "head": p["branch"], "draft": True,
            "title": "chore(rfvp): update upstream to " + p["target"][:12], "body": body})
    # Recheck ownership immediately before the non-forced ref mutation. GitHub's
    # REST ref update is not a transaction with PR metadata; do not claim a CAS.
    if plan(api) != p or api.get("git/ref/heads/" + p["branch"])["object"]["sha"] != p["head"]:
        raise ValueError("Managed branch/PR changed before publication")
    old_pr = api.get(f"pulls/{p['number']}")
    api.write("git/refs/heads/" + p["branch"], {"sha": head, "force": False}, "PATCH")
    updated_pr = api.get(f"pulls/{p['number']}")
    if (updated_pr["head"]["sha"] != head or not updated_pr["draft"]
            or updated_pr.get("body") != old_pr.get("body")
            or updated_pr["title"] != old_pr["title"]):
        raise ValueError("PR changed during publication; leave description untouched for manual review")
    return api.write(f"pulls/{p['number']}", {
        "title": "chore(rfvp): update upstream to " + p["target"][:12], "body": body}, "PATCH")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["plan", "publish"])
    args = parser.parse_args()
    api = GitHub(os.environ["GITHUB_REPOSITORY"], os.environ["GH_TOKEN"])
    if args.mode == "plan":
        p = plan(api)
        print(json.dumps(p, indent=2))
        if os.environ.get("GITHUB_OUTPUT"):
            with open(os.environ["GITHUB_OUTPUT"], "a") as out:
                out.write("plan=" + json.dumps(p, separators=(",", ":")) + "\n")
                for key in ("action", "base", "head", "target"):
                    out.write(key + "=" + str(p.get(key, "")) + "\n")
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as out:
                out.write("RFVP: " + p["reason"] + "\n")
    else:
        verification = os.environ["VERIFICATION_RESULT"]
        if verification not in ("success", "failure"):
            raise ValueError("Verification was cancelled/skipped; no PR mutation")
        p = json.loads(os.environ["EXPECTED_PLAN"])
        url = f"https://github.com/{api.repo}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
        result = publish(api, p, verification, url)
        print(result["html_url"])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, urllib.error.URLError, KeyError) as error:
        print(f"RFVP update stopped: {error}", file=sys.stderr)
        sys.exit(1)
