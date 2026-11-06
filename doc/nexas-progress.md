# NeXAS native runtime development checkpoint

This branch records the current C++ NeXAS integration work. Engine compatibility
is incomplete; it is not a release or a claim that every BALDR SKY/GIGA game works.
The existing single `nexas_vm_core` interprets all NeXAS script banks. Engine
state stays in the independent provider; Aether supplies the shared runtime ABI,
platform services and presentation, as it does for other native engines.

## Repositories and reproducible pair

- Host: `AetherKiri/Aether`, branch `codex/nexas-provider-integration`.
- Runtime: [AetherKiri/AetherNeXAS](https://github.com/AetherKiri/AetherNeXAS),
  branch `codex/native-runtime-migration`.
- Runtime revision: [`43b73bd`](https://github.com/AetherKiri/AetherNeXAS/commit/43b73bd922b9b771e3847e92e54c4867a280ff1c).

The runtime is a private repository at this initial upload. This public branch
contains only host integration and documentation. No private runtime source,
game resources, executables, original saves or research dumps are included.
The detailed [runtime progress and remaining work](https://github.com/AetherKiri/AetherNeXAS/blob/43b73bd922b9b771e3847e92e54c4867a280ff1c/docs/checkpoint-2026-11-07.zh-CN.md)
requires access to that repository.

## Build

Clone Aether on this branch and the independent runtime at the revision above.
Prepare the normal macOS toolchain and host dependencies from `development.md`,
then configure the optional provider:

```sh
git clone https://github.com/AetherKiri/AetherNeXAS.git /path/to/AetherNeXAS
git -C /path/to/AetherNeXAS checkout 43b73bd922b9b771e3847e92e54c4867a280ff1c
cmake --preset "MacOS Release Config" \
  -DAETHERKIRI_ENABLE_NEXAS=ON \
  -DAETHERKIRI_NEXAS_RUNTIME_DIR=/path/to/AetherNeXAS
cmake --build out/macos/release --target aether_kiri_godot -j6
```

The optional runtime remains disabled in the default host build. A configured
build detects NeXAS PC game directories, registers its C++ provider and forwards
input, window/cursor, movie, volume and vibration requests through the common
host services. Godot has only generic game-library routing changes.

## Validation recorded on 2026-11-07

| Check | Result |
| --- | --- |
| Standalone runtime Release build | Passed |
| Runtime CTest suite | 858/858 passed |
| Provider with original installation/save directories | 48 cases, 1,751 assertions passed |
| Original Event continuations | 4 cases, 2,546 assertions passed |
| Expanded original MEK/survival/tutorial/START checks | 12 cases, 3,670 assertions passed |
| Combined Aether macOS Release GDExtension | Built and linked |

Original-file checks run locally against user-provided data. They are not a
complete playthrough. Existing Swift conditional-flag and duplicate-library
link warnings remain.

## Remaining work and branch boundary

The latest runtime adds Host-owned scene/actor identities, stable machine parent
links and v190 snapshots. The common prepare/retry kernel and actor clock models
have numerical conformance tests, but live battle still uses its existing pass
order. The single retained Host update permutation, player/CPU callback wiring,
per-attempt prefixes and native subframes remain unfinished. Some WAZ/scalar
semantics, presentation memberships, PC standing reconstruction and full-frame
pixel comparisons also remain. Other GIGA titles have not been validated.

This integration branch preserves the tested host baseline `4a23e5ea`
(2026-09-22). It has not been rebased onto the current Aether `main`; it needs
that adaptation and renewed host checks before a merge or product release.
