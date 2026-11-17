# SystemNNN Android and iOS native validation

Verified on 2026-11-17 against Aether commit `de4a1f29781babddc7a302260ed6e4869d644e7b` and Emberfall commit `f52d77fe05104726d35389266f0ba6f5be3a3f59`. The [focused mobile workflow](../.github/workflows/systemnnn-mobile.yml) [completed successfully](https://github.com/AetherKiri/Aether/actions/runs/44140280096) on both targets.

| Target | Hosted job | Result |
| --- | --- | --- |
| Android arm64 | [134241016133](https://github.com/AetherKiri/Aether/actions/runs/44140280096/job/134241016133), Ubuntu 24.04 | Compile, complete adapter link, installation and binary inspection passed in 2m58s |
| iPhoneOS arm64 | [134241016761](https://github.com/AetherKiri/Aether/actions/runs/44140280096/job/134241016761), macOS 15 | Compile, complete adapter link, installation and binary inspection passed in 1m24s after runner allocation |

## Scope and dependency inputs

The [standalone CMake project](../tests/systemnnn_mobile/CMakeLists.txt) builds the production ABI, SystemNNN adapter, Emberfall scene/core libraries and their native dependency closure. Its final target uses CMake `WHOLE_ARCHIVE`, mapped to `--whole-archive` on Android and `-force_load` on iOS, so the link checks every adapter object. [Reproduction commands](../tests/systemnnn_mobile/README.md) use an isolated dependency installation and avoid the root product manifest and Godot build.

The [focused manifest](../tests/systemnnn_mobile/vcpkg.json) pins vcpkg baseline `9eec002df1cd109f8f104cd966a763daf9751489`, matching the product baseline. Observed dependency versions on both target builds were FFmpeg 9.0.2#1, fmt 12.2.0#1, spdlog 1.17.0#1, FreeType 2.14.3, libiconv 1.19#1, libpng 1.6.59, zlib 1.3.2#2, nlohmann-json 3.12.0#2 and OpenAL Soft 1.25.2. FFmpeg enables avcodec, avformat, swresample and swscale, with avutil in the resulting closure. This does not establish support for every product codec or game asset.

The [Android overlay triplet](../tests/systemnnn_mobile/triplets/arm64-android.cmake) includes the [product Android triplet](../vcpkg/triplets/arm64-android.cmake), selects shared libc++ and builds Release dependencies. The [iOS overlay triplet](../tests/systemnnn_mobile/triplets/arm64-ios.cmake) includes the [product iOS triplet](../vcpkg/triplets/arm64-ios.cmake) and builds Release dependencies. Dependencies remain static libraries except the explicitly packaged Android shared C++ runtime and ABI DSO.

## Android evidence

The hosted log identifies NDK r28b `28.1.13356709`, Clang `19.0.0` and `--target=aarch64-none-linux-android24`. The outer adapter configuration explicitly selects `CMAKE_SYSTEM_NAME=Android` and chainloads the NDK CMake toolchain through vcpkg; selecting only an Android dependency triplet is insufficient to select the outer compiler.

The final shared-library link rejects undefined symbols and sets a maximum page size of 16384 bytes. The [Android inspector](../tests/systemnnn_mobile/inspect_android.py) passed these checks for the adapter probe, ABI DSO and shared libc++:

- Every packaged DSO reports `Machine: AArch64`.
- Every observed LOAD segment has 16384-byte alignment.
- DT_NEEDED entries resolve to packaged libraries or Android platform libraries. The adapter uses the packaged ABI DSO and shared libc++, plus platform libc, libm, libdl, liblog, libandroid and libmediandk.
- `aether_systemnnn_register_runtime` and `aether_systemnnn_mobile_link_probe` are defined exports.

A local NDK build also passed all 58 build/link steps, installation and inspection. After the final provider/presenter changes stabilized, all four affected compile/link steps and inspection passed again. The captured provider, presenter and dialogue-helper SHA-256 values match the final committed source. Local evidence remains under the ignored build directory; the hosted job is the portable review reference.

## iOS evidence and iconv correction

The final hosted log identifies AppleClang `17.0.0.17000013`, Xcode 16.4 and the iPhoneOS 18.5 SDK. All 57 build/link steps passed. The [iOS inspector](../tests/systemnnn_mobile/inspect_ios.py) verified a Mach-O arm64 executable, `LC_BUILD_VERSION` platform `2` (iOS), minimum iOS `16.0`, defined registration/probe symbols and exclusively system dynamic dependencies. Observed dynamic dependencies were libSystem, libc++, AudioToolbox, CoreFoundation, CoreAudio, VideoToolbox, CoreMedia and CoreVideo. No signing secrets were required.

The earlier [iOS link attempt](https://github.com/AetherKiri/Aether/actions/runs/44137822250/job/134232348375) compiled all source files but failed at the final link on `_libiconv`, `_libiconv_open` and `_libiconv_close`. The pinned vcpkg wrapper preferred Apple SDK `-liconv`, while common dependency include paths exposed GNU iconv headers that reference the GNU-prefixed symbols.

The [production adapter configuration](../bridge/systemnnn_runtime/CMakeLists.txt) now selects the matching target GNU header, libiconv archive and libcharset archive for iOS with vcpkg. It checks the required files and GNU header marker, and refreshes an existing imported Iconv target if an earlier discovery selected the SDK library. The successful job reports `Found Iconv` with both target archives and version 1.19; its final force-load link includes both archives. Undefined-symbol checks were preserved. The standalone iOS probe also disables CMake’s default application-bundle behavior so it installs as the intended executable.

## Retained evidence and limits

The successful run uploads textual binary inspection output, compile commands, source revisions, CMake cache, vcpkg status and diagnostics. Its Android diagnostic artifact is ID `14354337258` (1246705 bytes); its iOS diagnostic artifact is ID `14354428187` (113604 bytes), available from the [run page](https://github.com/AetherKiri/Aether/actions/runs/44140280096). Native package binaries are excluded from these uploads. License compatibility remains unresolved; this validation does not authorize distribution of combined binaries.

These results establish native cross-compilation, complete adapter linking and inspection of developer probe packages. They do not establish APK/IPA creation, Godot export acceptance, simulator/device execution, game playback or runtime behavior on Android or iOS. No mobile device was available for this validation.
