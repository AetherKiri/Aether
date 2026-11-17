# SystemNNN native sanitizer validation

## Final native-path revision

After pinning Emberfall `e5ca4283b9c4f933f9cea9d486239396eeb9b086` at Aether `b634edba5630429ca1cbae2003e4ded1cc389524`, rebuilt the instrumented targets and ran all ten native CTests with `ASAN_OPTIONS=detect_leaks=1:halt_on_error=1`, `UBSAN_OPTIONS=halt_on_error=1`, `--timeout 240 -E java`. All ten passed in 136.03 seconds; provider 127.25 seconds. No sanitizer diagnostics were reported. Exact retained CTest output is under `build/systemnnn-native-asan/Testing/Temporary/LastTest.log`. This rerun covers the final native-path correction, and supersedes the earlier snapshot-only limitation. The build below was reused incrementally with unchanged instrumentation; this was not a second fresh configure.

Validated on Linux x86-64 with GCC 13.3.0 on 2026-11-17, against source revision `81c096263cc74a09faabaf9ce621306883ad1a86`. The validation changed no runtime source or existing build files. It used a separate `build/systemnnn-native-asan` directory; the normal native build was untouched.

## Reproduce

Run from the repository root. System dependencies must already be available, as for the normal native contracts. Debug symbols were limited to `-g1` to keep the build within the available disk budget.

```sh
cmake -S tests/systemnnn_native -B build/systemnnn-native-asan -G Ninja \
  -DCMAKE_BUILD_TYPE=Debug \
  '-DCMAKE_C_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer' \
  '-DCMAKE_CXX_FLAGS=-fsanitize=address,undefined -fno-omit-frame-pointer' \
  -DCMAKE_C_FLAGS_DEBUG=-g1 -DCMAKE_CXX_FLAGS_DEBUG=-g1 \
  '-DCMAKE_EXE_LINKER_FLAGS=-fsanitize=address,undefined' \
  '-DCMAKE_SHARED_LINKER_FLAGS=-fsanitize=address,undefined' \
  '-DCMAKE_MODULE_LINKER_FLAGS=-fsanitize=address,undefined'

cmake --build build/systemnnn-native-asan --target \
  systemnnn-provider-contract systemnnn-text-contract \
  systemnnn-startup-contract systemnnn-progress-contract \
  systemnnn-audio-contract systemnnn-presenter-contract \
  systemnnn-native-panel-contract systemnnn-minigame-contract \
  systemnnn-minigame-binding-contract systemnnn-dialogue-reveal-contract -j2

ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
ALSOFT_DRIVERS=null \
./build/systemnnn-native-asan/systemnnn-provider-contract

ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
ctest --test-dir build/systemnnn-native-asan -E 'provider|java' --output-on-failure
```

The full provider executable ran directly and completed in **126.76 seconds**. No provider test filter was set. The final source revision configures a **240-second provider CTest timeout** (the helper defaults are 120 seconds); the earlier reason recorded for choosing direct execution referred to the old 120-second limit. The direct process exit remains the execution evidence. The helper command selects the nine remaining native contracts. Java parity tests were excluded from this sanitizer run.

## Recorded results and evidence

| Check | Result | Elapsed |
| --- | --- | --- |
| Configure and build | Exit 0; all 78 build steps completed | Build: 137.50 s |
| Full provider contract | Exit 0 | 126.76 s |
| Nine native helper contracts | Exit 0; 9/9 passed | 10.17 s |

No AddressSanitizer, UndefinedBehaviorSanitizer, or LeakSanitizer diagnostic was reported by these runs. This evidence covers the exercised fixtures and instrumented project code; it does not establish that all possible executions are free of defects. System libraries were linked from the host installation.

Retained helper output is in [LastTest.log](../build/systemnnn-native-asan/Testing/Temporary/LastTest.log), with per-test timings in [CTestCostData.txt](../build/systemnnn-native-asan/Testing/Temporary/CTestCostData.txt). These are local build artifacts and may be replaced by later CTest runs.

The original provider stdout/stderr and exit status were captured by harness job `bash-edcf8b5c10a8487a` (2026-11-17 17:49:42.396–17:51:49.156 UTC). That invocation did not redirect to a standalone log file. Its temporary fixture root was `/tmp/aether-systemnnn-534062791022221`; successful completion removed the fixtures and their engine logs. The helper capture was job `bash-ee0baaef807a44db`.

The isolated build occupied **741 MB** after completion; **3.8 GB** remained free, above the requested 2 GB reserve.
