#!/usr/bin/env python3
"""Exercise patched upstream RunGroup using real host subprocesses.

These are compiler scheduling/error-boundary tests, not a native runtime build
or gameplay. No SDK or compilation prerequisite is mocked as successful.
"""
import ast
from concurrent.futures import ThreadPoolExecutor
import contextlib
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
PIN = "7bfab40c1174f622f644b24669afd5fb167fbb79"


def main():
    checkout = Path(sys.argv[1])
    assert subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip() == PIN
    with tempfile.TemporaryDirectory(prefix="renpy-build-parallelism-") as temporary:
        root = Path(temporary)
        run_file = root / "renpybuild/run.py"
        run_file.parent.mkdir()
        run_file.write_bytes(subprocess.check_output(["git", "-C", str(checkout), "show", "HEAD:renpybuild/run.py"]))
        build_patch = REPO / "bridge/renpy_runtime/mobile_launcher/patches/native/0009-bounded-build-parallelism.patch"
        subprocess.run(["git", "apply", "--check", str(build_patch)], cwd=root, check=True)
        subprocess.run(["git", "apply", str(build_patch)], cwd=root, check=True)
        tree = ast.parse(run_file.read_text())
        classes = [node for node in tree.body if isinstance(node, ast.ClassDef) and node.name in ("RunCommand", "RunGroup")]
        namespace = dict(os=os, shlex=shlex, subprocess=subprocess, sys=sys, ThreadPoolExecutor=ThreadPoolExecutor)
        exec(compile(ast.Module(body=classes, type_ignores=[]), str(run_file), "exec"), namespace)
        RunGroup = namespace["RunGroup"]

        def context(jobs=None):
            environment = dict(os.environ)
            environment.pop("RENPY_BUILD_JOBS", None)
            if jobs is not None:
                environment["RENPY_BUILD_JOBS"] = jobs
            return SimpleNamespace(cwd=root, environ=environment, expand=lambda command: command)

        def command(code):
            return shlex.join([sys.executable, "-c", code])

        state = root / "state.json"
        state.write_text(json.dumps(dict(running=0, peak=0, finished=0)))
        child = """
import fcntl,json,pathlib,time
state=pathlib.Path('state.json')
def update(delta):
    with state.open('r+') as stream:
        fcntl.flock(stream,fcntl.LOCK_EX)
        data=json.load(stream)
        data['running']+=delta
        data['peak']=max(data['peak'],data['running'])
        data['finished']+=int(delta<0)
        stream.seek(0)
        json.dump(data,stream)
        stream.truncate()
update(1)
time.sleep(0.08)
update(-1)
"""
        output = io.StringIO()
        with contextlib.redirect_stdout(output), RunGroup(context("2")) as group:
            for _ in range(8):
                group.run(command(child))
        data = json.loads(state.read_text())
        assert data == dict(running=0, peak=2, finished=8), data
        assert all(task.future.done() for task in group.tasks)
        with patch.object(os, "cpu_count", lambda: 3):
            with RunGroup(context()) as default_group:
                assert default_group.executor._max_workers == 3
        for invalid in ("0", "-1", "invalid", "1.5", ""):
            try:
                RunGroup(context(invalid))
            except ValueError as error:
                assert "positive integer" in str(error)
            else:
                raise AssertionError("invalid job limit accepted: " + repr(invalid))

        output = io.StringIO()
        try:
            with contextlib.redirect_stdout(output), RunGroup(context("2")) as failed:
                failed.run(command("import sys; print('actual child failure'); sys.exit(7)"))
                failed.run(command("print('actual child success')"))
        except SystemExit as error:
            assert error.code == 1
        else:
            raise AssertionError("failed compiler process was reported as success")
        assert "Process failed with 7" in output.getvalue(), output.getvalue()
        assert sorted(task.code for task in failed.tasks) == [0, 7]
        assert all(task.future.done() for task in failed.tasks)

        try:
            with RunGroup(context("1")) as missing:
                missing.run(shlex.quote(str(root / "nonexistent-compiler")))
        except FileNotFoundError:
            pass
        else:
            raise AssertionError("compiler spawn error was swallowed")
        assert missing.executor._shutdown

        started = root / "started"
        finished = root / "finished"
        unexpected = root / "unexpected"
        try:
            with RunGroup(context("1")) as interrupted:
                interrupted.run(command("import pathlib,time; pathlib.Path('started').touch(); time.sleep(0.2); pathlib.Path('finished').touch()"))
                deadline = time.monotonic() + 5
                while not started.exists() and time.monotonic() < deadline:
                    time.sleep(0.005)
                assert started.exists(), "real child did not start"
                interrupted.run(command("import pathlib; pathlib.Path('unexpected').touch()"))
                raise RuntimeError("actual build-body failure")
        except RuntimeError as error:
            assert str(error) == "actual build-body failure"
        assert finished.exists(), "running child was left behind after the build-body exception"
        assert not unexpected.exists(), "queued child executed after cancellation"
        assert all(task.future.done() for task in interrupted.tasks)
        assert interrupted.tasks[1].future.cancelled()
    print("Real subprocess concurrency, failures and cleanup passed; no native runtime build or gameplay performed")


if __name__ == "__main__":
    main()
