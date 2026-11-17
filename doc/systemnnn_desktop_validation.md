# SystemNNN desktop validation

The following evidence applies to Aether commit `81c096263cc74a09faabaf9ce621306883ad1a86` and [SystemNNN native run 44141468366](https://github.com/AetherKiri/Aether/actions/runs/44141468366). Later commits require their own CI result; these results do not authorize binary distribution.

| Job | Result | Verified coverage |
| --- | --- | --- |
| [Linux native](https://github.com/AetherKiri/Aether/actions/runs/44141468366/job/134245088550) | Passed | All 12 CTest contracts, required executable inventory, generated movie playback/resolver integration, unchanged child source check. |
| [macOS native](https://github.com/AetherKiri/Aether/actions/runs/44141468366/job/134245088698) | Passed | All 12 CTest contracts, required executable inventory, unchanged child source check. The earlier font fixture and temporary-directory path failures are resolved. |
| [Godot 4.6 shell](https://github.com/AetherKiri/Aether/actions/runs/44141468366/job/134245088129) | Passed | Library, player reopen, runtime form dialog, launch entry, and input mapping suites; shell project runs without the native extension. |
| [Windows native](https://github.com/AetherKiri/Aether/actions/runs/44141468366/job/134245088587) | Failed: 11/12 | Configuration, Release compile/link, executable inventory and vcpkg cache upload passed. Provider contract failed Unicode game-directory and startup-filename reads: a native Windows path was narrowed through the active code page. Other eleven contracts passed. A child native-path IO correction and new CI result are required. |

The twelve native-job contracts comprise ten native executables: provider, text, startup, progress, audio, presenter, native panel, minigame, minigame binding, and dialogue reveal; plus Java compatibility checks for progress and minigames. Linux passed all twelve at 17:53:38 UTC and its movie integration at 17:53:41 UTC. macOS passed all twelve at 17:58:33 UTC. Generated movie integration runs only in the Linux job.

## Windows corrections under validation

The earlier run at `2b4a86eb` installed dependencies but failed on the OpenAL header include root, Debug OpenAL linkage in Release, and missing static transitive dependencies. OpenAL discovery now prefers its package config explicitly and retains workflow fallback paths for the include root and Release library.

The next run at `3d216ed0` installed all dependencies in 26 minutes but failed configuration because global package-config preference selected a ZLIB package without the expected `ZLIB::ZLIB` target. The current workflow removes that global preference while retaining scoped OpenAL config discovery. Its explicit cache save accepts a completed configuration attempt whether successful or failed, preventing subsequent project configuration errors from discarding valid vcpkg binary archives. Run 44141468366 confirms these dependency/configuration corrections and saved the cache at 18:23:49 UTC. It then exposed the separate Unicode filesystem defect above; compile/link success alone does not establish working Windows game loading.

## Product artifact hold

[Product Build run 44141468335](https://github.com/AetherKiri/Aether/actions/runs/44141468335), at the same commit, skipped all platform job definitions and produced zero artifacts. The product workflow excludes `feat/systemnnn` integration refs while distribution authorization remains unresolved; native and mobile source verification continue independently. The previous [product Build run 44135893801](https://github.com/AetherKiri/Aether/actions/runs/44135893801) was canceled with all five jobs canceled and zero artifacts. No existing artifacts were deleted.

This note records source and contract verification. Product packaging, device execution, visual acceptance, and permission to distribute combined binaries require separate evidence and authorization.
