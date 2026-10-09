#!/usr/bin/env python3
"""Validate public vcpkg files-provider ZIPs; never bypass manifest/ABI install.

Only successful package archives belong in this cache. SDKs, installed trees,
sources, build trees, credentials and compiler logs are outside its boundary.
The Apple cache family fixes the actual tools/profile, while vcpkg recomputes
each port/dependency ABI after restore. Per-port overlay edits therefore miss
only their affected packages. Reports are separate from the cached directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import struct
import subprocess
import sys
import zipfile
import zlib


SCHEMA = 1
HEX = re.compile(r"[0-9a-f]{64}\Z")
PORT = re.compile(r"[a-z0-9][a-z0-9-]*\Z")
TOP_LEVEL = {"include", "lib", "bin", "debug", "share", "tools", "etc"}
# Diagnostic labels only, not a root allowlist. Other root names are hashed,
# so no arbitrary filename is echoed into the Actions console.
ROOT_DIAGNOSTIC_LABELS = {
    "manual-tools", "plugins", "libexec", "sbin", "man", "doc", "docs",
    "cmake", "var", "Frameworks", "Applications", "sdk",
}
# Existing public Mono dependency, maintained as this repository's overlay;
# it is absent from the current and baseline builtin registries.
PUBLIC_ADDITIONAL_OVERLAYS = {"libgdiplus"}
MAX_METADATA = 1024 * 1024
MAX_MEMBERS = 250_000
MAX_ARCHIVE_BYTES = 4 * 1024**3
MAX_EXPANDED_BYTES = 8 * 1024**3
MAX_CACHE_BYTES = 32 * 1024**3
MAX_ARCHIVES = 4096
MAX_CENTRAL_DIRECTORY_BYTES = 32 * 1024**2
MAX_CACHE_EXPANDED_BYTES = 32 * 1024**3
MAX_CACHE_MEMBERS = 1_000_000


class InvalidCache(ValueError):
    """Fixed diagnostic codes avoid echoing untrusted archive free text."""

    def __init__(self, code: str, *, metadata: dict | None = None):
        super().__init__(code)
        self.metadata = metadata


def rejection_message(error: Exception) -> str:
    code = str(error) if isinstance(error, InvalidCache) else type(error).__name__
    message = f"Public dependency cache rejected: {code}"
    if isinstance(error, InvalidCache) and code == "unexpected-package-root" and error.metadata:
        detail = json.dumps(error.metadata, sort_keys=True, separators=(",", ":"))
        require(len(detail) <= 512, "diagnostic-too-large")
        message += " " + detail
    return message


def require(condition: bool, code: str) -> None:
    if not condition:
        raise InvalidCache(code)


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def run(argv: list[str], cwd: Path | None = None) -> str:
    return subprocess.check_output(argv, cwd=cwd, text=True).strip()


def public_ports(repository: Path, vcpkg_root: Path) -> set[str]:
    config = json.loads((repository / "vcpkg-configuration.json").read_text())
    registry = config["default-registry"]
    require(registry["kind"] == "builtin", "non-public-registry")
    require(config.get("registries", []) == [], "additional-registry")
    require(config["overlay-ports"] == ["./vcpkg/ports"], "unexpected-port-overlay")
    names: set[str] = set()
    for rev in (registry["baseline"], "HEAD"):
        names.update(run(["git", "ls-tree", "--name-only", f"{rev}:ports"], vcpkg_root).splitlines())
    require(all(PORT.fullmatch(n) for n in names), "invalid-public-port-name")
    for p in (repository / "vcpkg/ports").iterdir():
        if p.is_dir():
            require(p.name in names or p.name in PUBLIC_ADDITIONAL_OVERLAYS, "overlay-not-public-port")
            manifest = json.loads((p / "vcpkg.json").read_text())
            require(manifest["name"] == p.name, "overlay-name-mismatch")
            names.add(p.name)
    return names


def apple_identity(repository: Path, vcpkg_root: Path, sdk: str, triplet: str,
                   internal: str) -> dict:
    require(internal == "OFF", "internal-profile-enabled")
    require(platform.system() == "Darwin", "real-apple-host-required")
    require("OSXCROSS_IOS" not in os.environ, "cross-sdk-not-supported")
    expected = {"iphonesimulator": "arm64-ios-simulator", "iphoneos": "arm64-ios"}
    require(expected.get(sdk) == triplet, "sdk-triplet-mismatch")
    arch = platform.machine()
    require(arch in ("arm64", "x86_64"), "unsupported-apple-host")
    host_triplet = "arm64-osx" if arch == "arm64" else "x64-osx"
    public_ports(repository, vcpkg_root)
    config = json.loads((repository / "vcpkg-configuration.json").read_text())
    compilers = {}
    for name in ("clang", "clang++"):
        path = Path(run(["xcrun", "--sdk", sdk, "--find", name]))
        compilers[name] = {"path": str(path), "sha256": digest(path),
                           "version": run([str(path), "--version"])}
    cmake = shutil.which("cmake")
    require(cmake is not None, "cmake-missing")
    sdks = {}
    for name in ("macosx", sdk):
        sdks[name] = {
            "path": str(Path(run(["xcrun", "--sdk", name, "--show-sdk-path"])).resolve()),
            "version": run(["xcrun", "--sdk", name, "--show-sdk-version"]),
            "build": run(["xcrun", "--sdk", name, "--show-sdk-build-version"]),
        }
    return {
        "schema": SCHEMA, "profile": "public-renpy-on-internal-off-ios-debug",
        "host_triplet": host_triplet, "target_triplet": triplet,
        "host_os": run(["sw_vers", "-productVersion"]), "host_arch": arch,
        "developer": run(["xcode-select", "--print-path"]),
        "xcode": run(["xcodebuild", "-version"]), "sdks": sdks,
        "compilers": compilers,
        "cmake": {"path": cmake, "sha256": digest(Path(cmake)), "version": run([cmake, "--version"])},
        "vcpkg": {"head": run(["git", "rev-parse", "HEAD"], vcpkg_root),
                  "sha256": digest(vcpkg_root / "vcpkg"),
                  "version": run([str(vcpkg_root / "vcpkg"), "version"])},
        "baseline": config["default-registry"]["baseline"],
        "inputs": {name: digest(repository / name) for name in (
            "vcpkg.json", "vcpkg-configuration.json", "CMakePresets.json",
            f"vcpkg/triplets/{triplet}.cmake", "vcpkg/meson/ios-cross.ini")},
        "host_triplet_sha256": digest(next(p for p in (
            vcpkg_root / "triplets" / f"{host_triplet}.cmake",
            vcpkg_root / "triplets/community" / f"{host_triplet}.cmake") if p.is_file())),
        "validator_sha256": digest(Path(__file__)),
    }


def family(identity: dict) -> str:
    return "ios-public-vcpkg-v1-" + hashlib.sha256(canonical(identity)).hexdigest()


def paragraphs(data: bytes) -> list[dict[str, str]]:
    require(len(data) <= MAX_METADATA, "metadata-too-large")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise InvalidCache("metadata-not-utf8") from e
    require("\x00" not in text, "metadata-nul")
    result: list[dict[str, str]] = []
    for section in re.split(r"\n\s*\n", text.strip()):
        fields: dict[str, str] = {}
        key = ""
        for line in section.splitlines():
            if line[:1].isspace():
                require(bool(key), "invalid-control-continuation")
                fields[key] += "\n" + line
            else:
                require(":" in line, "invalid-control-field")
                key, value = line.split(":", 1)
                require(key not in fields and bool(key), "duplicate-control-field")
                fields[key] = value.strip()
        result.append(fields)
    return result


def safe_member(name: str) -> str:
    require(bool(name) and not any(c in name for c in ("\\", ":", "//"))
            and not any(ord(c) < 32 or ord(c) == 127 for c in name), "unsafe-member")
    require(not name.startswith("/") and all(p not in ("", ".", "..") for p in name.rstrip("/").split("/")), "unsafe-member")
    return name.rstrip("/")


def preflight_central_directory(path: Path) -> None:
    # Bound zipfile's central-directory allocation before it parses any entry.
    size = path.stat().st_size
    require(size <= MAX_ARCHIVE_BYTES, "archive-too-large")
    with path.open("rb") as f:
        f.seek(max(0, size - 65557))
        tail = f.read()
        start = tail.rfind(b"PK\x05\x06")
        require(start >= 0 and len(tail) - start >= 22, "invalid-zip-end")
        _, disk, cd_disk, disk_count, count, cd_size, cd_offset, comment = struct.unpack(
            "<4s4H2LH", tail[start:start + 22])
        require(start + 22 + comment == len(tail), "invalid-zip-end")
        end_offset = size - len(tail) + start
        require(disk == cd_disk == 0 and disk_count == count, "multipart-zip")
        sentinel = count == 0xffff or cd_size == 0xffffffff or cd_offset == 0xffffffff
        locator = b""
        if end_offset >= 20:
            f.seek(end_offset - 20)
            locator = f.read(20)
        has_zip64 = locator.startswith(b"PK\x06\x07")
        require(has_zip64 or not sentinel, "invalid-zip64-end")
        # Like zipfile, a present locator overrides ordinary EOCD metadata,
        # even when the ordinary fields do not contain ZIP64 sentinel values.
        if has_zip64:
            sig, disk, zip64_offset, disks = struct.unpack("<4sLQL", locator)
            require(sig == b"PK\x06\x07" and disk == 0 and disks == 1,
                    "invalid-zip64-end")
            require(zip64_offset + 56 <= end_offset - 20, "invalid-zip64-end")
            f.seek(zip64_offset)
            record = f.read(56)
            require(len(record) == 56, "invalid-zip64-end")
            sig, record_size, _, _, disk, cd_disk, disk_count, count, cd_size, cd_offset = struct.unpack(
                "<4sQ2H2L4Q", record)
            require(sig == b"PK\x06\x06" and 44 <= record_size <= MAX_METADATA
                    and zip64_offset + 12 + record_size <= end_offset - 20,
                    "invalid-zip64-end")
            require(disk == cd_disk == 0 and disk_count == count, "multipart-zip")
            end_offset = zip64_offset
        require(0 < count <= MAX_MEMBERS, "archive-member-count")
        require(cd_size <= MAX_CENTRAL_DIRECTORY_BYTES, "central-directory-too-large")
        require(cd_offset + cd_size <= end_offset, "invalid-central-directory")


def validate_archive(path: Path, ports: set[str], triplets: set[str]) -> dict:
    abi = path.stem
    require(bool(HEX.fullmatch(abi)) and path.parent.name == abi[:2], "invalid-archive-identity")
    preflight_central_directory(path)
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        require(0 < len(infos) <= MAX_MEMBERS, "archive-member-count")
        require(sum(i.file_size for i in infos) <= MAX_EXPANDED_BYTES, "archive-expanded-size")
        members: dict[str, zipfile.ZipInfo] = {}
        links: dict[str, str] = {}
        unexpected_members = []
        for i in infos:
            n = safe_member(i.filename)
            require(n not in members, "duplicate-member")
            require(not i.flag_bits & 1, "encrypted-member")
            mode = stat.S_IFMT(i.external_attr >> 16)
            require(mode in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK), "special-member")
            root = n.split("/", 1)[0]
            if n not in ("CONTROL", "BUILD_INFO") and root not in TOP_LEVEL:
                unexpected_members.append(n)
            members[n] = i
            if mode == stat.S_IFLNK:
                require(i.file_size <= MAX_METADATA, "symlink-too-large")
                try:
                    target = z.read(i).decode("utf-8")
                except UnicodeDecodeError as e:
                    raise InvalidCache("invalid-symlink") from e
                require(bool(target) and not target.startswith("/") and not any(c in target for c in ("\\", ":"))
                        and not any(ord(c) < 32 or ord(c) == 127 for c in target), "unsafe-symlink")
                links[n] = target
        for n in members:
            for parent in PurePosixPath(n).parents:
                require(str(parent) not in links, "member-under-symlink")
        def resolve_link(n: str, seen: set[str]) -> str:
            require(n not in seen, "symlink-cycle")
            if n not in links:
                return n
            parts = n.split("/")[:-1]
            for piece in links[n].split("/"):
                if piece in ("", "."):
                    continue
                if piece == "..":
                    require(bool(parts), "escaping-symlink")
                    parts.pop()
                else:
                    parts.append(piece)
            target = "/".join(parts)
            require(target in members, "missing-symlink-target")
            return resolve_link(target, seen | {n})
        for n in links:
            resolve_link(n, set())
        require("CONTROL" in members and "CONTROL" not in links, "missing-control")
        require(members["CONTROL"].file_size <= MAX_METADATA, "metadata-too-large")
        control = paragraphs(z.read("CONTROL"))
        core = control[0]
        name = core.get("Package", "")
        triplet = core.get("Architecture", "")
        require(name in ports and bool(PORT.fullmatch(name)), "non-public-package")
        require(triplet in triplets, "unexpected-package-triplet")
        require(core.get("Abi") == abi, "control-abi-mismatch")
        require(bool(core.get("Version")) and core.get("Multi-Arch") == "same", "invalid-core-control")
        for feature in control[1:]:
            require(feature.get("Package") == name and feature.get("Architecture") == triplet and bool(feature.get("Feature")), "invalid-feature-control")
        for paragraph in control:
            for dependency in paragraph.get("Depends", "").split(","):
                if dependency.strip():
                    dep = re.split(r"[ :\[]", dependency.strip(), maxsplit=1)[0]
                    require(dep in ports, "non-public-dependency")
        abi_path = f"share/{name}/vcpkg_abi_info.txt"
        require(abi_path in members and abi_path not in links, "missing-abi-info")
        require(members[abi_path].file_size <= MAX_METADATA, "metadata-too-large")
        abi_info = z.read(abi_path)
        require(hashlib.sha256(abi_info).hexdigest() == abi, "abi-info-digest-mismatch")
        require(f"triplet {triplet}\n".encode() in abi_info.splitlines(keepends=True), "abi-info-triplet-mismatch")
        # GLib 2.84.2's non-Cocoa GIO branch installs this helper in libexec.
        # The pinned public 2.84.2#2 port retains it and disables installed
        # tests. Permit its exact regular-file payload after package/ABI gates;
        # this does not allow a general libexec subtree or another package.
        helper = "libexec/gio-launch-desktop"
        glib_helper = (name == "glib" and core.get("Version") == "2.84.2"
                       and core.get("Port-Version") == "2" and helper in members
                       and helper not in links and not members[helper].is_dir()
                       and stat.S_IFMT(members[helper].external_attr >> 16) in (0, stat.S_IFREG))
        rejected_root = None
        for n in unexpected_members:
            if glib_helper and (n == helper or (n == "libexec" and members[n].is_dir())):
                continue
            rejected_root = n.split("/", 1)[0]
            break
        if rejected_root is not None:
            metadata = {"abi": abi, "package": name, "triplet": triplet}
            if rejected_root in ROOT_DIAGNOSTIC_LABELS:
                metadata["root"] = rejected_root
            else:
                metadata["root_sha256"] = hashlib.sha256(rejected_root.encode()).hexdigest()
            raise InvalidCache("unexpected-package-root", metadata=metadata)
        # Read all bytes and check their CRC before vcpkg's unzip consumer sees them.
        for i in infos:
            with z.open(i) as f:
                while f.read(1024 * 1024):
                    pass
    return {"abi": abi, "sha256": digest(path), "package": name, "triplet": triplet}


def validate_cache(cache_dir: Path, ports: set[str], triplets: set[str]) -> dict:
    require(not cache_dir.is_symlink(), "cache-root-symlink")
    cache_dir.mkdir(parents=True, exist_ok=True)
    archives = []
    paths = []
    total = 0
    expanded = 0
    member_count = 0
    # Reject total resource budgets before decompressing the first payload.
    for bucket in sorted(cache_dir.iterdir()):
        require(not bucket.is_symlink() and bucket.is_dir() and bool(re.fullmatch(r"[0-9a-f]{2}", bucket.name)), "invalid-cache-bucket")
        for path in sorted(bucket.iterdir()):
            require(len(paths) < MAX_ARCHIVES, "cache-archive-count")
            require(not path.is_symlink() and path.is_file() and path.suffix == ".zip", "invalid-cache-file")
            total += path.stat().st_size
            require(total <= MAX_CACHE_BYTES, "cache-too-large")
            preflight_central_directory(path)
            try:
                with zipfile.ZipFile(path) as z:
                    infos = z.infolist()
                    archive_expanded = sum(i.file_size for i in infos)
                    require(0 < len(infos) <= MAX_MEMBERS, "archive-member-count")
                    require(archive_expanded <= MAX_EXPANDED_BYTES, "archive-expanded-size")
                    expanded += archive_expanded
                    member_count += len(infos)
            except (zipfile.BadZipFile, zlib.error, RuntimeError, NotImplementedError) as e:
                raise InvalidCache("invalid-zip-payload") from e
            require(expanded <= MAX_CACHE_EXPANDED_BYTES, "cache-expanded-size")
            require(member_count <= MAX_CACHE_MEMBERS, "cache-member-count")
            paths.append(path)
    for path in paths:
        try:
            archives.append(validate_archive(path, ports, triplets))
        except (zipfile.BadZipFile, zlib.error, RuntimeError, NotImplementedError) as e:
            raise InvalidCache("invalid-zip-payload") from e
    return {"schema": SCHEMA, "status": "public_binary_archives_verified",
            "archive_count": len(archives), "archives": archives,
            "content_sha256": hashlib.sha256(canonical(archives)).hexdigest(),
            "source_build": "not_run", "app": "not_run", "gameplay": "not_run"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("family", "validate"):
        p = sub.add_parser(command)
        p.add_argument("--repository", type=Path, required=True)
        p.add_argument("--vcpkg-root", type=Path, required=True)
        p.add_argument("--sdk", choices=("iphoneos", "iphonesimulator"), required=True)
        p.add_argument("--triplet", choices=("arm64-ios", "arm64-ios-simulator"), required=True)
        p.add_argument("--internal", choices=("OFF",), required=True)
        if command == "validate":
            p.add_argument("--cache-dir", type=Path, required=True)
            p.add_argument("--report", type=Path, required=True)
            p.add_argument("--previous-report", type=Path)
            p.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    try:
        identity = apple_identity(args.repository, args.vcpkg_root, args.sdk, args.triplet, args.internal)
        key = family(identity)
        if args.command == "family":
            print(key)
            return 0
        cache = args.cache_dir.resolve()
        require(not args.report.resolve().is_relative_to(cache), "report-inside-cache")
        report = validate_cache(args.cache_dir, public_ports(args.repository, args.vcpkg_root),
                                {args.triplet, identity["host_triplet"]})
        report["family"] = key
        previous = []
        if args.previous_report:
            old = json.loads(args.previous_report.read_text())
            require(old["family"] == key and old["schema"] == SCHEMA, "previous-report-family-mismatch")
            previous = old["archives"]
        old_pairs = {(a["abi"], a["sha256"]) for a in previous}
        require(old_pairs <= {(a["abi"], a["sha256"]) for a in report["archives"]}, "existing-archive-changed")
        report["new_archive_count"] = (sum((a["abi"], a["sha256"]) not in old_pairs
                                           for a in report["archives"])
                                       if args.previous_report else 0)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        summary = {k: report[k] for k in ("status", "archive_count", "new_archive_count", "content_sha256", "source_build", "app", "gameplay")}
        print(json.dumps(summary, sort_keys=True))
        if args.github_output:
            with args.github_output.open("a") as f:
                f.write(f"archive-count={report['archive_count']}\nnew-archive-count={report['new_archive_count']}\n")
        return 0
    except (InvalidCache, zipfile.BadZipFile, OSError, KeyError, ValueError,
            RuntimeError, NotImplementedError, subprocess.CalledProcessError) as e:
        print(rejection_message(e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
