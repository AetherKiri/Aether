#!/usr/bin/env python3
"""
Inspect submodules updated in a target commit (or latest commit on main),
check if their remote tracking/main branches have newer commits than currently pinned,
and optionally update git index and prepare branch/PR information.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
from typing import Dict, List, Optional, Tuple


def run_git(args: List[str], cwd: Optional[str] = None, check: bool = True) -> str:
    """Run a git command and return its trimmed stdout."""
    res = subprocess.run(
        ["git"] + args,
        cwd=cwd,
        capture_output=True,
        text=True,
        check=check,
    )
    return res.stdout.strip()


def normalize_github_url(url: str) -> Optional[str]:
    """Convert git@github.com:org/repo.git or https://github.com/org/repo.git to https://github.com/org/repo."""
    if not url:
        return None
    url = url.strip()
    # SSH format: git@github.com:owner/repo.git
    ssh_match = re.match(r"^git@github\.com:([^/]+)/(.+?)(?:\.git)?$", url)
    if ssh_match:
        return f"https://github.com/{ssh_match.group(1)}/{ssh_match.group(2)}"
    # HTTPS format: https://github.com/owner/repo.git
    https_match = re.match(r"^https?://github\.com/([^/]+)/(.+?)(?:\.git)?$", url)
    if https_match:
        return f"https://github.com/{https_match.group(1)}/{https_match.group(2)}"
    return None


def is_ancestor_commit(url: str, ancestor_sha: str, descendant_sha: str) -> bool:
    """
    Verify that ancestor_sha is indeed an ancestor of descendant_sha in the remote repo.
    Uses a minimal treeless bare clone to fetch only commit metadata.
    """
    with tempfile.TemporaryDirectory() as td:
        repo_dir = os.path.join(td, "repo.git")
        try:
            # Treeless clone downloads only commit objects without tree or blob data (<200KB)
            run_git(["clone", "--bare", "--filter=tree:0", url, repo_dir])
            res = subprocess.run(
                ["git", "merge-base", "--is-ancestor", ancestor_sha, descendant_sha],
                cwd=repo_dir,
                capture_output=True,
            )
            return res.returncode == 0
        except Exception as e:
            print(f"Warning: Failed to check commit ancestry for {url}: {e}", file=sys.stderr)
            return False


