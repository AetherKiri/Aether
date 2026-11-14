# Build cache policy

GitHub Actions caches are immutable and share repository capacity. A key with a
run ID creates another full archive on every run; old compiler snapshots can
evict expensive Android dependencies. Only `main` publishes shared caches;
other branches, pull requests and release tags restore them without uploading
their own copies. The build workflow uses:

| Cache | Changes its key when | Writers |
| --- | --- | --- |
| C/C++ compiler snapshot (up to 1 GiB per platform) | Tracked native sources, engine gitlinks or compiler tools change | `main` |
| Linux vcpkg binaries | Manifest, overlays, toolchain or vcpkg baseline changes | `main` |
| Android vcpkg binaries | Manifest, overlays, NDK or toolchain changes | `main` |
| vcpkg source downloads | Manifest or overlays change | `main` |
| Runtime dependency downloads | Platform dependency recipe changes | `main` |
| Gradle dependencies | Managed by `setup-gradle` | `main` (explicit read-only setting elsewhere) |

This is one shared set, with separate archives for each platform, architecture
and cache kind. It is not one archive shared between incompatible toolchains.
Existing keys and restore paths are retained so this policy change does not
invalidate already populated caches.

Every CI checkout bootstraps vcpkg at `vcpkg-configuration.json`'s baseline,
instead of the current upstream HEAD. Local developer checkouts are unchanged.
Fallback keys allow migration from old snapshots; vcpkg's package ABI checks and
ccache's compiler-content checks still validate individual cache entries.
Godot scripts, preview assets and documentation do not invalidate C/C++ snapshots.

Android runs the same build entry point with `--configure-only` for Release and
Debug, then on `main` saves the completed dependency archives **before** native compilation,
tests, signing and APK export. A later application failure therefore does not
throw away a successful dependency build. All other refs remain remote cache
readers; they may reuse newly built packages locally between Release and Debug.
No installed tree is trusted blindly and no dependency build is skipped.

GitHub tries the current ref before falling back to the default branch. Legacy
PR, branch and tag copies are therefore removed by maintenance, leaving `main`
as the shared source. PR caches cannot be promoted to `main`, and a release tag
does not populate `main`'s cache. The main-branch build must finish saving a cache
before later jobs can restore it. A branch with changed dependencies can still
download or compile missing packages; only a build on `main` persists that update.

`Maintain build caches` runs after Build or Release completes and once daily. It
checks out only the default branch, never a triggering PR, tag or its artifacts.
The policy keeps the latest main snapshot per recognized platform and cache kind,
removing superseded snapshots and all managed non-main copies. It preserves the
only main copy for every platform and leaves unrelated caches and Gradle's split
components alone. If those protected caches exceed the 8 GiB target, it reports
the excess instead of emptying them. Different Gradle component keys contain
different files and are not interchangeable snapshots.

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
