# Native lifecycle patch

The source runner applies these patches to the pinned SDL2/Python3
renpy-build revision, then copies `renpy_mobile_lifecycle.c` and the versioned
ABI header into that checkout. It compiles the shared native lifecycle and
linked greenlet for Android and every selected iOS target. The platform
bootstrap initializes CPython without calling the process launchers.

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

These sources need actual target compilation and cloud-device gameplay
acceptance. A successful host compilation or exported-symbol check is not
mobile playability evidence. The iOS MetalANGLE host rendering integration
remains blocked and the provider refuses it explicitly.
