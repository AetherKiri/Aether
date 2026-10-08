#!/usr/bin/env python3
"""Exercise pinned CPython patch tasks and genuine external libffi builds.

Linux results are host compilation/execution only. On Darwin, additional
device and Simulator cases configure CPython and link using the selected
real Xcode SDKs. Target executables are not installed or run as gameplay.
"""
import argparse
import ast
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[1]
PIN = "7bfab40c1174f622f644b24669afd5fb167fbb79"
PATCHES = REPO / "bridge/renpy_runtime/mobile_launcher/patches/native"
PYTHON_VERSION = "3.12.8"
FFI_VERSION = "3.4.5"
API_SOURCE = r"""
#include <ffi.h>
#include <stdio.h>
static int add_three(int value) { return value + 3; }
static void callback(ffi_cif *cif, void *result, void **arguments, void *data) {
    (void)cif;
    *(int *)result = *(int *)arguments[0] + *(int *)data;
}
int main(void) {
    ffi_cif cif, variadic;
    ffi_type *types[] = { &ffi_type_sint };
    int value = 7, increment = 5;
    void *arguments[] = { &value }, *code = NULL;
    ffi_arg result = 0;
    if (ffi_prep_cif(&cif, FFI_DEFAULT_ABI, 1, &ffi_type_sint, types) != FFI_OK) return 1;
    if (ffi_prep_cif_var(&variadic, FFI_DEFAULT_ABI, 1, 1, &ffi_type_sint, types) != FFI_OK) return 2;
    ffi_call(&cif, FFI_FN(add_three), &result, arguments);
    if ((int)result != 10) return 3;
    ffi_closure *closure = ffi_closure_alloc(sizeof(*closure), &code);
    if (!closure || !code) return 4;
    if (ffi_prep_closure_loc(closure, &cif, callback, &increment, code) != FFI_OK) return 5;
    int actual = ((int (*)(int))code)(value);
    ffi_closure_free(closure);
    if (actual != 12) return 6;
    puts("Genuine libffi call and executable closure returned 10 and 12");
    return 0;
}
"""


class BeforeMake(Exception):
    """Only capture task generation; genuine builds run separately below."""


def run(command, *, cwd, env=None, log):
    result = subprocess.run(command, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text("Command: " + shlex.join(map(str, command)) + "\n" + result.stdout)
    if result.returncode:
        # Only expose this new public-source command's tool errors. Do not
        # publish config.log's environment/cache dump or old build logs.
        for config_log in sorted(Path(cwd).rglob("config.log"))[:6]:
            errors = [line for line in config_log.read_text(errors="replace").splitlines()
                      if re.match(r"^(?:xcrun: error:|make(?:\[\d+\])?: |[^='\"\s]+:\d+: \*\*\*)", line)]
            if errors:
                print(json.dumps({"new_config_tool_errors": errors[-15:]}), flush=True)
        if sys.platform == "darwin":
            def tool_probe(command, environment, record):
                try:
                    probe = subprocess.run(command, cwd=cwd, env=environment,
                        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
                    record.update(status=probe.returncode, result=probe.stdout.strip())
                except (OSError, subprocess.TimeoutExpired) as error:
                    record.update(diagnostic_error=type(error).__name__)
                print(json.dumps(record), flush=True)
            tool_probe(["xcrun", "--find", "make"], env, {"make_probe": "xcrun-selected"})
            sdk_setting = (env or os.environ).get("SDKROOT")
            for label, sdk_value in (("original", sdk_setting),
                                     ("resolved", str(Path(sdk_setting).resolve()) if sdk_setting else None),
                                     ("unset", None)):
                diagnostic_environment = dict(env or os.environ)
                diagnostic_environment.pop("SDKROOT", None)
                if sdk_value:
                    diagnostic_environment["SDKROOT"] = sdk_value
                tool_probe(["make", "--version"], diagnostic_environment,
                           {"make_probe": label, "sdkroot": sdk_value})
        raise RuntimeError(f"Command failed ({result.returncode}); {log}\n{result.stdout[-7000:]}")
    return result.stdout


def extract(path, destination):
    with tarfile.open(path) as source:
        source.extractall(destination, filter="data")


def task_namespace(path, Context):
    selected = [node for node in ast.parse(path.read_text()).body
                if isinstance(node, ast.FunctionDef) and node.name in
                ("common", "common_post", "patch_posix", "patch_ios", "build_ios")]
    assert len(selected) == 5
    for node in selected:
        node.decorator_list = []
    namespace = {"Context": Context, "version": PYTHON_VERSION}
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(path), "exec"), namespace)
    return namespace


