#!/usr/bin/env python3
"""Run the pinned FreeType task, its real host exporter and target archive.

Darwin checks native macOS plus real device/Simulator SDK builds. Linux checks
the native library and, with --ndk, a genuine Android AArch64 cross archive.
The genuine native apinames executable is run; target libraries are not run.
"""
import argparse
from contextlib import contextmanager
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
PIN = "7bfab40c1174f622f644b24669afd5fb167fbb79"
SOURCE_SHA256 = "5c3a8e78f7b24c20b25b54ee575d6daa40007a5f4eea2845861c3409b3021747"
TARGET_VARIABLES = ("CC", "CXX", "CPP", "AR", "RANLIB", "NM", "CFLAGS", "CXXFLAGS",
                    "CPPFLAGS", "LDFLAGS", "SDKROOT", "IPHONEOS_DEPLOYMENT_TARGET")


def command(arguments, *, cwd, env=None):
    result = subprocess.run(list(map(str, arguments)), cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {shlex.join(map(str, arguments))}\n"
                           + result.stdout[-8000:])
    return result.stdout


@contextmanager
def build_log(path):
    sys.stdout.flush()
    sys.stderr.flush()
    previous = [os.dup(1), os.dup(2)]
    try:
        with path.open("w") as output:
            os.dup2(output.fileno(), 1)
            os.dup2(output.fileno(), 2)
            yield
    finally:
        sys.stdout.flush()
        sys.stderr.flush()
        for descriptor, saved in zip((1, 2), previous):
            os.dup2(saved, descriptor)
            os.close(saved)


