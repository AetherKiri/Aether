#!/usr/bin/env python3
"""Exercise optional-SDK task branches from patched pinned upstream sources.

This verifies task selection and payload rules; it does not compile or run Ren'Py.
"""
import ast
import contextlib
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile


REPO = Path(__file__).resolve().parents[1]
PATCH = REPO / "bridge/renpy_runtime/mobile_launcher/patches/native/0005-optional-cubism.patch"
PIN = "7bfab40c1174f622f644b24669afd5fb167fbb79"


def function(path, name, namespace):
    tree = ast.parse(path.read_text())
    selected = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == name)
    selected.decorator_list = []
    exec(compile(ast.Module(body=[selected], type_ignores=[]), str(path), "exec"), namespace)
    return namespace[name]


class Context:
    python = "3"
    platform = "android"

    def __init__(self, root):
        self.root = root
        self.renpy = root / "renpy"
        self.environ = {"CUBISM": "/unrelated/host/sdk"}
        self.variables = {}
        self.includes = []
        self.commands = []
        self.modules = []

    def path(self, text):
        values = {
            "install": self.root / "install",
            "pytmp": self.root / "pytmp",
            "source": self.root / "source",
            "distlib": self.root / "distlib",
            "pythonver": "python3.12",
            "pycver": "312",
            "runtime": self.root / "runtime",
        }
        for key, value in values.items():
            text = text.replace("{{ " + key + " }}", str(value))
        return Path(text)

    def expand(self, text):
        return str(self.path(text))

    def include(self, text):
        self.includes.append(self.path(text))

    def env(self, name, value):
        self.environ[name] = self.expand(value)

    def var(self, name, value):
        self.variables[name] = value

    def run(self, command):
        for name, value in self.variables.items():
            command = command.replace("{{ " + name + " }}", str(value))
        self.commands.append(command)
        if command.startswith("mkdir -p "):
            self.path(command[len("mkdir -p "):]).mkdir(parents=True, exist_ok=True)

    def run_group(self):
        return contextlib.nullcontext(self)

    def generate(self, _source, _destination, *, modules):
        self.modules = list(modules)

    def unlink(self, _path):
        pass

    def copy(self, _source, _destination):
        pass

    def rmtree(self, _path):
        pass

    def clean(self, path):
        self.path(path).mkdir(parents=True, exist_ok=True)

    def compile(self, path):
        # Emulate bytecode filenames so the actual packaging rule loop runs.
        for source in Path(path).glob("**/*.py"):
            destination = source.parent / "__pycache__" / (source.stem + ".cpython-312.pyc")
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(b"rule-test")


def write(root, name, text):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def main():
    checkout = Path(sys.argv[1])
    actual = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    assert actual == PIN, (actual, PIN)
    with tempfile.TemporaryDirectory(prefix="renpy-optional-sdk-") as temporary:
        root = Path(temporary)
        archive = subprocess.Popen([
            "git", "-C", str(checkout), "archive", "HEAD",
            "tasks/live2d.py", "tasks/librenpy.py", "tasks/pythonlib.py",
        ], stdout=subprocess.PIPE)
        assert archive.stdout is not None
        with tarfile.open(fileobj=archive.stdout, mode="r|*") as source:
            source.extractall(root, filter="data")
        assert archive.wait() == 0
        subprocess.run(["git", "apply", "--check", str(PATCH)], cwd=root, check=True)
        subprocess.run(["git", "apply", str(PATCH)], cwd=root, check=True)
        namespace = {"Context": Context}
        annotate = function(root / "tasks/live2d.py", "annotate", namespace)
        build = function(root / "tasks/librenpy.py", "build", namespace)
        package = function(root / "tasks/pythonlib.py", "python3", {
            "Context": Context, "PY3_MODULES": "", "re": re,
            "shutil": __import__("shutil"),
        })
        write(root, "renpy/src/Setup", "base base.c\nrenpy.gl2.live2dmodel live2dmodel.c live2dcsm.c\n")
        write(root, "extensions/Setup", "extension extension.c\n")
        write(root, "pytmp/pyjnius/Setup", "jnius jnius.c\n")
        write(root, "source/brotli/Setup", "_brotli _brotli.c\n")
        context = Context(root)
        annotate(context)
        assert "CUBISM" not in context.environ and not context.includes
        build(context)
        assert context.modules == ["base", "extension", "jnius", "_brotli"], context.modules
        assert not any("live2dmodel" in command or "live2dcsm" in command for command in context.commands)
        header = write(root, "install/cubism/Core/include/Live2DCubismCore.h", "/* test SDK */\n")
        context = Context(root)
        annotate(context)
        assert context.environ["CUBISM"] == str(header.parents[2])
        assert context.includes == [header.parent]
        build(context)
        assert "renpy.gl2.live2dmodel" in context.modules
        assert any("live2dmodel" in command for command in context.commands)
        assert any("live2dcsm" in command for command in context.commands)
        for present in (False, True):
            case = root / ("steam-present" if present else "steam-absent")
            write(case, "distlib/python3.12/certifi/empty", "")
            write(case, "runtime/site3.py", "# test sitecustomize\n")
            if present:
                write(case, "pytmp/steam/steamapi.py", "# generated by SDK task\n")
            package(Context(case))
            assert (case / "distlib/python3.12/steamapi.pyc").exists() == present
    print("Pinned optional Cubism/Steam task branches passed; no native build or gameplay performed")


if __name__ == "__main__":
    main()
