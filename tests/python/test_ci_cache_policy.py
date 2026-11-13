"""Protect shared dependency caches from duplicate snapshots and unsafe cleanup."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / ".github/scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


policy = load("prune-ci-caches")
native = load("native-cache-key")


def cache(number, key, ref="refs/heads/main", size=100):
    return dict(id=number, key=key, ref=ref, size_in_bytes=size,
                created_at=f"2026-11-{number:02d}T00:00:00Z",
                last_accessed_at=f"2026-11-{number:02d}T00:00:00Z")


class CacheRetentionTests(unittest.TestCase):
    def deleted(self, entries, open_prs=(), budget=8 * policy.GIB):
        plan, remaining = policy.plan_evictions(entries, set(open_prs), budget=budget)
        return {item["id"] for item, reason in plan}, remaining

    def test_keeps_latest_main_snapshot_for_each_platform_and_cache_kind(self):
        entries = [cache(1, "Linux-linux-arm64-ccache-v3-100-1"),
                   cache(2, "Linux-linux-arm64-ccache-v4-native-digest"),
                   cache(3, "Linux-linux-x86_64-ccache-v3-100-1"),
                   cache(4, "Linux-X64-android-vcpkg-binaries-v1-dependencies"),
                   cache(5, "Linux-linux-arm64-vcpkg-binaries-v4-abi")]
        self.assertEqual(self.deleted(entries), ({1}, 400))

    def test_duplicate_keys_on_different_refs_do_not_replace_main(self):
        key = "Linux-X64-android-vcpkg-binaries-v1-dependencies"
        entries = [cache(1, key), cache(2, key, "refs/pull/11/merge"),
                   cache(3, key, "refs/pull/12/merge"), cache(4, key, "refs/pull/13/merge")]
        self.assertEqual(self.deleted(entries, {11, 12}), ({2, 4}, 200))

    def test_budget_discards_pr_copy_before_only_shared_android_cache(self):
        entries = [cache(1, "Linux-X64-android-vcpkg-binaries-v1-deps", size=500),
                   cache(2, "macOS-vcpkg-downloads-old", "refs/pull/11/merge", 400)]
        self.assertEqual(self.deleted(entries, {11}, 600), ({2}, 500))

    def test_unknown_caches_and_manual_branch_caches_are_not_deleted(self):
        entries = [cache(1, "gradle-dependencies-v2-digest"),
                   cache(2, "macOS-private-runtime-apple-digest", "refs/pull/99/merge"),
                   cache(3, "Linux-android-ccache-v4-native", "refs/heads/release")]
        self.assertEqual(self.deleted(entries, budget=1), (set(), 300))

    def test_dry_run_and_repeated_cleanup_do_not_mutate_inventory(self):
        entries = [cache(1, "macOS-ios-xcode-27.1-ccache-v2-old"),
                   cache(2, "macOS-ios-xcode-27.1-ccache-v3-new")]
        removed, remaining = self.deleted(entries)
        self.assertEqual(len(entries), 2)
        self.assertEqual(self.deleted([item for item in entries if item["id"] not in removed]),
                         (set(), remaining))


class NativeCacheKeyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.track("bridge/provider.cpp", "native")
        self.track("apps/godot_app/scripts/ui.gd", "UI")

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args])

    def track(self, path, content):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(content)
        self.git("add", path)

    def test_ui_and_documentation_changes_reuse_compiler_cache(self):
        key = native.native_key(self.root)
        self.track("apps/godot_app/scripts/ui.gd", "updated UI")
        self.track("doc/readme.md", "updated docs")
        self.assertEqual(native.native_key(self.root), key)

    def test_native_submodule_and_toolchain_changes_refresh_snapshot(self):
        key = native.native_key(self.root)
        self.track("bridge/provider.cpp", "updated native")
        updated = native.native_key(self.root)
        self.assertNotEqual(updated, key)
        self.git("update-index", "--add", "--cacheinfo", "160000," + "1" * 40 + ",packages/Engine")
        self.assertNotEqual(native.native_key(self.root), updated)
        self.assertNotEqual(native.native_key(self.root, b"compiler v1"),
                            native.native_key(self.root, b"compiler v2"))


if __name__ == "__main__":
    unittest.main()