def make_variables(path):
    values = {}
    for line in path.read_text().splitlines():
        match = re.match(r"([A-Za-z0-9_]+)\s*=\s*(.*)", line)
        if match:
            values[match.group(1)] = match.group(2)
    def expand(value):
        for _ in range(20):
            # GNU make expands an unset override such as CFLAGS to empty.
            expanded = re.sub(r"\$\((\w+)\)", lambda match: values.get(match.group(1), ""), value)
            if expanded == value:
                assert "$" not in value, f"Unexpanded compiler flags: {value}"
                return value
            value = expanded
        raise AssertionError("Recursive Makefile flags")
    return values, expand


def capture_ios_task(namespace, Context, root, shared, architecture, source, sdk):
    context = Context("ios", architecture, "3", root, SimpleNamespace())
    context.set_names("python", "build_ios", "python3")
    if sdk:
        cross = context.path("{{ cross }}/sdk")
        cross.parent.mkdir(parents=True, exist_ok=True)
        cross.symlink_to(sdk, target_is_directory=True)
        assert cross.resolve() == sdk.resolve(), "Only a genuine selected Xcode SDK may be used"
    context.var("source", shared / "source")
    context.cwd = source.parent
    captured = {}
    base_sdkroot = context.environ.get("SDKROOT")
    def capture(command, **kwargs):
        expanded = context.expand(command)
        if expanded.strip().startswith("./configure"):
            assert not captured, "Unexpected second configure"
            captured.update(command=shlex.split(expanded), environment=dict(context.environ),
                            base_context_sdkroot=base_sdkroot)
            # Execute configure below before running any post-configure task.
            raise BeforeMake()
        raise AssertionError("Unexpected pre-configure command: " + expanded)
    context.run = capture
    try:
        namespace["build_ios"](context)
    except BeforeMake:
        pass
    assert captured and context.cwd == source
    environment = captured["environment"]
    assert environment["SDKROOT"] == str(context.path("{{ cross }}/sdk").resolve())
    assert environment["LIBFFI_CFLAGS"] == "-I" + str(context.install / "include")
    assert environment["LIBFFI_LIBS"] == "-L" + str(context.install / "lib") + " -lffi"
    assert "ac_cv_func_ffi_" not in (source / "config.site").read_text()
    return context, captured


