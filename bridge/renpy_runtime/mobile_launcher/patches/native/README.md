# Native lifecycle patch

The source runner applies these patches to the pinned SDL2/Python3
renpy-build revision, then copies `renpy_mobile_lifecycle.c` and the versioned
ABI header into that checkout. It compiles the shared native lifecycle and
linked greenlet for Android and every selected iOS target. The platform
bootstrap initializes CPython without calling the process launchers.

`0001-renpy-build-link.patch` also includes the static Cython output directory
when compiling Ren'Py's C and C++ sources. Its generated surface API header
lives in `tmp/gen3-static`, so a clean rebuild does not depend on a previous
desktop generation having populated `tmp/gen3`.

`0005-optional-cubism.patch` keeps the base runtime build independent of the
optional licensed SDKs. It enables Live2D generation and its native module only
when the target Cubism header exists, and packages `steamapi` only when the
Steam task actually generated that module. Games that require Live2D still
need the Cubism SDK and its runtime library; supplying the header preserves the
upstream compilation path. No native build tasks are marked complete by this
patch.

`0007-darwin-ios-build.patch` builds the complete iOS dependency chain on a
macOS cloud runner using the selected Xcode SDKs in place. The source runner
selects device arm64 and simulator arm64, and packages those slices under the
existing `release` and `debug` directories. Install Homebrew `autoconf`,
`autoconf-archive`, `automake`, `libtool`, `pkg-config`, `ccache`, `cmake`,
`ninja`, `uv`, `python@3.12`, `openssl@3`, `xz`, `bzip2`, `libffi`, `gnu-tar`
and `coreutils`. Put the GNU tar and coreutils `libexec/gnubin` directories on
PATH, select Xcode, then run the source runner's `prepare --fetch` and `build`
modes with `--platform ios`. The runner derives host dependency prefixes and
`config.sub` from the installed Homebrew packages. It requires actual Xcode
tools, all three local SDKs and 64 GiB of free disk; it does not substitute
prerequisite fixtures. The port still needs a successful native macOS build
and simulator gameplay before it establishes iOS runtime support.
The Autoconf compiler environment uses unquoted tool and SDK paths from Xcode;
the cloud build requires these paths to contain no whitespace and rejects
unsupported paths explicitly. Quoted path text inside `CC` is interpreted as
part of the executable name by the pinned configure scripts. CI preserves their
`config.log` files alongside the source-build log when compilation fails.

The Darwin port also backports libffi's upstream fix
[`8308bed5`](https://github.com/libffi/libffi/commit/8308bed5b2423878aa20d7884a99cf2e30b8daf7)
to the pinned 3.4.5 source archive. Three arm64 entry labels precede
`cfi_startproc`, as required by LLVM 17 and later when assembling Mach-O.
Unwind metadata remains enabled. The unpack task applies this patch before
any target compilation; it does not replace the pinned libffi dependency.
The MetalANGLE annotator keeps its header paths and definitions in compiler
flags and supplies `-framework MetalANGLE` through linker flags. Compile-only
dependency builds retain their strict warning checks.

`0009-bounded-build-parallelism.patch` limits the upstream native object build
group to the host CPU count. Set `RENPY_BUILD_JOBS` to a positive integer to
select another limit. Child compiler failures still fail the build, and an
exception cancels queued work and joins running child processes. This limits
concurrent compiler memory use; it does not change source-build prerequisites.

`renpy_mobile_lifecycle.c` owns the copied host callback table and the borrowed
frame byte storage. It invokes the full cooperative Python entrypoints,
preserves pointer/key/text actions, publishes renderer screenshots and
returns observable normal-exit and text-input state. Window binding connects
the real SDL renderer window to the Android EGL context handoff.

Terminal shutdown runs on the interpreter's owning thread while its healthy
private context is current. The cooperative patch stops the engine timers,
retires GL2 Program destructors before dropping cached references, and destroys
the Python-owned SDL window, context and pbuffer. Programs retained by script
stores or texture loaders cannot later delete a host GL program during garbage
collection. SDL hint override keeps `AETHER_RENPY_EMBEDDED` true throughout the
window and video teardown; the existing SDL patch skips `eglTerminate` on the
shared display. Normal bootstrap renderer teardown is not repeated.

Shutdown is terminal: another Ren'Py session requires restarting the host.
If its private EGL context cannot be made current or Python cleanup fails,
native reports the failure, retains the session and clears host callbacks.
It never substitutes the current host context for deleting Ren'Py resources.
Recovery from genuine EGL context/display loss remains unimplemented; this
does not imply an ordinary host Surface replacement destroys the private
pbuffer. Real long-background, rotation and context-loss stress acceptance
is still required.

These sources need actual target compilation and cloud-device gameplay
acceptance. A successful host compilation or exported-symbol check is not
mobile playability evidence. iOS startup requires the patched offscreen
MetalANGLE driver; successful renderer probes do not establish full Ren'Py
gameplay, input, pause/resume or shutdown acceptance.
