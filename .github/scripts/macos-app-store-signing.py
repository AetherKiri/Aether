#!/usr/bin/env python3
"""Sign embedded macOS code and check every executable before packaging."""

import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile


SANDBOX = "com.apple.security.app-sandbox"
INHERIT = "com.apple.security.inherit"


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True, capture_output=True)


def code_files(root, target_arch):
    """Inspect physical files only; resource aliases must not be signed twice."""
    for directory, directories, files in os.walk(root, followlinks=False):
        directories[:] = sorted(
            name for name in directories if not (Path(directory) / name).is_symlink()
        )
        for name in sorted(files):
            path = Path(directory) / name
            if path.is_symlink() or not path.is_file():
                continue
            if b"Mach-O" not in run("file", "-b", path).stdout:
                continue
            architectures = run("lipo", "-archs", path).stdout.decode().split()
            if target_arch not in architectures:
                raise ValueError(f"Mac App Store runtime is missing {target_arch}: {path} ({architectures})")
            # File extensions and executable permission bits do not distinguish
            # MH_EXECUTE from MH_DYLIB/MH_BUNDLE, especially in universal files.
            lines = iter(run("otool", "-arch", "all", "-hv", path).stdout.decode().splitlines())
            types = []
            for line in lines:
                columns = line.split()
                if columns and columns[0] == "magic" and "filetype" in columns:
                    values = next(lines, "").split()
                    index = columns.index("filetype")
                    if len(values) <= index:
                        raise ValueError(f"Invalid Mach-O header: {path}")
                    types.append(values[index])
            if len(types) != len(architectures) or len(set(types)) != 1:
                raise ValueError(f"Inconsistent Mach-O headers: {path}")
            if types[0] not in {"EXECUTE", "DYLIB", "BUNDLE"}:
                raise ValueError(f"Unsupported packaged Mach-O type {types[0]}: {path}")
            yield path, architectures, types[0]


def read_entitlements(path, architecture, allow_unsigned=False):
    result = subprocess.run(
        ["codesign", "--display", "--architecture", architecture, "--entitlements", ":-", str(path)],
        capture_output=True,
    )
    if result.returncode:
        if allow_unsigned and b"code object is not signed at all" in result.stderr:
            return {}
        result.check_returncode()
    entitlements = plistlib.loads(result.stdout) if result.stdout.strip() else {}
    if not isinstance(entitlements, dict):
        raise ValueError(f"Entitlements are not a dictionary: {path} ({architecture})")
    return entitlements


def check_inheritance(entitlements, path):
    # Apple requires exactly sandbox + inherit among the App Sandbox keys.
    # https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app
    # Hardened Runtime (cs.*) and other existing capabilities are independent.
    # Refuse incompatible input instead of silently discarding permissions.
    incompatible = sorted(
        key for key in entitlements
        if key.startswith("com.apple.security.")
        and not key.startswith("com.apple.security.cs.")
        and key not in {SANDBOX, INHERIT}
    )
    if incompatible:
        raise ValueError(f"Helper has App Sandbox entitlements incompatible with inheritance: {path}: {incompatible}")


def sign_nested(app, target_arch, identity, keychain):
    frameworks = app / "Contents/Frameworks"
    # Complete inspection before changing any signatures. All slices must be
    # compatible with the single entitlements plist codesign applies to them.
    code = list(code_files(frameworks, target_arch))
    helpers = {}
    originals = {}
    for path, architectures, kind in code:
        originals[path] = {
            arch: read_entitlements(path, arch, allow_unsigned=True) for arch in architectures
        }
        if kind != "EXECUTE":
            continue
        existing = list(originals[path].values())
        if any(entitlements != existing[0] for entitlements in existing[1:]):
            raise ValueError(f"Helper entitlements differ across architectures: {path}")
        entitlements = existing[0]
        check_inheritance(entitlements, path)
        helpers[path] = dict(entitlements, **{SANDBOX: True, INHERIT: True})

    signing_args = ["codesign", "--force", "--sign", identity, "--keychain", keychain, "--timestamp"]
    with tempfile.TemporaryDirectory(prefix="aether-helper-entitlements-") as directory:
        entitlement_file = Path(directory) / "helper.plist"
        # Seal leaves before their enclosing frameworks, then the caller signs
        # the main app. Never use --deep for signing.
        for path, _, _ in sorted(code, key=lambda item: len(item[0].parts), reverse=True):
            if path in helpers:
                entitlement_file.write_bytes(plistlib.dumps(helpers[path]))
                run(*signing_args, "--entitlements", entitlement_file, path)
            else:
                # On macOS 15, preservation alone still drops library
                # entitlements. Opt in only when there are existing keys.
                library_args = ["--preserve-metadata=entitlements"]
                if any(originals[path].values()):
                    library_args.append("--force-library-entitlements")
                run(*signing_args, *library_args, path)
        bundles = [
            Path(directory) for directory, _, _ in os.walk(frameworks, followlinks=False)
            if Path(directory).suffix == ".framework" and not Path(directory).is_symlink()
        ]
        for bundle in sorted(bundles, key=lambda path: len(path.parts), reverse=True):
            # Sealing a framework re-signs its library again. This flag only
            # retains existing metadata; no entitlements plist is supplied.
            run(*signing_args, "--preserve-metadata=entitlements", "--force-library-entitlements", bundle)
        for path, architectures, kind in code:
            if kind != "EXECUTE":
                for architecture in architectures:
                    if read_entitlements(path, architecture) != originals[path][architecture]:
                        raise ValueError(f"Library entitlements changed during signing: {path} ({architecture})")


def verify(app, target_arch):
    with (app / "Contents/Info.plist").open("rb") as stream:
        executable = plistlib.load(stream)["CFBundleExecutable"]
    main = app / "Contents/MacOS" / executable
    found_main = False
    # Scan all Contents, not only Frameworks, so newly embedded executables
    # cannot escape the check. Libraries, scripts and resource aliases differ.
    for path, architectures, kind in code_files(app / "Contents", target_arch):
        if kind != "EXECUTE":
            continue
        run("codesign", "--verify", "--strict", "--all-architectures", path)
        for architecture in architectures:
            entitlements = read_entitlements(path, architecture)
            if entitlements.get(SANDBOX) is not True:
                raise ValueError(f"Signed executable is missing Boolean App Sandbox: {path} ({architecture})")
            if path == main:
                found_main = True
                if entitlements.get(INHERIT):
                    raise ValueError(f"Main application must not inherit a sandbox: {path} ({architecture})")
            else:
                if entitlements.get(INHERIT) is not True:
                    raise ValueError(f"Signed helper is missing Boolean sandbox inheritance: {path} ({architecture})")
                check_inheritance(entitlements, path)
            print(f"Verified App Sandbox: {path.relative_to(app)} ({architecture})")
    if not found_main:
        raise ValueError(f"Main application is not a physical Mach-O executable: {main}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("sign-nested", "verify"))
    parser.add_argument("app", type=Path)
    parser.add_argument("--target-arch", choices=("arm64", "x86_64"), required=True)
    parser.add_argument("--identity")
    parser.add_argument("--keychain")
    args = parser.parse_args()
    if args.action == "sign-nested" and (not args.identity or not args.keychain):
        parser.error("sign-nested requires --identity and --keychain")
    try:
        if args.action == "sign-nested":
            sign_nested(args.app, args.target_arch, args.identity, args.keychain)
        else:
            verify(args.app, args.target_arch)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        details = ""
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            details = error.stderr.decode(errors="replace")
        parser.exit(1, f"Mac App Store signing failed: {error}\n{details}")


if __name__ == "__main__":
    main()