def object_identity(data):
    if data[:4] == b"\x7fELF":
        endian = "<" if data[5] == 1 else ">"
        return {"format": "ELF", "machine": struct.unpack_from(endian + "H", data, 18)[0]}
    assert data[:4] == bytes.fromhex("cffaedfe"), "A genuine ELF or Mach-O64 object is required"
    machine, commands = struct.unpack_from("<I", data, 4)[0], struct.unpack_from("<I", data, 16)[0]
    offset = 32
    platforms = []
    for _ in range(commands):
        kind, size = struct.unpack_from("<II", data, offset)
        assert size >= 8
        if kind == 0x32:  # LC_BUILD_VERSION
            platforms.append(struct.unpack_from("<I", data, offset + 8)[0])
        elif kind in (0x24, 0x25):  # LC_VERSION_MIN_MACOSX / IPHONEOS
            platforms.append(1 if kind == 0x24 else 2)
        offset += size
    assert len(set(platforms)) == 1, "The Mach-O must identify its actual platform"
    return {"format": "Mach-O", "machine": machine, "platform": platforms[0]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_source", type=Path)
    parser.add_argument("--ndk", type=Path, help="Real Android NDK r29; Linux cross-build acceptance")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--jobs", type=int, default=3)
    args = parser.parse_args()
    assert args.jobs > 0
    assert command(["git", "rev-parse", "HEAD"], cwd=args.build_source).strip() == PIN
    evidence = (args.output_dir or Path(tempfile.mkdtemp(prefix="renpy-freetype-evidence-"))).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    print("FreeType evidence:", evidence, flush=True)
    patches = sorted((REPO / "bridge/renpy_runtime/mobile_launcher/patches/native").glob(
        "[0-9][0-9][0-9][0-9]-*.patch"))
    assert any(path.name.startswith("0012-") for path in patches)

    with tempfile.TemporaryDirectory(prefix="renpy-real-freetype-tools-") as temporary:
        root = Path(temporary) / "renpy-build"
        command(["git", "clone", "--no-local", "--depth=1", "--single-branch", "--quiet", "--no-checkout",
                 args.build_source.resolve(), root], cwd=REPO)
        command(["git", "checkout", "--quiet", "--detach", PIN], cwd=root)
        command([sys.executable, REPO / "tools/apply_renpy_mobile_patch_series.py",
                 "--checkout", root, "--pin", PIN, *patches], cwd=REPO)
        assert hashlib.sha256((root / "source/freetype-2.13.3.tar.gz").read_bytes()).hexdigest() == SOURCE_SHA256
        sys.path.insert(0, str(root))
        from renpybuild.context import Context
        from renpybuild.task import annotators, tasks
        specification = importlib.util.spec_from_file_location("freetype", root / "tasks/freetype.py")
        module = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(module)
        selected = {task.task: task for task in tasks if task.name == "freetype"}

        class TrackingContext(Context):
            def run(self, template, verbose=False, quiet=False, **kwargs):
                arguments = shlex.split(self.expand(template, **kwargs))
                self.calls.append(arguments)
                if arguments[0] == "./configure":
                    self.target_before = {name: self.environ.get(name) for name in TARGET_VARIABLES}
                if arguments[:2] == ["make", "install"]:
                    # Exercise install's real exporter rebuild, not just an
                    # up-to-date install that never uses its CCexe assignment.
                    (self.cwd / "objs/apinames").unlink()
                    (self.cwd / "objs/ftexport.sym").unlink()
                return super().run(template, verbose=verbose, quiet=quiet, **kwargs)

        native_machine = {"x86_64": 62, "aarch64": 183, "arm64": 183}[platform.machine()]
        if sys.platform == "darwin":
            assert platform.machine() == "arm64", "This iOS acceptance uses a genuine arm64 Mac runner"
            cases = [("mac-host", "mac", "arm64", "macosx", 1),
                     ("ios-device", "ios", "arm64", "iphoneos", 2),
                     ("ios-simulator", "ios", "sim-arm64", "iphonesimulator", 7)]
        else:
            assert sys.platform == "linux"
            cases = [("linux-host", "linux", platform.machine(), None, None)]
            if args.ndk:
                ndk = args.ndk.resolve(strict=True)
                assert 'Pkg.Revision = 29.' in (ndk / "source.properties").read_text()
                toolchain = ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin"
                assert (toolchain / "clang").is_file()
                cases.append(("android-arm64", "android", "arm64_v8a", None, None))

        for label, target_platform, architecture, sdk_name, expected_platform in cases:
            case = evidence / label
            case.mkdir(exist_ok=True)
            sdk = None
            if sdk_name:
                sdk = Path(command(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], cwd=REPO).strip()).resolve(strict=True)
                cross_sdk = root / f"tmp/cross.{target_platform}-{architecture}/sdk"
                cross_sdk.parent.mkdir(parents=True, exist_ok=True)
                cross_sdk.symlink_to(sdk)

            def real_compilers(context):
                context.var("make", "nice make -j " + str(args.jobs))
                # Preserve the production target flags, replacing only missing
                # cache/tool executable locations with genuine local compilers.
                if target_platform == "android":
                    cc = [str(toolchain / "clang"), "--target=aarch64-linux-android21", "-std=gnu17"]
                    cpp = cc[:-1] + ["-E"]
                    ar, ranlib, nm = [str(toolchain / name) for name in ("llvm-ar", "llvm-ranlib", "llvm-nm")]
                elif sdk:
                    cc = shlex.split(context.environ["CC"])
                    assert cc.pop(0) == "ccache"
                    cpp = shlex.split(context.environ["CPP"])
                    assert cpp.pop(0) == "ccache"
                    ar, ranlib, nm = [context.environ[name] for name in ("AR", "RANLIB", "NM")]
                    context.env("SDKROOT", str(sdk))
                else:
                    cc = [shutil.which("cc")]
                    cpp = cc + ["-E"]
                    ar, ranlib, nm = [shutil.which(name) for name in ("ar", "ranlib", "nm")]
                    context.var("cross_config", "--build=" + command([cc[0], "-dumpmachine"], cwd=REPO).strip()
                                + " --host=" + command([cc[0], "-dumpmachine"], cwd=REPO).strip())
                assert all(cc) and ar and ranlib and nm
                context.env("CC", shlex.join(cc))
                context.env("CPP", shlex.join(cpp))
                for variable, value in (("AR", ar), ("RANLIB", ranlib), ("NM", nm)):
                    context.env(variable, value)

            annotators.append(real_compilers)
            context = TrackingContext(target_platform, architecture, "3", root, SimpleNamespace())
            context.calls = []
            print("Actual FreeType production task:", label, flush=True)
            try:
                with build_log(case / "production-build.log"):
                    selected["unpack"].run(context)
                    selected["build"].run(context)
            except BaseException:
                print("New FreeType build errors:", (case / "production-build.log").read_text(errors="replace")[-8000:], flush=True)
                raise
            finally:
                annotators.remove(real_compilers)
            assert context.target_before == {name: context.environ.get(name) for name in TARGET_VARIABLES}
            (case / "production-commands.json").write_text(json.dumps(context.calls, indent=2) + "\n")
            (case / "target-toolchain.json").write_text(json.dumps(context.target_before, indent=2) + "\n")
            source = context.cwd
            apinames = source / "objs/apinames"
            shutil.copy2(apinames, case / "apinames")
            shutil.copy2(context.build / "aether-freetype-host-cc", case / "aether-freetype-host-cc")
            exports = (source / "objs/ftexport.sym").read_text()
            assert "FT_Init_FreeType" in exports and "FT_OpenType_Validate" in exports
            assert "TT_New_Context" in exports and "TT_RunIns" in exports
            shutil.copy2(source / "objs/ftexport.sym", case / "ftexport.sym")
            host_identity = object_identity(apinames.read_bytes())
            if sys.platform == "darwin":
                assert host_identity == {"format": "Mach-O", "machine": 0x100000C, "platform": 1}
            else:
                assert host_identity == {"format": "ELF", "machine": native_machine}
            archive = context.install / "lib/libfreetype.a"
            assert archive.is_file()
            shutil.copy2(archive, case / "libfreetype.a")
            members = command([context.environ["AR"], "t", archive], cwd=root).splitlines()
            objects = [member for member in members if member.endswith(".o")]
            assert objects
            identities = []
            for member in objects:
                data = subprocess.check_output([context.environ["AR"], "p", str(archive), member], cwd=root)
                identity = object_identity(data)
                expected = {"format": "Mach-O", "machine": 0x100000C, "platform": expected_platform} if sdk \
                    else {"format": "ELF", "machine": 183 if target_platform == "android" else native_machine}
                assert identity == expected, (member, identity, expected)
                identities.append(identity)
            nm_flags = ["-g", "-U"] if sys.platform == "darwin" else ["--defined-only", "--extern-only"]
            defined = command([context.environ["NM"], *nm_flags, archive], cwd=root)
            names = {line.split()[-1].lstrip("_") for line in defined.splitlines() if line.split()}
            assert {"FT_Init_FreeType", "FT_OpenType_Validate"} <= names
            (case / "defined-symbols.txt").write_text(defined)
            result = {"status": "passed", "case": label, "source_sha256": SOURCE_SHA256,
                      "production_unpack_build_install": "passed", "install_exporter_rebuild": "passed",
                      "apinames": host_identity, "exported_api_names": len(exports.splitlines()),
                      "apinames_sha256": hashlib.sha256(apinames.read_bytes()).hexdigest(),
                      "target_archive_objects": len(objects), "target_archive_identity": identities[0],
                      "target_archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                      "target_execution": "not_run", "gameplay": "unverified"}
            (case / "result.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps(result, sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
