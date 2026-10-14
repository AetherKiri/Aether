#!/usr/bin/env python3
"""Fetch pinned upstream inputs and prepare the native runtime used by Aether builds."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request
import zipfile

REPO = Path(__file__).resolve().parents[1]
VERSION = "8.5.3"
INPUTS = {
    "sdk.zip": ("https://www.renpy.org/dl/8.5.3/renpy-8.5.3-sdk.zip", "ff57648f9c04f27e381c48af6d8e3ee3cdec296bed4d3831f47f09b0a71b505e"),
    "sdkarm.tar.bz2": ("https://www.renpy.org/dl/8.5.3/renpy-8.5.3-sdkarm.tar.bz2", "0579782517f203ba3535dcc2dab54e34bfc318f2f2a7510a5130b6f809f901f6"),
    "renios.zip": ("https://www.renpy.org/dl/8.5.3/renpy-8.5.3-renios.zip", "c4fae153e8276ed0faed5e84ea3e0b7c4bf337f0e3208e9130c6a41748a83b2b"),
    "rapt.zip": ("https://www.renpy.org/dl/8.5.3/renpy-8.5.3-rapt.zip", "8a12be34a2f5238d125ff6dd76a56772fd8e44838af864f81bca82c1059b00e6"),
    "python.tgz": ("https://www.python.org/ftp/python/3.12.8/Python-3.12.8.tgz", "5978435c479a376648cb02854df3b892ace9ed7d32b1fead652712bee9d03a45"),
    "greenlet.tar.gz": ("https://files.pythonhosted.org/packages/3e/6e/0091f175ccd02b02bc8811bbcbcc6ac2e980be116e3b2f7a736ca322bf84/greenlet-3.5.6.tar.gz", "8e67c43bdfc88d5fee6db0d3e40175b362fc95fb85f0412d233b9b203c53a575"),
}


def digest(file):
    with file.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fetch(cache, name, url=None, checksum=None):
    if url is None:
        url, checksum = INPUTS[name]
    target = cache / name
    if target.exists() and digest(target) == checksum:
        return target
    temporary = target.with_suffix(target.suffix + ".part")
    with urllib.request.urlopen(url, timeout=60) as source, temporary.open("wb") as output:
        shutil.copyfileobj(source, output)
    if digest(temporary) != checksum:
        temporary.unlink()
        raise RuntimeError("Upstream checksum mismatch: " + name)
    temporary.replace(target)
    return target


def tar_extract(archive, destination):
    with tarfile.open(archive) as stream:
        stream.extractall(destination, filter="data")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("platform", choices=("macos", "linux", "ios", "ios-simulator", "android"))
    parser.add_argument("--arch", choices=("arm64", "x86_64"), default=platform.machine().replace("aarch64", "arm64"))
    parser.add_argument("--cache", type=Path, default=REPO / ".devtools/renpy/8.5.3")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--ndk", type=Path)
    args = parser.parse_args()
    cache = args.cache.resolve(); cache.mkdir(parents=True, exist_ok=True)
    fingerprint = hashlib.sha256()
    inputs = [*REPO.glob("tools/*renpy*.py"), *REPO.glob("bridge/renpy_runtime/ios_sdl_adapter.mm"),
              *REPO.glob("bridge/renpy_runtime/android/**/*.cpp"), *REPO.glob("bridge/renpy_runtime/android/**/*.java")]
    for file in sorted(inputs):
        fingerprint.update(file.relative_to(REPO).as_posix().encode()); fingerprint.update(file.read_bytes())
    identity = fingerprint.hexdigest()
    output = (args.output or cache / (args.platform + "-" + args.arch + "-" + identity[:12])).resolve()
    ready = output / ".aether-runtime-ready.json"
    if ready.is_file() and json.loads(ready.read_text()).get("identity") == identity:
        print(output)
        return
    if output.exists():
        if output.is_relative_to(cache) and output != cache and not output.is_symlink():
            shutil.rmtree(output)
        else:
            parser.error("Use a fresh output directory for a changed runtime")
    if args.platform in ("ios", "android") and args.arch not in ("arm64", "x86_64"):
        parser.error("Use a supported 64-bit architecture")
    sdk = cache / "source-sdk"
    native = "lib/py3-mac-universal/" if args.platform == "macos" else "lib/py3-linux-x86_64/" if args.platform == "linux" and args.arch == "x86_64" else ""
    core_missing = not (sdk / "renpy.py").is_file() or not (sdk / "lib/python3.12/encodings").is_dir()
    native_missing = bool(native) and not (sdk / native).is_dir()
    if core_missing or native_missing:
        sdk.mkdir(exist_ok=True)
        # Extract only shared engine data and the requested desktop platform.
        with zipfile.ZipFile(fetch(cache, "sdk.zip")) as archive:
            prefix = "renpy-8.5.3-sdk/"
            for name in archive.namelist():
                if not name.startswith(prefix) or name.endswith("/"): continue
                relative = name[len(prefix):]
                core = core_missing and (relative in ("renpy.py", "LICENSE.txt") or relative.startswith(("renpy/", "lib/python3.12/", "sdk-fonts/")))
                if not (core or native_missing and relative.startswith(native)): continue
                target = sdk / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(name))
                mode = (archive.getinfo(name).external_attr >> 16) & 0o777
                target.chmod(mode or 0o644)
    if args.platform == "linux" and args.arch == "arm64" and not (sdk / "lib/py3-linux-aarch64/librenpython.so").exists():
        arm = cache / "sdk-arm-source"
        tar_extract(fetch(cache, "sdkarm.tar.bz2"), arm)
        native = next(arm.glob("*/lib/py3-linux-aarch64"))
        shutil.copytree(native, sdk / "lib/py3-linux-aarch64", dirs_exist_ok=True)
    if args.platform in ("macos", "linux"):
        metadata = json.load(urllib.request.urlopen("https://pypi.org/pypi/greenlet/3.5.6/json", timeout=30))
        architecture = "aarch64" if args.arch == "arm64" else "x86_64"
        wheel = next(item for item in metadata["urls"] if "cp312-cp312" in item["filename"] and
            ("macosx_11_0_universal2" in item["filename"] if args.platform == "macos" else "manylinux" in item["filename"] and architecture in item["filename"]))
        package = cache / ("greenlet-" + args.platform + "-" + args.arch)
        package.mkdir(exist_ok=True)
        with zipfile.ZipFile(fetch(cache, wheel["filename"], wheel["url"], wheel["digests"]["sha256"])) as archive:
            archive.extractall(package)
        if args.platform == "macos":
            subprocess.run(["python3", str(REPO / "tools/stage_renpy_native.py"), "--sdk", str(sdk), "--greenlet", str(package), "--output", str(output)], check=True)
        else:
            output.mkdir(parents=True, exist_ok=True)
            for name in ("renpy", "lib/python3.12", "lib/py3-linux-" + architecture):
                shutil.copytree(sdk / name, output / name, dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__"))
            for name in ("renpy.py", "LICENSE.txt"):
                shutil.copy2(sdk / name, output / name)
            shutil.copytree(package, output / "lib/python3.12/site-packages", dirs_exist_ok=True)
        ready.write_text(json.dumps({"identity":identity, "version":VERSION, "platform":args.platform, "arch":args.arch}))
        print(output)
        return
    python = cache / "python/Python-3.12.8"
    if not python.is_dir(): tar_extract(fetch(cache, "python.tgz"), python.parent)
    config = cache / "python-config"
    config.mkdir(exist_ok=True)
    if not (config / "pyconfig.h").is_file():
        with (config / "configure.log").open("w") as log:
            subprocess.run([str(python / "configure"), "--without-ensurepip"], cwd=config, stdout=log, stderr=subprocess.STDOUT, check=True)
    greenlet = cache / "greenlet-source/greenlet-3.5.6"
    if not greenlet.is_dir(): tar_extract(fetch(cache, "greenlet.tar.gz"), greenlet.parent)
    common = ["--sdk", str(sdk), "--greenlet-source", str(greenlet), "--python-include", str(python / "Include"), "--python-config", str(config), "--output", str(output)]
    if args.platform.startswith("ios"):
        extra = ["--device"] if args.platform == "ios" else []
        subprocess.run(["python3", str(REPO / "tools/build_renpy_ios.py"), "--renios", str(fetch(cache, "renios.zip")), "--arch", args.arch, *common, *extra], check=True)
    else:
        ndk = args.ndk or os.environ.get("ANDROID_NDK_HOME") or os.environ.get("ANDROID_NDK")
        if not ndk: parser.error("--ndk or ANDROID_NDK_HOME is required")
        abi = "arm64-v8a" if args.arch == "arm64" else "x86_64"
        subprocess.run(["python3", str(REPO / "tools/build_renpy_android.py"), "--rapt", str(fetch(cache, "rapt.zip")), "--ndk", str(ndk), "--abi", abi, *common], check=True)
    ready.write_text(json.dumps({"identity":identity, "version":VERSION, "platform":args.platform, "arch":args.arch}))
    print(output)


if __name__ == "__main__":
    main()
