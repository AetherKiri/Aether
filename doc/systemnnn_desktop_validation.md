# SystemNNN desktop validation

## Final native-path and fixture revision

[Run 44150877791](https://github.com/AetherKiri/Aether/actions/runs/44150877791) completed successfully at Aether `b72bdca3720a4da89d040fdc535969b6050f4625` / Emberfall `e5ca4283b9c4f933f9cea9d486239396eeb9b086`. This is the final desktop contract authority, superseding the earlier Windows failures below.

| Job | Result | Coverage |
| --- | --- | --- |
| [Linux 134278547301](https://github.com/AetherKiri/Aether/actions/runs/44150877791/job/134278547301) | Passed, 2m8s | All 12 contracts, required native inventory, generated movie fixtures and clean child source check. |
| [macOS 134278547374](https://github.com/AetherKiri/Aether/actions/runs/44150877791/job/134278547374) | Passed, 1m36s | All 12 contracts, required inventory and clean child source check. |
| [Windows 134278547758](https://github.com/AetherKiri/Aether/actions/runs/44150877791/job/134278547758) | Passed, 3m46s | Focused vcpkg configuration, Release compile/link, all 12 contracts including Japanese game-directory/startup loading, inventory and clean child source check. |
| [Source contracts 134278546904](https://github.com/AetherKiri/Aether/actions/runs/44150877791/job/134278546904) | Passed, 7s | 20 selector, initialization, fixture and binary-inspection helper tests. |
| [Godot shell 134278547659](https://github.com/AetherKiri/Aether/actions/runs/44150877791/job/134278547659) | Passed, 20s | Five shell suites with native extension intentionally absent. |

The native-path correction preserves Windows filesystem paths through script, loose-art and GTB/GPK IO without changing CP932 resource keys. At the intermediate `b634edba`, every provider functional fixture passed but the process failed in final temporary-directory cleanup: the process-global ABI diagnostic sink still held a log open. The test-only `b72bdca3` correction reports cleanup errors and retains remaining files, keeping assertion failures fatal. The common logger lifecycle was not changed.

The Windows focused dependency cache was an exact hit at `b634edba`; vcpkg restored 17 packages in 2.9 seconds. Final desktop source remained the same except that cleanup handling. Full successful run log is retained locally at `/tmp/systemnnn-b72-native.log`. These contract results do not establish complete product packaging or authorize binary distribution.

## Historical desktop attempts

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
