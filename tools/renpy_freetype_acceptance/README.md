# FreeType native export-generator acceptance

Run the actual FreeType 2.13.3 unpack/build/install tasks from pinned
`renpy-build` commit `7bfab40c1174f622f644b24669afd5fb167fbb79`, applying the complete
native patch series to a fresh scratch checkout:

```sh
python tools/test_renpy_mobile_freetype_host_tools.py /path/to/renpy-build \
  --output-dir /tmp/renpy-freetype-host-tools --jobs 3
```

The driver needs the pinned source checkout, Python with Jinja2, make, pkg-config
and the platform's real compiler tools. On an arm64 Mac it uses the selected
Xcode's macOS, iPhoneOS and iPhoneSimulator SDKs. On Linux it checks a native
archive; add `--ndk /path/to/android-ndk-r29` for a real Android AArch64 API 21
cross archive. No target SDK or compiler is simulated.

The source tar's SHA256 must be
`5c3a8e78f7b24c20b25b54ee575d6daa40007a5f4eea2845861c3409b3021747`.
The test invokes production `Context` and `Task.run`, replacing missing compiler
cache locations with genuine local compiler executables and preserving target
flags. It loads the FreeType recipe in isolation; it does not claim the full
Ren'Py dependency graph was run. The native Linux case uses the installed native
compiler rather than requiring the unrelated production Linux sysroot.

FreeType's host `apinames` must execute and generate `ftexport.sym`, including
the existing OpenType validation and TrueType interpreter exports. Before the
actual `make install`, the driver removes the exporter and its output, requiring
the install invocation to compile and run the host exporter again. It checks
all objects in the installed static archive and checks defined FreeType API
symbols. On Mac, `apinames` must identify macOS platform 1; target objects must
identify macOS 1, iOS device 2 or iOS Simulator 7 as appropriate. CPU checks alone
cannot distinguish those platforms. On Linux, the exporter must be a native
ELF executable and the Android archive must contain AArch64 ELF objects.

Each case preserves its production commands, unchanged target environment,
build log, actual host executable and compiler wrapper, generated export file,
actual installed archive, defined-symbol listing and result JSON with hashes.
The driver executes the host exporter; it does not execute target libraries,
launch an app, or validate gameplay. The HarfBuzz-enabled recipe receives the
same production fix, but this focused driver runs the base FreeType recipe;
the complete source pipeline must still validate its HarfBuzz dependency.

Patch `0012-freetype-host-tools.patch` supplies a separate native C compiler
wrapper. On Darwin it selects the real macOS compiler and canonical macOS SDK,
queries the native target triple with cross deployment variables removed, and
then explicitly selects that triple and SDK. Only the host compiler child loses
the iOS/tvOS/watchOS/visionOS/DriverKit deployment variables and `SDKROOT`.
The target compiler and flags stay in the production context. Both FreeType
recipes pass `CC_BUILD` for configure and override `CCexe`, `CCexe_CFLAGS` and
`CCexe_LDFLAGS` on both make and install. This also covers configure's branch
that resets `CC_BUILD` to the target `CC` when a target conftest appears runnable.

The upstream contracts are visible in
[configure.raw](https://github.com/freetype/freetype/blob/VER-2-13-3/builds/unix/configure.raw),
[unix-cc.in](https://github.com/freetype/freetype/blob/VER-2-13-3/builds/unix/unix-cc.in)
and [exports.mk](https://github.com/freetype/freetype/blob/VER-2-13-3/builds/exports.mk).
Upstream uses `CC_BUILD` and the make `CCexe*` variables for this tool;
`CFLAGS_BUILD` and `LDFLAGS_BUILD` are not the relevant hooks.
