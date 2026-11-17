# SystemNNN Linux production validation

Local validation performed on 2026-11-17 using the production `aether_kiri_godot` target, public KiriKiri, and the SystemNNN provider. This is development evidence, not authorization to distribute binaries; the license gate in [systemnnn_redistribution.md](systemnnn_redistribution.md) remains open.

## Tested source and binary

The checkout HEAD was `cf406eb2337bc9c1f4aa83e0da9a276f9e531630` with uncommitted provider/presenter fixes and the two Linux CMake fixes described below. The observed source hashes, dirty status, and submodule identities are retained locally in `/var/lib/dsh/systemnnn/tools/systemnnn-registration/tested-source-provenance.json`. HEAD alone does not identify the tested source tree.

The final production library is `build/systemnnn-production/bridge/godot_extension/libaether_kiri_godot.so`, SHA-256 `3f3821f74e4eda6ed309b1d6ed45c6ff0fbaad4448398f21a30c50e589be870e`. Its staged copy has the same hash. The final stable-provider incremental build completed all three steps and linked the real shared library successfully.

## Selected toolchain and dependencies

- Linux x86-64, GCC 13.3, CMake 3.28.3, Ninja, Release.
- Only `KRKR2;SYSTEMNNN` selected. Private Internal package unavailable; public fallbacks used.
- Current godot-cpp overlay: 10.0.0-stable, API 4.7, template_release. Verified with official Godot 4.7.2 `ed1daf0bf`. The initially supplied Godot 4.6 is older than this API and was not used to claim matching verification.
- Current FFmpeg overlay 8.1.2, shared, selected libraries avcodec/avformat/avfilter/avutil/swscale/swresample. System FFmpeg 6.1 lacks the `av_opt_set_array` API used by public KiriKiri and cannot compile that source unchanged.
- Highway 1.4.0, the current port version, built externally. System Highway 1.0.7 lacks `Dup128VecFromValues`.
- libgdiplus 5.6.1 with the repository overlay patches, shared, built externally; public KiriKiri consumes its private drawing headers.
- Selective vcpkg installation of godot-cpp, 7zip, and FFmpeg; the root manifest was not installed. Other dependencies use installed system development packages and external CMake package adapters. Public AetherKrkr, psdfile, and psdfile's psdparse submodule were initialized.

The source was initially left unchanged. Public Linux header propagation issues were supplied through build flags: vcpkg include root for 7zip, FreeType include root, and `-include limits.h` for PATH_MAX. The GDI generated configuration header is supplied through CPATH. OpenCV's umbrella include requires the additional module headers beyond core/imgproc.

## Minimal configure and build

The exact host-local configure is retained in `/var/lib/dsh/systemnnn/tools/systemnnn-production-configure.sh`. Its essential selection is:

```sh
VCPKG_ROOT=/var/lib/dsh/systemnnn/tools/vcpkg cmake -S . -B build/systemnnn-production -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DLINUX=ON -DVCPKG_MANIFEST_MODE=OFF \
  -DVCPKG_TARGET_TRIPLET=x64-linux \
  -DAETHERKIRI_RUNTIMES_DEFAULT=OFF \
  -DAETHERKIRI_ENABLE_KRKR2=ON -DAETHERKIRI_ENABLE_SYSTEMNNN=ON \
  -DAETHERKIRI_ENABLE_INTERNAL=OFF \
  -DBUILD_ENGINE_API=ON -DBUILD_GODOT_EXTENSION=ON \
  -DBUILD_TOOLS=OFF -DENABLE_TESTS=OFF -DBUILD_TESTING=OFF \
  -DCMAKE_FIND_PACKAGE_PREFER_CONFIG=ON \
  -DCMAKE_PREFIX_PATH=/var/lib/dsh/systemnnn/tools/system-package-adapters \
  -DCMAKE_MODULE_PATH=/var/lib/dsh/systemnnn/tools/system-package-adapters/modules \
  -Dzstd_DIR=/var/lib/dsh/systemnnn/tools/system-package-adapters/zstd \
  -Dlibgdiplus_DIR=/var/lib/dsh/systemnnn/tools/libgdiplus-prefix/share/libgdiplus \
  -Dhwy_DIR=/var/lib/dsh/systemnnn/tools/highway-1.4-prefix/lib/cmake/hwy \
  -Dunofficial-godot-cpp_DIR=/var/lib/dsh/systemnnn/tools/vcpkg/installed/x64-linux/share/unofficial-godot-cpp \
  '-DCMAKE_CXX_FLAGS=-isystem /var/lib/dsh/systemnnn/tools/vcpkg/installed/x64-linux/include -isystem /usr/include/freetype2 -include limits.h'
CPATH=/var/lib/dsh/systemnnn/tools/libgdiplus-build \
  cmake --build build/systemnnn-production --target aether_kiri_godot --parallel 3
```

