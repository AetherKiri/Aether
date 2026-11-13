#!/usr/bin/env python3
"""Retain useful build caches without evicting another platform's dependencies."""

import argparse
from collections import defaultdict
import json
import re
import subprocess


GIB = 2**30
# Only caches owned by build.yml are managed. In particular, Gradle's split
# caches, unrelated workflows and private dependency downloads are untouched.
FAMILIES = (
    r"(Linux-(?:android|linux-(?:x86_64|arm64))-ccache)-v\d+-",
    r"(macOS-(?:ios|macos)-xcode-[\d.]+-ccache)-v\d+-",
    r"(Linux-(?:X64|ARM64)-android-vcpkg-(?:downloads|binaries))-v\d+-",
    r"(Linux-linux-(?:x86_64|arm64)-vcpkg-(?:downloads|binaries))-",
    r"(macOS-vcpkg-downloads)-",
)


def family(key):
    for pattern in FAMILIES:
        match = re.match(pattern, key)
        if match:
            return match[1]
    return None


def plan_evictions(caches, open_prs, default_ref="refs/heads/main", budget=8 * GIB):
    groups = defaultdict(list)
    removals = {}
    for cache in caches:
        group = family(cache["key"])
        if group is None:
            continue
        pr = re.fullmatch(r"refs/pull/(\d+)/merge", cache["ref"])
        if pr and int(pr[1]) not in open_prs:
            removals[cache["id"]] = (cache, "closed PR")
        elif cache["ref"] == default_ref or pr:
            groups[group].append(cache)
        # Manual builds on other branches may still be in use. Do not delete
        # their last cache based on assumptions about the branch's lifetime.

    pr_candidates = []
    for entries in groups.values():
        entries.sort(key=lambda item: (item["created_at"], item["id"]), reverse=True)
        # Keep one shared main snapshot and at most one recent open-PR copy
        # per platform/cache kind. Old prefixes remain usable via restore-keys.
        for on_main in (True, False):
            scoped = [item for item in entries if (item["ref"] == default_ref) == on_main]
            for old in scoped[1:]:
                removals[old["id"]] = (old, "superseded snapshot")
            if scoped and not on_main:
                pr_candidates.append(scoped[0])

    remaining = sum(item["size_in_bytes"] for item in caches if item["id"] not in removals)
    # Make headroom for the next upload. Preserve each platform's only main
    # snapshot; PR copies are recoverable from main or regenerated in that PR.
    for cache in sorted(pr_candidates, key=lambda item: item["last_accessed_at"]):
        if remaining <= budget:
            break
        removals[cache["id"]] = (cache, "PR copy exceeds shared cache budget")
        remaining -= cache["size_in_bytes"]
    return list(removals.values()), remaining


def pages(endpoint):
    return json.loads(subprocess.check_output(["gh", "api", "--paginate", "--slurp", endpoint]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--default-branch", default="main")
    parser.add_argument("--budget-gib", type=float, default=8)
    parser.add_argument("--apply", action="store_true", help="delete listed obsolete caches (default: dry run)")
    args = parser.parse_args()
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo) or args.budget_gib <= 0:
        parser.error("Expected owner/repository and a positive cache budget")
    caches = [item for page in pages(f"repos/{args.repo}/actions/caches?per_page=100")
              for item in page["actions_caches"]]
    open_prs = {item["number"] for page in pages(f"repos/{args.repo}/pulls?state=open&per_page=100")
                for item in page}
    plan, remaining = plan_evictions(caches, open_prs, "refs/heads/" + args.default_branch,
                                     args.budget_gib * GIB)
    before = sum(item["size_in_bytes"] for item in caches)
    print(f"Cache usage: {before / GIB:.2f} -> {remaining / GIB:.2f} GiB; {len(plan)} obsolete entries")
    for cache, reason in plan:
        print(f"{'Delete' if args.apply else 'Would delete'} {cache['id']}: {reason}; "
              f"{cache['size_in_bytes'] / GIB:.2f} GiB; {cache['ref']}; {cache['key']}")
        if args.apply:
            result = subprocess.run(["gh", "api", "--method", "DELETE",
                                     f"repos/{args.repo}/actions/caches/{cache['id']}"],
                                    capture_output=True, text=True)
            if result.returncode and "HTTP 404" not in result.stderr:
                raise RuntimeError(result.stderr)
    if remaining > args.budget_gib * GIB:
        print("Only protected or unmanaged caches remain above the target; no shared cache was discarded.")


if __name__ == "__main__":
    main()
