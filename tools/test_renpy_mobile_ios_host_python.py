#!/usr/bin/env python3
"""Execute the iOS build's host Python tools and pure-package installation.

This uses real host CPython, pip, published packages and the patched task body.
It does not compile an iOS object, launch a target interpreter or run gameplay.
"""
import argparse
import ast
import importlib.metadata
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
PIN = "7bfab40c1174f622f644b24669afd5fb167fbb79"
RENPY_PIN = "39895c1e017f0b36ffea2447d97eccd69d76ee1c"


def capture(command, *, cwd, env=None):
    result = subprocess.run(list(map(str, command)), cwd=cwd, env=env,
                            text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=600)
    if result.returncode:
        raise RuntimeError(f"Host command failed ({result.returncode}):\n{result.stdout[-6000:]}")
    return result.stdout


def task_functions(path, context_type):
    functions = [node for node in ast.parse(path.read_text()).body
                 if isinstance(node, ast.FunctionDef) and node.name in ("annotate", "pip")]
    assert len(functions) == 2
    for node in functions:
        node.decorator_list = []
    namespace = {"Context": context_type}
    exec(compile(ast.Module(body=functions, type_ignores=[]), str(path), "exec"), namespace)
    return namespace


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_source", type=Path)
    parser.add_argument("--renpy-src", required=True, type=Path)
    args = parser.parse_args()
    if sys.version_info[:2] != (3, 12):
        raise SystemExit("The pinned build's host-tool regression requires genuine CPython 3.12.")
    assert capture(["git", "rev-parse", "HEAD"], cwd=args.build_source).strip() == PIN
    assert capture(["git", "rev-parse", "HEAD"], cwd=args.renpy_src).strip() == RENPY_PIN
    patches = sorted((REPO / "bridge/renpy_runtime/mobile_launcher/patches/native").glob(
        "[0-9][0-9][0-9][0-9]-*.patch"))
    assert any(path.name.startswith("0010-") for path in patches)
    with tempfile.TemporaryDirectory(prefix="renpy-real-host-python-") as directory:
        root = Path(directory) / "renpy-build"
        # Limit the copy to the materialized pinned HEAD. Local shared clones
        # can traverse unrelated missing objects in a promisor repository.
        capture(["git", "clone", "--no-local", "--depth=1", "--single-branch", "--quiet", "--no-checkout",
                 args.build_source.resolve(), root], cwd=REPO)
        capture(["git", "checkout", "--quiet", "--detach", PIN], cwd=root)
        capture([sys.executable, REPO / "tools/apply_renpy_mobile_patch_series.py",
                 "--checkout", root, "--pin", PIN, *patches], cwd=REPO)
        sys.path.insert(0, str(root))
        from renpybuild.context import Context
        from renpybuild.ios_host_python import prepare_ios_host_python

        tasks = task_functions(root / "tasks/python3.py", Context)
        # These are genuine production Context paths/commands. No target SDK
        # or compiler is invoked by this host-tool/package-only regression.
        context = Context("ios", "arm64", "3", root, SimpleNamespace())
        context.set_names("python", "pip", "python3")
        context.var("host", Path(sys.base_prefix))
        tasks["annotate"](context)
        poison = root / "foreign-stdlib"
        poison.mkdir()
        (poison / "subprocess.py").write_text("raise RuntimeError('foreign target stdlib loaded')\n")
        context.env("PYTHONHOME", str(poison))
        context.env("PYTHONPATH", str(poison))
        prepare_ios_host_python(context)
        tasks["pip"](context)

        wrapper = context.path("{{ install }}/bin/hostpython3")
        assert wrapper.read_bytes().startswith(b"#!/bin/sh\n"), "Host Mach-O/ELF was copied instead of a build-only wrapper"
        probe = root / "host-generation-probe.py"
        probe.write_text("""import json, pathlib, subprocess, sys
sys.path.insert(0, sys.argv[1])
import setuplib, setuptools, _posixsubprocess
assert sys.flags.isolated
subprocess.run([sys.executable, '-I', '-c', 'import subprocess, _posixsubprocess'], check=True)
print(json.dumps({'isolated': bool(sys.flags.isolated), 'stdlib': subprocess.__file__,
                  'setuptools': setuptools.__version__, 'prefix': sys.prefix}))
""")
        tools = json.loads(capture([wrapper, probe, args.renpy_src.resolve() / "scripts"],
                                  cwd=root, env=context.environ).strip().splitlines()[-1])
        assert tools["setuptools"] == "74.1.2"
        assert not Path(tools["stdlib"]).is_relative_to(context.install)
        assert Path(tools["prefix"]).is_relative_to(context.install)
        site = context.path("{{ install }}/lib/{{ pythonver }}/site-packages")
        versions = {dist.metadata["Name"].lower().replace("_", "-"): dist.version
                    for dist in importlib.metadata.distributions(path=[str(site)])}
        expected = {"future": "1.0.0", "six": "1.16.0", "rsa": "4.9", "pyasn1": "0.6.1",
                    "ecdsa": "0.19.0", "urllib3": "2.7.0", "charset-normalizer": "3.3.2",
                    "chardet": "5.2.0", "idna": "3.8", "requests": "2.33.0",
                    "pefile": "2022.5.30", "websockets": "12.0",
                    "setuptools": "74.1.2", "pysocks": "1.7.1"}
        assert all(versions.get(name) == version for name, version in expected.items()), versions
        assert "certifi" in versions and (site / "certifi/cacert.pem").is_file()
        assert (site / "websockets/__init__.py").is_file()
        assert (site / "charset_normalizer/__init__.py").is_file()
        assert (site / "pefile.py").is_file()
        assert not any(path.is_file() and path.suffix.lower() in (".so", ".dylib", ".pyd")
                       for path in site.rglob("*")), "A native extension entered target site-packages"
        runtime = root / "runtime-compilation-probe.py"
        runtime.write_text("value = 'real CPython bytecode'\n")
        context.compile(runtime)
        assert runtime.with_suffix(".pyc").is_file()
        result = {"status": "passed", "host_python": sys.version.split()[0],
                  "isolated_stdlib_and_subprocess": "passed", "pinned_setuplib_import": "passed",
                  "actual_context_compileall": "passed", "target_package_versions": versions,
                  "target_native_extensions": "absent", "certifi_certificate": "present",
                  "target_compilation": "not_run", "gameplay": "unverified"}
        print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