These absolute dependency adapters are local setup, not committed product configuration. A fresh machine must provision equivalent dependencies or use the normal project dependency setup. No existing files were deleted. Approximately 4.5 GiB remained free after validation; concurrent Android toolchain installation also consumed disk during this session.

## Linux archive cycle correction

The first complete production link failed because CMake repeated the cyclic krkr2plugin static dependency twice under WHOLE_ARCHIVE, emitting duplicate definitions from the same archive objects. The authorized correction in [../bridge/godot_extension/CMakeLists.txt](../bridge/godot_extension/CMakeLists.txt) and [../bridge/krkr2_runtime/CMakeLists.txt](../bridge/krkr2_runtime/CMakeLists.txt) applies the existing Web approach to Linux: keep target-based krkr2plugin dependencies normal and force-load its archive path once at the final extension link. The Linux core-module RESCAN group remains intact.

The generated link was asserted to have exactly one whole-archive krkr2plugin path and one start/end rescan group. No multiple-definition suppression was used. The production link passed; `aether_kiri_library_init` is exported. Normal-environment `ldd -r` on the staged extension reported no missing libraries or undefined symbols.

## Graphical verification

An isolated authored fixture and test project live under `/var/lib/dsh/systemnnn/tools/systemnnn-registration`. No commercial game content was used. Godot ran under Xvfb using X11, OpenGL 4.5 compatibility, and Mesa llvmpipe. The test used Godot's Dummy audio driver; SystemNNN separately logged unavailable OpenAL hardware and continued gracefully. This does not establish audible output on physical hardware.

Graphical registration returned load result 0, registered AetherRuntimePlayer, and returned SystemNNN positive probe 100 / negative probe 0. The final runtime exercise, with LD_LIBRARY_PATH unset, passed:

- Load the actual production extension and instantiate its registered class.
- Open the mixed-case resource fixture in a Unicode path; show title and produce Godot textures.
- Enter the story; check exact RGB (180,30,60) and rendered authored dialogue.
- Respect progressive reveal completion before input advancement.
- Save PC slot 13, check its file, advance dialogue, load, and restore the script continuation word.
- Select choice 2 with keyboard input; check the resulting RGB (10,80,220) and visible selected-route dialogue.
- Count 976 bright glyph pixels in the story text region and 647 in the selected-route region.

The final run exited 0 with `SYSTEMNNN_GRAPHICAL_PRODUCTION_EXERCISE_OK`. Local evidence:

- `runtime-glyphs.log` and `runtime_exercise.gd`: exact final exercise and assertions.
- `production-story-finished.png` / `production-choice-finished.png`: 800x600 Godot texture readbacks showing independently authored dialogue.
- `production-readelf.txt`, `production-ldd-relocations.txt`, `production-sha256.txt`: binary identity and loader evidence.
- `bundle-final/closure.json`: all staged external dependency sources and normal loader resolution.

## Staging boundary

The raw build output has RUNPATH=$ORIGIN but its companion dependency libraries are in other build/prefix directories; raw unstaged ldd therefore reports missing dependencies. The local development bundle copies engine_api, 7zip, patched GDI, and the FFmpeg libraries into one directory and sets their RUNPATH to $ORIGIN. With LD_LIBRARY_PATH unset, all dependencies and relocations resolve and the graphical exercise passes. It still relies on this host's installed distro libraries (including SDL2, OpenCV, Boost, FreeType and OpenAL); it is not a self-contained Linux distribution or a clean-machine packaging certification.

The tested bundle remains local development output. No binary release, upload, or redistribution approval was performed. Resolve the documented license gate before any redistribution.

The graphical exercise is now reproducible from source via [tests/systemnnn_godot/README.md](../tests/systemnnn_godot/README.md). Its standard-library Python preparer generates an independently authored SPT story and fresh Godot project; the harness accepts configurable extension, fixture, writable, output, and font paths. A fresh generated project was run against the same staged production library with Godot 4.7.2/X11 and LD_LIBRARY_PATH unset, without rebuilding production: exit 0, SYSTEMNNN_GRAPHICAL_PRODUCTION_EXERCISE_OK, 976 story glyph pixels and 647 selected-route glyph pixels. The local portable-run evidence is /var/lib/dsh/systemnnn/tools/systemnnn-portable-verification/run.log and its artifacts directory. No opaque /tmp fixture is required.
