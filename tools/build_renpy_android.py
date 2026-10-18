#!/usr/bin/env python3
"""Prepare a native Ren'Py Android runtime, private SDL Java host and JNI bridge."""
import argparse
import importlib.util
import hashlib
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

REPO = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--rapt", type=Path, required=True)
    parser.add_argument("--greenlet-source", type=Path, required=True)
    parser.add_argument("--python-include", type=Path, required=True)
    parser.add_argument("--python-config", type=Path, required=True)
    parser.add_argument("--ndk", type=Path, required=True)
    parser.add_argument("--abi", choices=("arm64-v8a", "x86_64"), default="arm64-v8a")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    sdk, output = args.sdk.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if "8.5.3.26051504" not in (sdk / "renpy/vc_version.py").read_text():
        parser.error("Use the matching Ren'Py 8.5.3 SDK")
    spec = importlib.util.spec_from_file_location("renpy_copy", REPO / "apps/godot_app/renpy_runtime/host.py")
    copy = importlib.util.module_from_spec(spec); spec.loader.exec_module(copy)
    def clone(src, dst):
        copy.copy_file(Path(src), Path(dst)); return dst
    runtime = output / "runtime"
    for name in ("renpy", "lib/python3.12"):
        shutil.copytree(sdk / name, runtime / name, copy_function=clone, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns("__pycache__"))
    for name in ("renpy.py", "LICENSE.txt"):
        shutil.copy2(sdk / name, runtime / name)
    greenlet = args.greenlet_source.resolve()
    shutil.copytree(greenlet / "src/greenlet", runtime / "lib/python3.12/site-packages/greenlet",
                    copy_function=clone, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("tests", "__pycache__", "*.cpp", "*.c", "*.h", "*.hpp", "platform"))
    license_dir = runtime / "licenses/greenlet"
    license_dir.mkdir(parents=True, exist_ok=True)
    for name in ("LICENSE", "LICENSE.PSF"):
        shutil.copy2(greenlet / name, license_dir / name)
    # Keep SDL's Java classes private. The official binary binds its own
    # symbols (DT_SYMBOLIC) and JNI_OnLoad registers methods by these class
    # strings, so equal-length renaming needs no ELF symbol/hash rewriting.
    java_root = output / "java"
    jni = output / "jni" / args.abi
    jni.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(args.rapt) as archive:
        prefix = "rapt/prototype/renpyandroid/src/main/java/org/libsdl/app/"
        for name in archive.namelist():
            if name.startswith(prefix) and name.endswith(".java"):
                content = archive.read(name).decode().replace("org.libsdl.app", "org.aether.sdl")
                if name.endswith("/SDLActivity.java"):
                    content = content.replace("extends Activity", "extends org.godotengine.godot.GodotActivity")
                    content = re.sub(r"protected void (onCreate|onPause|onResume|onStart|onStop|onDestroy)\(", r"public void \1(", content)
                    content = content.replace("mSDLThread.join();", "mSDLThread.join(1500);")
                    content = content.replace("        setWindowStyle(false);", "        // Aether owns the Activity's window style.")
                    content = content.replace("        getWindow().getDecorView().setOnSystemUiVisibilityChangeListener(this);", "")
                    content = content.replace("        super.onCreate(savedInstanceState);", """        super.onCreate(savedInstanceState);
        if (!mBrokenLibraries && mSurface != null && mLayout != null) {
            // Keep the Python owner thread and native Surface across an
            // Activity configuration recreation, just like Godot's fragment.
            mSingleton = this;
            SDL.setContext(this);
            return;
        }""")
                    boundary = "    public void onDestroy() {"
                    if content.count(boundary) != 1:
                        raise RuntimeError("The SDK Activity destruction boundary changed")
                    content = content.replace(boundary, boundary + "\n        if (isChangingConfigurations()) { super.onDestroy(); return; }")
                    content = content.replace("new RelativeLayout(this)", "new RelativeLayout(getApplication())")
                    content = content.replace("public static void setWindowStyle(boolean fullscreen) {",
                        "public static void setWindowStyle(boolean fullscreen) {\n        if (mSingleton instanceof org.renpy.android.PythonSDLActivity) return; // Aether owns the top-level window.")
                target = java_root / "org/aether/sdl" / Path(name).name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content)
        for name in ("RenPySound.java", "VideoPlayer.java", "Action.java", "GenericBroadcastReceiver.java", "GenericBroadcastReceiverCallback.java", "ResourceManager.java"):
            target = java_root / "org/renpy/android" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read("rapt/prototype/renpyandroid/src/main/java/org/renpy/android/" + name))
        library = archive.read(f"rapt/prototype/renpyandroid/src/main/jniLibs/{args.abi}/librenpython.so")
        library = library.replace(b"org/libsdl/app/", b"org/aether/sdl/")
        (jni / "librenpython.so").write_bytes(library)
    for file in (REPO / "bridge/renpy_runtime/android/src/main/java").rglob("*.java"):
        target = java_root / file.relative_to(REPO / "bridge/renpy_runtime/android/src/main/java")
        target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(file, target)
    bootstrap = runtime / "renpy/bootstrap.py"
    content = bootstrap.read_text()
    old = "        if renpy.android:\n            from jnius import autoclass"
    if content.count(old) != 1:
        raise RuntimeError("The SDK's Android shutdown boundary changed")
    bootstrap.write_text(content.replace(old, "        if renpy.android and not os.environ.get(\"AETHER_RENPY_EMBEDDED\"):\n            from jnius import autoclass"))
    for file in runtime.rglob("*"):
        if file.is_file() and file.suffix in {".py", ".pyc", ".rpy"}:
            data = file.read_bytes()
            changed = data.replace(b"org.libsdl.app.", b"org.aether.sdl.").replace(b"org/libsdl/app/", b"org/aether/sdl/")
            if data != changed: file.write_bytes(changed)
    (runtime / "AETHER_NATIVE_SDK.txt").write_text(
        "Ren'Py 8.5.3.26051504, CPython 3.12.8, greenlet 3.5.6. Native Android embedding.\n"
        "SDL JNI class names isolated to org.aether.sdl; bootstrap returns to Aether.\n"
        "Sources: https://github.com/renpy/renpy https://github.com/renpy/renpy-build https://github.com/python-greenlet/greenlet\n"
        "Rebuild with tools/build_renpy_android.py and bridge/renpy_runtime/android.\n")
    prebuilt = next((args.ndk / "toolchains/llvm/prebuilt").glob("*"))
    target = "aarch64-linux-android26" if args.abi == "arm64-v8a" else "x86_64-linux-android26"
    compiler = prebuilt / "bin" / (target + "-clang++")
    base = [str(compiler), "-std=c++17", "-O2", "-fPIC", "-I" + str(args.python_include.resolve()), "-I" + str(args.python_config.resolve())]
    objects = []
    for name, source in {"host":REPO / "bridge/renpy_runtime/android/native_host.cpp", "greenlet":greenlet / "src/greenlet/greenlet.cpp"}.items():
        obj = output / (name + "-" + args.abi + ".o")
        subprocess.run(base + ["-c", str(source), "-o", str(obj)], check=True)
        objects.append(str(obj))
    subprocess.run(base + ["-shared", "-static-libstdc++", "-Wl,-z,defs", "-Wl,-z,max-page-size=16384",
        "-Wl,-soname,libaether_renpy_android.so", *objects, "-L" + str(jni), "-lrenpython", "-llog", "-ldl", "-landroid",
        "-o", str(jni / "libaether_renpy_android.so")], check=True)
    assets = output / "assets"; assets.mkdir(exist_ok=True)
    with zipfile.ZipFile(assets / "aether_renpy_runtime.zip", "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for file in sorted(runtime.rglob("*")):
            if file.is_file():
                info = zipfile.ZipInfo(file.relative_to(runtime).as_posix())
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o644 << 16
                archive.writestr(info, file.read_bytes())
    digest = hashlib.file_digest((assets / "aether_renpy_runtime.zip").open("rb"), "sha256").hexdigest()
    (assets / "aether_renpy_runtime.sha256").write_text(digest + "\n")
    print(output)


if __name__ == "__main__":
    main()
