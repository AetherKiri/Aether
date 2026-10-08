#!/usr/bin/env python3
"""Check real patched task configuration for Darwin iOS and Linux Android.

Xcode paths are fixtures for configuration tests only. No preflight, compiler,
SDK contents or gameplay is simulated as successful.
"""
import ast
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
PIN = "7bfab40c1174f622f644b24669afd5fb167fbb79"


def task_function(path, name, namespace, *, archs=None):
    tree = ast.parse(path.read_text())
    selected = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == name and
                    (archs is None or any(isinstance(decorator, ast.Call) and
                     any(keyword.arg == "archs" and keyword.value.value == archs for keyword in decorator.keywords)
                     for decorator in node.decorator_list)))
    selected.decorator_list = []
    exec(compile(ast.Module(body=[selected], type_ignores=[]), str(path), "exec"), namespace)
    return namespace[name]


def main():
    checkout = Path(sys.argv[1])
    assert subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip() == PIN
    with tempfile.TemporaryDirectory(prefix="renpy-darwin-build-") as temporary:
        root = Path(temporary)
        archive = subprocess.Popen([
            "git", "-C", str(checkout), "archive", "HEAD", "renpybuild", "tasks",
            "source/Python-3.12.8-Setup.stdlib", "tools/cmake_build_variables.cmake",
        ], stdout=subprocess.PIPE)
        assert archive.stdout is not None
        with tarfile.open(fileobj=archive.stdout, mode="r|*") as source:
            source.extractall(root, filter="data")
        assert archive.wait() == 0
        build_patch = REPO / "bridge/renpy_runtime/mobile_launcher/patches/native/0007-darwin-ios-build.patch"
        subprocess.run(["git", "apply", "--check", str(build_patch)], cwd=root, check=True)
        subprocess.run(["git", "apply", str(build_patch)], cwd=root, check=True)
        sys.path.insert(0, str(root))
        from renpybuild.context import Context
        import renpybuild.run as run

        def xcrun(arguments, **_kwargs):
            assert arguments[0] == "xcrun", arguments
            if arguments[1] == "--find":
                return "/fixture/Xcode/usr/bin/" + arguments[2]
            assert arguments[1] == "--sdk" and arguments[3] == "--show-sdk-path", arguments
            sdk = root / "local-sdk" / arguments[2]
            sdk.mkdir(parents=True, exist_ok=True)
            return str(sdk)

        with patch.object(run.sys, "platform", "darwin"), patch.object(run.subprocess, "check_output", xcrun), \
                patch.dict(run.os.environ, {"AETHERKIRI_RENPY_HOST_DEPS": "/fixture/openssl:/fixture/libffi"}), \
                patch.object(run.sysconfig, "get_config_var", lambda _name: "aarch64-apple-darwin24"):
            for architecture, target in (("arm64", "arm64-apple-ios13.0"), ("sim-arm64", "arm64-apple-ios13.0-simulator")):
                context = Context("ios", architecture, "3", root, SimpleNamespace())
                context.set_names("python", "build", "renpython")
                assert target in context.environ["CC"]
                assert "-isysroot" in context.environ["CC"]
                assert "-fuse-ld=lld" not in context.environ["CC"]
                assert "-stdlib=libc++" in context.environ["CXX"]
                assert "-lmockrt" not in context.environ["LDFLAGS"]
                assert "/fixture/openssl" not in context.environ["LDFLAGS"], "host libraries leaked into target linking"
                assert context.variables["lipo"] == "xcrun lipo"
                assert "-DCMAKE_POLICY_VERSION_MINIMUM=3.5" in context.variables["cmake_args"]
                host_generation = Context("ios", architecture, "3", root, SimpleNamespace())
                host_generation.set_names("host-python", "gen_static3", "librenpy")
                assert host_generation.install == root / "tmp" / ("install.ios-" + architecture)
                assert str(root / "local-sdk/macosx") in host_generation.environ["CC"]
                assert "/fixture/libffi/include" in host_generation.environ["CFLAGS"]
            host = Context("host", "host", "3", root, SimpleNamespace())
            host.set_names("host", "build_host", "hostpython3")
            assert "/fixture/openssl/lib" in host.environ["LDFLAGS"]
            rendered = host.expand((root / "source/Python-3.12.8-Setup.stdlib").read_text())
            assert "_scproxy -DPy_BUILD_CORE_BUILTIN _scproxy.c -framework SystemConfiguration" in rendered
            namespace = {"Context": Context, "sys": sys, "subprocess": run.subprocess}
            toolchain = task_function(root / "tasks/toolchain.py", "build", namespace,
                                      archs="sim-arm64,sim-x86_64")
            cross = Context("ios", "sim-arm64", "3", root, SimpleNamespace())
            cross.set_names("cross", "build", "toolchain")
            cross.run = lambda _command: None
            toolchain(cross)
            assert cross.path("{{ cross }}/sdk").is_symlink()
            assert cross.path("{{ cross }}/sdk").samefile(root / "local-sdk/iphonesimulator")
            shim_task = task_function(root / "tasks/toolchain.py", "mockrt", namespace)
            shim_context = Context("ios", "arm64", "3", root, SimpleNamespace())
            shim_context.set_names("arch", "mockrt", "toolchain")
            obsolete_shim = shim_context.path("{{ install }}/lib/libmockrt.a")
            obsolete_shim.parent.mkdir(parents=True, exist_ok=True)
            obsolete_shim.touch()
            def reject_shim_compile(command):
                raise AssertionError("native Xcode build attempted the Linux runtime shim: " + command)
            shim_context.run = reject_shim_compile
            shim_task(shim_context)
            assert not obsolete_shim.exists()
        with patch.object(run.sys, "platform", "linux"), \
                patch.object(run.sysconfig, "get_config_var", lambda _name: "x86_64-pc-linux-gnu"):
            context = Context("android", "arm64_v8a", "3", root, SimpleNamespace())
            context.set_names("python", "build", "renpython")
            assert "aarch64-linux-android21-clang" in context.environ["CC"]
            assert "linux-x86_64" in context.environ["CC"]
            assert not context.native_darwin
            assert "CMAKE_POLICY_VERSION_MINIMUM" not in context.variables["cmake_args"]
    print("Darwin iOS and Linux Android task configuration passed; no native build or gameplay performed")


if __name__ == "__main__":
    main()
