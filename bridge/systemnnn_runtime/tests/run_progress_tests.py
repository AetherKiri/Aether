#!/usr/bin/env python3
"""Build standalone progress tests against an existing Emberfall build.

Usage:
  python3 run_progress_tests.py EMBERFALL_SOURCE EMBERFALL_BUILD [--java]
Requires the existing build's emberfall-scene, emberfall-render and core static
libraries, the C++ compiler in CXX (default c++), and system libpng/zlib.
--java also checks the unmodified sibling Java readers using javac/java.
"""
import argparse
import os
import pathlib
import shlex
import subprocess
import tempfile


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source",type=pathlib.Path)
    parser.add_argument("build",type=pathlib.Path)
    parser.add_argument("--java",action="store_true")
    args=parser.parse_args()
    source=args.source.resolve()
    build=args.build.resolve()
    here=pathlib.Path(__file__).resolve().parent
    libraries=[build/"libemberfall-scene.a",build/"nnn-render/libemberfall-render.a"]
    libraries += [build/"nnn-core"/("lib"+name+".a") for name in (
        "nnn-game-audio","nnn-script-core","nnn-dwq-core","nnn-image-core",
        "nnn-png-core","nnn-archive-core")]
    for library in libraries:
        if not library.is_file():
            parser.error("Build the existing Emberfall dependencies first: "+str(library))
    with tempfile.TemporaryDirectory(prefix="systemnnn-progress-build-") as tmp:
        binary=pathlib.Path(tmp)/"progress-tests"
        command=shlex.split(os.environ.get("CXX","c++"))
        command += ["-std=c++17","-Wall","-Wextra","-Wpedantic"]
        command += shlex.split(os.environ.get("CXXFLAGS",""))
        command += ["-I"+str(source/path) for path in (
            "core/include","platform/scene/include","platform/render/include")]
        command += [str(here/"systemnnn_progress_tests.cpp"),"-Wl,--start-group"]
        command += [str(path) for path in libraries]
        command += ["-Wl,--end-group","-lpng","-lz","-lm","-pthread","-o",str(binary)]
        subprocess.run(command,check=True)
        subprocess.run([str(binary)],check=True)
        if args.java:
            subprocess.run(["python3",str(here/"check_progress_java.py"),str(source),str(binary)],check=True)

if __name__=="__main__":
    main()
