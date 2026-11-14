#!/usr/bin/env python3
"""Retain useful build caches without evicting another platform's dependencies."""

import argparse
from collections import defaultdict
import json
import re
import subprocess


GIB = 2**30
# Only caches owned by build.yml are managed. In particular, Gradle's split
# caches and unrelated workflows are untouched.
FAMILIES = (
    r"(Linux-(?:android|linux-(?:x86_64|arm64))-ccache)-v\d+-",
    r"(macOS-(?:ios|macos))-xcode-[\d.]+-ccache-v\d+-",
    r"(Linux-(?:X64|ARM64)-android-vcpkg-(?:downloads|binaries))-v\d+-",
    r"(Linux-linux-(?:x86_64|arm64)-vcpkg-(?:downloads|binaries))-",
    r"(macOS-vcpkg-downloads)-",
    r"(Linux-private-runtime-android)-",
    r"(macOS-private-runtime-(?:apple|macos))-",
)


def family(key):
    for pattern in FAMILIES:
        match = re.match(pattern, key)
        if match:
            return match[1]
    return None


def plan_evictions(caches, default_ref="refs/heads/main"):
    groups = defaultdict(list)
    removals = {}
    for cache in caches:
        group = family(cache["key"])
        if group is None:
            continue
        if cache["ref"] == default_ref:
            groups[group].append(cache)
        else:
            # All other refs are readers. Legacy PR, branch and tag copies
            # cannot seed main and only consume the shared storage budget.
            removals[cache["id"]] = (cache, "non-default-branch copy")

    for entries in groups.values():
        entries.sort(key=lambda item: (item["created_at"], item["id"]), reverse=True)
        # Keep one shared main snapshot per platform/cache kind, including
        # across compiler versions. Never sacrifice a platform's only copy.
        for old in entries[1:]:
            removals[old["id"]] = (old, "superseded snapshot")

    remaining = sum(item["size_in_bytes"] for item in caches if item["id"] not in removals)
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
    plan, remaining = plan_evictions(caches, "refs/heads/" + args.default_branch)
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
