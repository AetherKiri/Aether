# Build cache policy

GitHub Actions caches are immutable and share repository capacity. A key with a
run ID creates another full archive on every run; old compiler snapshots can
evict expensive Android dependencies. The build workflow instead uses:

| Cache | Changes its key when | Writers |
| --- | --- | --- |
| C/C++ compiler snapshot (up to 1 GiB per platform) | Tracked native sources, engine gitlinks or compiler tools change | `main` |
| Linux vcpkg binaries | Manifest, overlays, toolchain or vcpkg baseline changes | `main` |
| Android vcpkg binaries | Manifest, overlays, NDK or toolchain changes | `main` and trusted same-repository PRs |
| vcpkg source downloads | Manifest or overlays change | `main`; Android also allows trusted PRs |
| Gradle dependencies | Managed by `setup-gradle` | Its default main-branch policy |

Every CI checkout bootstraps vcpkg at `vcpkg-configuration.json`'s baseline,
instead of the current upstream HEAD. Local developer checkouts are unchanged.
Fallback keys allow migration from old snapshots; vcpkg's package ABI checks and
ccache's compiler-content checks still validate individual cache entries.
Godot scripts, preview assets and documentation do not invalidate C/C++ snapshots.

Android runs the same build entry point with `--configure-only` for Release and
Debug, then saves the completed dependency archives **before** native compilation,
tests, signing and APK export. A later application failure therefore does not
throw away a successful dependency build. Fork and Dependabot PRs remain remote
cache readers; they may reuse packages locally between Release and Debug.
No installed tree is trusted blindly and no dependency build is skipped.

`Maintain build caches` runs after Build completes and once daily. It checks out
only the default branch, never a triggering PR or its artifacts. The policy keeps
one main snapshot and at most one recent open-PR copy per recognized platform and
cache kind, removes closed-PR copies, and trims PR copies toward an 8 GiB target.
It preserves the only main copy for every platform and leaves unrelated caches
(including Gradle and private dependency downloads) alone. If those protected
caches exceed the target, it reports the excess instead of emptying them.

Preview cleanup with:

```sh
python3 .github/scripts/prune-ci-caches.py --repo AetherKiri/Aether
```

Add `--apply` to remove the listed obsolete entries. Automatic maintenance starts
after this workflow is merged into the default branch. The first build of a new
dependency/toolchain key can still be cold; compare the next same-key run before
claiming a warm-cache duration. Build logs expose cache hits, vcpkg restored
package counts and ccache statistics. Rust compilation and app packaging are
still performed, so this policy does not imply a fixed end-to-end duration.

References: [GitHub cache behavior and limits](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching),
[vcpkg binary caching](https://learn.microsoft.com/en-us/vcpkg/users/binarycaching).