def ffi_and_python_case(label, *, root, shared, namespace, Context, compiler,
                        architecture, sdk, target, cython, jobs, evidence):
    case = root / label
    case.mkdir()
    extract(shared / f"source/Python-{PYTHON_VERSION}.tar.xz", case)
    python_source = case / f"Python-{PYTHON_VERSION}"
    patch_context = Context("ios", architecture, "3", case, SimpleNamespace())
    patch_context.set_names("python", "patch_posix", "python3")
    patch_context.cwd = case
    patch_context.var("patches", shared / "patches")
    patch_context.environ["PATH"] = str(cython.parent) + os.pathsep + patch_context.environ["PATH"]
    # These are the complete real task bodies, with real Context.patch/run.
    namespace["patch_posix"](patch_context)
    patch_context.cwd = case
    namespace["patch_ios"](patch_context)
    generated = (python_source / "Modules/_scproxy.c").read_text()
    assert "Generated by Cython 3.2.4" in generated
    assert "HAVE_SYSTEM" in (python_source / "Modules/posixmodule.c").read_text()

    context, captured = capture_ios_task(namespace, Context, case, shared, architecture, python_source, sdk)
    cross = context.path("{{ cross }}/sdk")
    prefix = context.install
    host_python = context.path("{{ host }}/bin/python3")
    host_python.parent.mkdir(parents=True, exist_ok=True)
    host_python.symlink_to(Path(sys.executable).resolve())

    extract(shared / f"source/libffi-{FFI_VERSION}.tar.gz", case)
    ffi_source = case / f"libffi-{FFI_VERSION}"
    patch_context.cwd = ffi_source
    patch_context.patchdir("libffi")
    initial_ffi_configs = {path: path.read_bytes() for path in ffi_source.rglob("fficonfig.h")}
    if target:
        # Preserve the production Context's compiler, preprocessor, target,
        # SDK alias, tools and complete compile/link flags, including ccache.
        environment = dict(captured["environment"])
        words = shlex.split(environment["CC"])
        assert target in words and str(cross) in words, words
        assert Path(environment["SDKROOT"]).resolve() == sdk.resolve()
    else:
        words = [str(compiler)]
        if sdk:
            words += ["-isysroot", str(sdk)]
        environment = dict(os.environ, CC=shlex.join(words), CFLAGS="", CPPFLAGS="", LDFLAGS="", LIBS="")
    if target:
        # libffi runs as an arch task before Python sets its own SDKROOT,
        # CONFIG_SITE, PYTHON_FOR_BUILD and external-libffi variables.
        ffi_context = Context("ios", architecture, "3", case, SimpleNamespace())
        ffi_context.set_names("arch", "build", "libffi")
        assert ffi_context.install == prefix
        ffi_environment = dict(ffi_context.environ)
        for key in ("CC", "CPP", "CXX", "AR", "RANLIB", "NM", "CFLAGS", "CPPFLAGS", "LDFLAGS"):
            assert ffi_environment[key] == environment[key], key
    else:
        ffi_environment = dict(environment)
    print(json.dumps({"case": label, "ffi_environment_source": "libffi task Context" if target else "host isolation",
                      "base_context_sdkroot": captured["base_context_sdkroot"],
                      "ffi_sdkroot": ffi_environment.get("SDKROOT")}), flush=True)
    ffi_command = ["./configure", "--disable-shared", "--enable-portable-binary", "--prefix=" + str(prefix)]
    if target:
        # Use the actual production libffi tuple; do not silently fix it in a test.
        ffi_command += shlex.split(context.expand("{{ ffi_cross_config }}"))
    run(ffi_command, cwd=ffi_source, env=ffi_environment, log=evidence / f"{label}-ffi-configure.log")
    run(["make", "-j", str(jobs)], cwd=ffi_source, env=ffi_environment, log=evidence / f"{label}-ffi-build.log")
    run(["make", "install"], cwd=ffi_source, env=ffi_environment, log=evidence / f"{label}-ffi-install.log")
    # The official archive also ships a pre-generated MSVC ARM64 header. Only
    # a header created/changed by this genuine configure belongs to this case.
    ffi_configs = [path for path in ffi_source.rglob("fficonfig.h")
                   if initial_ffi_configs.get(path) != path.read_bytes()]
    assert len(ffi_configs) == 1, f"Expected one genuinely generated libffi configuration: {ffi_configs}"
    trampoline_table = bool(re.search(r"^#define FFI_EXEC_TRAMPOLINE_TABLE 1$", ffi_configs[0].read_text(), re.M))
    if target:
        assert trampoline_table, "iOS ARM64 external libffi must use Apple's static executable trampoline table"
    static_ffi = prefix / "lib/libffi.a"
    assert static_ffi.is_file() and not (prefix / "lib/libffi.dylib").exists()

    environment.update(LIBFFI_CFLAGS=captured["environment"]["LIBFFI_CFLAGS"],
                       LIBFFI_LIBS=captured["environment"]["LIBFFI_LIBS"],
                       CONFIG_SITE=str(python_source / "config.site"))
    if not target:
        environment.update(CPPFLAGS="-I" + str(prefix / "include"),
                           LDFLAGS="-L" + str(prefix / "lib"),
                           SDKROOT=str(sdk) if sdk else "")
    # No function cache is supplied. CPython's three genuine ffi probes are
    # compile checks; the API executable and link map below establish linking.
    assert not any(key.startswith("ac_cv_func_ffi_") for key in environment)
    configure = captured["command"] if target else ["./configure", "--prefix=" + str(prefix), "--with-ensurepip=no"]
    run(configure, cwd=python_source, env=environment, log=evidence / f"{label}-python-configure.log")
    # Production runs configure first, then replaces BOTH Setup files. Repeat
    # the genuine common_post generation in that order, stopping before make.
    # Its static extensions use global compiler flags plus this Setup line,
    # rather than assuming MODULE__CTYPES_CFLAGS controls the static object.
    static_commands = []
    def execute_post_configure(command, **kwargs):
        expanded = context.expand(command)
        if expanded.strip().startswith("nice make"):
            raise BeforeMake()
        static_commands.append(shlex.split(expanded))
        # Use the genuine Context implementation for the production task's
        # makesetup and config.c move, rather than adding a test-only rule.
        return Context.run(context, command, **kwargs)
    context.run = execute_post_configure
    try:
        namespace["common_post"](context)
    except BeforeMake:
        pass
    assert len(static_commands) == 2 and "Modules/makesetup" in static_commands[0]
    assert (python_source / "Modules/Setup").read_bytes() == (python_source / "Modules/Setup.stdlib").read_bytes()
    registry = (python_source / "Modules/config.c").read_text()
    assert re.search(r'\{\s*"_ctypes"\s*,\s*PyInit__ctypes\s*\}', registry), \
        "The real generated static builtin registry is missing _ctypes"
    for name in ("Setup", "Setup.stdlib"):
        line = next(line for line in (python_source / "Modules" / name).read_text().splitlines()
                    if line.startswith("_ctypes "))
        assert "_ctypes/malloc_closure.c" in line and "-lffi" in line
        assert "USING_APPLE_OS_LIBFFI" not in line
    # Execute the genuine makesetup rule after the production templates have
    # replaced configure's Setup.stdlib, without building the interpreter.
    run(["make", "Makefile"], cwd=python_source, env=environment,
        log=evidence / f"{label}-static-makefile.log")
    variables, expand = make_variables(python_source / "Makefile")
    assert variables["MODULE__CTYPES_STATE"] == "yes", variables["MODULE__CTYPES_STATE"]
    cflags = shlex.split(expand(variables["MODULE__CTYPES_CFLAGS"]))
    ldflags = shlex.split(expand(variables["MODULE__CTYPES_LDFLAGS"]))
    assert "-I" + str(prefix / "include") in cflags, cflags
    assert "-L" + str(prefix / "lib") in ldflags and "-lffi" in ldflags, ldflags
    assert not any("USING_APPLE_OS_LIBFFI" in flag for flag in cflags), cflags
    config = (python_source / "pyconfig.h").read_text()
    for feature in ("FFI_PREP_CIF_VAR", "FFI_PREP_CLOSURE_LOC", "FFI_CLOSURE_ALLOC"):
        assert re.search(r"^#define HAVE_" + feature + r" 1$", config, re.M), feature
    api = case / "ffi-api.c"
    api.write_text(API_SOURCE)
    executable = case / "ffi-api"
    link_map = evidence / f"{label}-ffi-link.map"
    map_flag = "-Wl,-map," if sys.platform == "darwin" else "-Wl,-Map,"
    compile_flags = shlex.split(environment.get("CFLAGS", "")) + shlex.split(environment.get("CPPFLAGS", ""))
    link_flags = shlex.split(environment.get("LDFLAGS", "")) + shlex.split(environment.get("LIBS", ""))
    run([*words, *compile_flags, "-Wall", "-Wextra", "-Werror", *cflags, str(api), *link_flags, *ldflags,
         map_flag + str(link_map), "-o", str(executable)], cwd=case,
        env=environment, log=evidence / f"{label}-ffi-api-link.log")
    assert str(static_ffi) in link_map.read_text(), "API link did not consume the freshly built external libffi.a"
    closure_object = case / "malloc_closure.o"
    # Linux configure normally omits malloc_closure.c. This particular object
    # uses the actual iOS static Setup's definitions, including the symbol
    # wrappers that prevent aliases from recursively calling themselves.
    static_line = next(line for line in (python_source / "Modules/Setup").read_text().splitlines()
                       if line.startswith("_ctypes "))
    static_definitions = [flag for flag in shlex.split(static_line) if flag.startswith("-D")]
    assert "_ctypes/malloc_closure.c" in static_line and "-lffi" in static_line
    assert not any("USING_APPLE_OS_LIBFFI" in flag for flag in static_definitions)
    global_cflags = shlex.split(expand(variables["PY_BUILTIN_MODULE_CFLAGS"]))
    assert "-I" + str(prefix / "include") in global_cflags, global_cflags
    dry_run = run(["make", "-n", "Modules/_ctypes/malloc_closure.o"], cwd=python_source,
                  env=environment, log=evidence / f"{label}-ctypes-make-command.log")
    commands = [shlex.split(line) for line in dry_run.splitlines()
                if "malloc_closure.c" in line and " -c " in line]
    assert len(commands) == 1, dry_run
    closure_command = commands[0]
    assert all(flag in closure_command for flag in static_definitions), closure_command
    assert "-I" + str(prefix / "include") in closure_command, closure_command
    assert "USING_APPLE_OS_LIBFFI" not in " ".join(closure_command)
    closure_command[closure_command.index("-o") + 1] = str(closure_object)
    # Compile the upstream object with its real production warning policy.
    # A blanket extra -Werror rejects CPython's intentionally unreachable
    # legacy fallback when external ffi_closure_alloc is available.
    headers = run([*closure_command, "-H"],
        cwd=python_source, env=environment, log=evidence / f"{label}-ctypes-closure-compile.log")
    assert str(prefix / "include/ffi.h") in headers, "Actual static closure object did not include the external libffi header"
    wrapped_api = case / "ctypes-ffi-api.c"
    wrapped_api.write_text("#include <stddef.h>\n"
        "extern void *Py_ffi_closure_alloc(size_t, void **);\n"
        "extern void Py_ffi_closure_free(void *);\n" + API_SOURCE.replace(
            "ffi_closure_alloc(sizeof(*closure), &code)", "Py_ffi_closure_alloc(sizeof(*closure), &code)").replace(
            "ffi_closure_free(closure)", "Py_ffi_closure_free(closure)"))
    wrapped_executable = case / "ctypes-ffi-api"
    wrapped_map = evidence / f"{label}-ctypes-ffi-link.map"
    run([*words, *compile_flags, "-Wall", "-Wextra", "-Werror", *cflags, str(wrapped_api), str(closure_object), *link_flags, *ldflags,
         map_flag + str(wrapped_map), "-o", str(wrapped_executable)], cwd=case,
        env=environment, log=evidence / f"{label}-ctypes-ffi-api-link.log")
    assert str(static_ffi) in wrapped_map.read_text(), "CPython closure wrapper did not link to the external libffi.a"
    if target:
        assert executable.read_bytes()[:4] == bytes.fromhex("cffaedfe")
        assert closure_object.read_bytes()[:4] == bytes.fromhex("cffaedfe")
        assert wrapped_executable.read_bytes()[:4] == bytes.fromhex("cffaedfe")
        output = run(["xcrun", "nm", "-u", str(executable)], cwd=case,
                     log=evidence / f"{label}-ffi-unresolved.txt")
        assert not re.search(r"\b_ffi_\w+", output), output
    else:
        run([str(executable)], cwd=case, env=environment, log=evidence / f"{label}-ffi-api-run.log")
        run([str(wrapped_executable)], cwd=case, env=environment, log=evidence / f"{label}-ctypes-ffi-api-run.log")
    compiler_version = subprocess.check_output([str(compiler), "--version"], text=True).splitlines()[0]
    record = {"case": label, "compiler": words, "compiler_version": compiler_version,
              "build_source_pin": PIN, "python_version": PYTHON_VERSION, "libffi_version": FFI_VERSION,
              "sdk": str(sdk) if sdk else None,
              "python_sdkroot": environment.get("SDKROOT"),
              "ffi_sdkroot": ffi_environment.get("SDKROOT"),
              "target_context_toolchain": "production" if target else "host isolation",
              "static_setup_commands": static_commands,
              "ctypes_static_registry": "passed",
              "configure_ffi_headers": "passed", "ffi_api_link": "passed",
              "closure_object": "passed", "ctypes_closure_link": "passed",
              "ffi_api_execution": "not_run" if target else "passed",
              "ctypes_closure_execution": "not_run" if target else "passed",
              "ffi_trampoline_table": trampoline_table,
              "libffi_sha256": hashlib.sha256(static_ffi.read_bytes()).hexdigest(),
              "ctypes_compile_flags": cflags, "ctypes_link_flags": ldflags,
              "static_global_compile_flags": global_cflags, "static_definitions": static_definitions,
              "actual_static_closure_command": closure_command,
              "actual_static_closure_header": str(prefix / "include/ffi.h"),
              "gameplay": "unverified"}
    (evidence / f"{label}-result.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, sort_keys=True), flush=True)
    print(f"{label}: genuine patch/autoreconf/Cython, libffi build, CPython configure, closure object and API link PASS; "
          + ("target API execution not run" if target else "host ffi_call/closure execution PASS"), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_source", type=Path)
    parser.add_argument("--cython", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    assert args.jobs > 0
    assert sys.version_info[:2] == (3, 12), "The genuine CPython 3.12 configure requires a matching build Python"
    assert subprocess.check_output(["git", "-C", str(args.build_source), "rev-parse", "HEAD"], text=True).strip() == PIN
    cython = args.cython or Path(shutil.which("cython") or "")
    assert cython.is_file() and os.access(cython, os.X_OK), "Genuine Cython 3.2.4 is required"
    cython_version = subprocess.check_output([str(cython), "--version"], text=True, stderr=subprocess.STDOUT)
    assert "Cython version 3.2.4" in cython_version, cython_version
    evidence = (args.output_dir or Path(tempfile.mkdtemp(prefix="renpy-ios-libffi-evidence-"))).resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    print("Evidence:", evidence, flush=True)
    with tempfile.TemporaryDirectory(prefix="renpy-ios-libffi-") as temporary:
        root = Path(temporary)
        shared = root / "build-source"
        shared.mkdir()
        archive = subprocess.Popen(["git", "-C", str(args.build_source), "archive", "HEAD", "renpybuild", "tasks",
                                    "patches", "source/Python-3.12.8-Setup.stdlib", "source/Python-3.12.8.tar.xz",
                                    "source/libffi-3.4.5.tar.gz", "tools/cmake_build_variables.cmake"], stdout=subprocess.PIPE)
        assert archive.stdout is not None
        with tarfile.open(fileobj=archive.stdout, mode="r|*") as source:
            source.extractall(shared, filter="data")
        assert archive.wait() == 0
        run(["git", "apply", "--include=tasks/metalangle.py", str(PATCHES / "0006-ios-offscreen-renderer.patch")],
            cwd=shared, log=evidence / "0006-prerequisite.log")
        run(["git", "apply", str(PATCHES / "0007-darwin-ios-build.patch")],
            cwd=shared, log=evidence / "0007-production-patch.log")
        sys.path.insert(0, str(shared))
        from renpybuild.context import Context
        namespace = task_namespace(shared / "tasks/python3.py", Context)
        compiler = Path(subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()) if sys.platform == "darwin" \
            else Path(shutil.which("cc") or "")
        assert compiler.is_file(), "A genuine host C compiler is required"
        host_sdk = Path(subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()) \
            if sys.platform == "darwin" else None
        ffi_and_python_case("host", root=root, shared=shared, namespace=namespace, Context=Context,
                            compiler=compiler, architecture="arm64", sdk=host_sdk, target=None,
                            cython=cython, jobs=args.jobs, evidence=evidence)
        if sys.platform == "darwin":
            for architecture, sdk_name, target in (("arm64", "iphoneos", "arm64-apple-ios13.0"),
                                                   ("sim-arm64", "iphonesimulator", "arm64-apple-ios13.0-simulator")):
                sdk = Path(subprocess.check_output(["xcrun", "--sdk", sdk_name, "--show-sdk-path"], text=True).strip())
                assert sdk.is_dir(), sdk
                ffi_and_python_case(sdk_name, root=root, shared=shared, namespace=namespace, Context=Context,
                                    compiler=compiler, architecture=architecture, sdk=sdk, target=target,
                                    cython=cython, jobs=args.jobs, evidence=evidence)
        else:
            print("Linux host checks passed; iOS device/Simulator SDK compilation and linking NOT RUN", flush=True)
        print("No iOS executable was installed or launched; no Ren'Py/GL/device gameplay was tested", flush=True)


if __name__ == "__main__":
    main()