def get_submodules_config() -> Dict[str, Dict[str, Optional[str]]]:
    """Parse .gitmodules to retrieve path, url, and optional configured branch for all submodules."""
    if not os.path.exists(".gitmodules"):
        return {}

    try:
        out = run_git(["config", "-f", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$"])
    except subprocess.CalledProcessError:
        return {}

    submodules: Dict[str, Dict[str, Optional[str]]] = {}
    for line in out.splitlines():
        if not line.strip():
            continue
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        key, path = parts
        sub_name = key[len("submodule.") : -len(".path")]
        try:
            url = run_git(["config", "-f", ".gitmodules", f"submodule.{sub_name}.url"])
        except subprocess.CalledProcessError:
            url = ""

        try:
            branch = run_git(["config", "-f", ".gitmodules", f"submodule.{sub_name}.branch"])
        except subprocess.CalledProcessError:
            branch = None

        submodules[path] = {
            "name": sub_name,
            "path": path,
            "url": url,
            "branch": branch if branch else None,
        }
    return submodules


def get_changed_submodules(commit: str, base: Optional[str] = None) -> List[str]:
    """
    Find submodules whose commit hash changed between base and commit.
    Uses diff-tree to find mode 160000 changes.
    """
    # Ensure commit exists locally
    try:
        run_git(["rev-parse", "--verify", commit])
    except subprocess.CalledProcessError:
        try:
            run_git(["fetch", "--depth=2", "origin", commit])
        except subprocess.CalledProcessError:
            pass

    if not base:
        # Check if parent commit exists (e.g. commit^1)
        try:
            run_git(["rev-parse", "--verify", f"{commit}^1"])
            base = f"{commit}^1"
        except subprocess.CalledProcessError:
            try:
                run_git(["fetch", "--deepen=1", "origin", commit])
                run_git(["rev-parse", "--verify", f"{commit}^1"])
                base = f"{commit}^1"
            except subprocess.CalledProcessError:
                # First commit or shallow clone without parent
                return []

    try:
        diff_out = run_git(["diff-tree", "-r", "--no-commit-id", "-m", base, commit])
    except subprocess.CalledProcessError as e:
        print(f"Warning: git diff-tree failed ({e})", file=sys.stderr)
        return []

    changed = set()
    for line in diff_out.splitlines():
        parts = line.strip().split()
        if len(parts) >= 6:
            old_mode, new_mode, path = parts[0], parts[1], parts[5]
            if old_mode == ":160000" or new_mode == "160000":
                changed.add(path)
    return sorted(list(changed))


def get_pinned_commit(commit: str, submodule_path: str) -> Optional[str]:
    """Get the commit hash currently pinned for a submodule at a given tree commit."""
    try:
        tree_out = run_git(["ls-tree", commit, submodule_path])
        # Output format: 160000 commit <sha>\t<submodule_path>
        parts = tree_out.split()
        if len(parts) >= 3 and parts[1] == "commit":
            return parts[2]
    except subprocess.CalledProcessError:
        pass
    return None


def get_remote_branch_and_head(url: str, configured_branch: Optional[str] = None) -> Tuple[Optional[str], Optional[str]]:
    """
    Query the remote repository via git ls-remote to find the target branch and its latest commit SHA.
    Returns (branch_name, latest_sha).
    """
    if not url:
        return None, None

    try:
        ls_out = run_git(["ls-remote", "--symref", url, "HEAD"])
    except subprocess.CalledProcessError as e:
        print(f"Warning: git ls-remote failed for {url}: {e.stderr}", file=sys.stderr)
        return None, None

    default_branch = None
    head_sha = None
    for line in ls_out.splitlines():
        line = line.strip()
        if line.startswith("ref: refs/heads/"):
            # Format: ref: refs/heads/<branch>\tHEAD
            ref_part = line.split("\t")[0]
            default_branch = ref_part.replace("ref: refs/heads/", "").strip()
        elif "\tHEAD" in line or line.endswith("HEAD"):
            head_sha = line.split()[0]

    target_branch = configured_branch or default_branch or "main"

    # If configured_branch differs from remote default branch, resolve SHA specifically
    if configured_branch and configured_branch != default_branch:
        try:
            branch_out = run_git(["ls-remote", url, f"refs/heads/{configured_branch}"])
            for line in branch_out.splitlines():
                if line.strip().endswith(f"refs/heads/{configured_branch}"):
                    return configured_branch, line.strip().split()[0]
        except subprocess.CalledProcessError:
            return None, None

    return target_branch, head_sha


def main():
    parser = argparse.ArgumentParser(
        description="Inspect and update submodules that changed in the target commit."
    )
    parser.add_argument("--commit", default="HEAD", help="Target commit SHA on main to inspect for changed submodules (default: HEAD)")
    parser.add_argument("--current-ref", default="HEAD", help="Git ref of current checked-out base to compare and update (default: HEAD)")
    parser.add_argument("--base", default=None, help="Base commit to diff against (default: <commit>^1)")
    parser.add_argument("--submodule", default=None, help="Explicit submodule path to check")
    parser.add_argument("--all", action="store_true", help="Inspect all submodules in repo")
    parser.add_argument("--apply", action="store_true", help="Stage the updated submodules into the git index")
    parser.add_argument("--github-output", default=None, help="Path to $GITHUB_OUTPUT")
    parser.add_argument("--github-summary", default=None, help="Path to $GITHUB_STEP_SUMMARY")
    parser.add_argument("--pr-body-file", default=None, help="Path to write generated PR markdown body")
    parser.add_argument("--run-number", default="", help="GitHub Actions run number or unique suffix")
    parser.add_argument("--allow-non-forward", action="store_true", help="Allow updating even if current pin is not an ancestor of remote HEAD")
    parser.add_argument("--commit-msg-file", default=None, help="Path to write commit message")

    args = parser.parse_args()

    submodules_cfg = get_submodules_config()
    if not submodules_cfg:
        print("No submodules defined in .gitmodules.")
        write_github_outputs(args.github_output, {"has_updates": "false"})
        return 0

    # Determine candidate submodules to check
    if args.all:
        candidate_paths = sorted(list(submodules_cfg.keys()))
        print(f"Checking all {len(candidate_paths)} submodules in .gitmodules...")
    elif args.submodule:
        if args.submodule not in submodules_cfg:
            print(f"Error: Submodule path '{args.submodule}' not found in .gitmodules.", file=sys.stderr)
            write_github_outputs(args.github_output, {"has_updates": "false"})
            return 1
        candidate_paths = [args.submodule]
        print(f"Checking specified submodule: {args.submodule}")
    else:
        # Only submodules updated in previous commit
        changed_paths = get_changed_submodules(args.commit, args.base)
        candidate_paths = [p for p in changed_paths if p in submodules_cfg]
        if not candidate_paths:
            print(f"No submodules had their commit hash modified in commit {args.commit}. Skipping.")
            write_github_outputs(args.github_output, {"has_updates": "false"})
            return 0
        print(f"Submodule(s) modified in commit {args.commit}: {', '.join(candidate_paths)}")

    updates = []
    for path in candidate_paths:
        cfg = submodules_cfg[path]
        name = os.path.basename(path)
        url = cfg["url"]
        branch_cfg = cfg["branch"]

        # Resolve pinned commit from the checked-out base (HEAD) where changes will be committed
        pinned_sha = get_pinned_commit(args.current_ref, path)
        if not pinned_sha:
            print(f"[{name}] Could not resolve currently pinned commit at {args.current_ref}, skipping.")
            continue

        if args.commit != args.current_ref:
            historical_sha = get_pinned_commit(args.commit, path)
            print(f"[{name}] Inspected commit {args.commit[:8]} had pin: {historical_sha[:8] if historical_sha else 'None'}")

        target_branch, remote_sha = get_remote_branch_and_head(url, branch_cfg)
        if not remote_sha:
            print(f"[{name}] Could not retrieve remote branch/head for {url}, skipping.")
            continue

        print(f"[{name}] Target branch: {target_branch} | Checked-out pin ({args.current_ref}): {pinned_sha[:8]} | Remote HEAD: {remote_sha[:8]}")

        if remote_sha != pinned_sha:
            if not args.allow_non_forward:
                print(f"[{name}] Verifying {pinned_sha[:8]} is an ancestor of remote {remote_sha[:8]}...")
                if not is_ancestor_commit(url, pinned_sha, remote_sha):
                    print(f"[{name}] Remote HEAD {remote_sha[:8]} is not a forward descendant of checked-out pin {pinned_sha[:8]} (not an ancestor). Skipping.")
                    continue
            print(f"[{name}] Update available! {pinned_sha[:8]} -> {remote_sha[:8]}")
            gh_base_url = normalize_github_url(url)
            updates.append({
                "path": path,
                "name": name,
                "url": url,
                "gh_url": gh_base_url,
                "branch": target_branch,
                "old_sha": pinned_sha,
                "new_sha": remote_sha,
                "old_short": pinned_sha[:8],
                "new_short": remote_sha[:8],
            })
        else:
            print(f"[{name}] Submodule is already up to date with remote {target_branch} in checked-out base ({args.current_ref}).")

    if not updates:
        print("No submodule updates found.")
        write_github_outputs(args.github_output, {"has_updates": "false"})
        return 0

    print(f"\nFound {len(updates)} submodule(s) to update:")
    for u in updates:
        print(f"  - {u['name']}: {u['old_short']} -> {u['new_short']} (branch: {u['branch']})")

    # If --apply requested, stage into index
    if args.apply:
        for u in updates:
            print(f"Staging updated gitlink for {u['path']} ({u['new_sha']})...")
            run_git(["update-index", "--cacheinfo", "160000", u["new_sha"], u["path"]])

    # Prepare branch name, PR title, body, commit message
    suffix = f"-{args.run_number}" if args.run_number else ""
    if len(updates) == 1:
        u = updates[0]
        branch_prefix = f"submodule-update/{u['name']}"
        branch_name = f"submodule-update/{u['name']}-{u['new_short']}{suffix}"
        pr_title = f"chore(submodule): update {u['name']} to {u['new_short']}"
    else:
        names = ", ".join(u["name"] for u in updates)
        new_shorts = "-".join(u["new_short"] for u in updates)
        branch_prefix = "submodule-update/multi"
        branch_name = f"submodule-update/multi-{new_shorts}{suffix}"
        pr_title = f"chore(submodule): update submodules ({names})"

    # Construct markdown table
    table_rows = []
    for u in updates:
        if u["gh_url"]:
            sub_link = f"[{u['path']}]({u['gh_url']})"
            old_link = f"[{u['old_short']}]({u['gh_url']}/commit/{u['old_sha']})"
            new_link = f"[{u['new_short']}]({u['gh_url']}/commit/{u['new_sha']})"
            diff_link = f"[View compare]({u['gh_url']}/compare/{u['old_sha']}...{u['new_sha']})"
        else:
            sub_link = f"`{u['path']}`"
            old_link = f"`{u['old_short']}`"
            new_link = f"`{u['new_short']}`"
            diff_link = "N/A"

        table_rows.append(
            f"| {sub_link} | `{u['branch']}` | {old_link} | {new_link} | {diff_link} |"
        )

    table_content = "\n".join(table_rows)

    pr_body = f"""## Submodule Updates

This automated pull request updates submodule commit pointers to the latest commit on their respective upstream tracking branches.

### Summary of Changes

| Submodule | Tracking Branch | Pinned Commit | Upstream Commit | Changes |
| :--- | :--- | :--- | :--- | :--- |
{table_content}

---
*Triggered by commit `{args.commit[:8]}` on `main`.*
"""

    commit_msg = f"{pr_title}\n\nUpdates:\n" + "\n".join(
        f"- {u['path']} ({u['branch']}): {u['old_short']} -> {u['new_short']}" for u in updates
    )

    if args.pr_body_file:
        os.makedirs(os.path.dirname(os.path.abspath(args.pr_body_file)), exist_ok=True)
        with open(args.pr_body_file, "w", encoding="utf-8") as f:
            f.write(pr_body)

    if args.commit_msg_file:
        os.makedirs(os.path.dirname(os.path.abspath(args.commit_msg_file)), exist_ok=True)
        with open(args.commit_msg_file, "w", encoding="utf-8") as f:
            f.write(commit_msg)

    if args.github_summary:
        with open(args.github_summary, "a", encoding="utf-8") as f:
            f.write(f"\n{pr_body}\n")

    outputs = {
        "has_updates": "true",
        "branch_name": branch_name,
        "branch_prefix": branch_prefix,
        "pr_title": pr_title,
        "pr_body_file": args.pr_body_file or "",
        "commit_msg_file": args.commit_msg_file or "",
        "updated_submodules": ",".join(u["path"] for u in updates),
    }
    write_github_outputs(args.github_output, outputs)
    return 0


def write_github_outputs(output_file: Optional[str], outputs: Dict[str, str]):
    if not output_file:
        return
    with open(output_file, "a", encoding="utf-8") as f:
        for k, v in outputs.items():
            f.write(f"{k}={v}\n")


if __name__ == "__main__":
    sys.exit(main())
