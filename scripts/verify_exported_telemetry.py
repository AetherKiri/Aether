#!/usr/bin/env python3
"""Check the telemetry settings inside a shipped Godot APK, IPA, or PCK."""

import argparse
import json
import os
from pathlib import Path
import struct
import zipfile

from export_with_telemetry_config import CHANNEL, normalize_endpoint


CONFIG_PATH = "config/telemetry_export.json"
CONFIG_MAX_SIZE = 1024  # Match the runtime's limit.


def read_pck_config(pack):
    # Godot 4 uses a separate directory offset in standalone v3/v4 packs.
    # See core/io/file_access_pack.cpp in the pinned Godot release.
    magic, version, _, _, _, flags, data_offset, directory = struct.unpack("<4sIIIIIQQ", pack.read(40))
    if magic != b"GDPC" or version not in (3, 4) or flags & ~2:
        raise ValueError("expected an unencrypted standalone Godot PCK (v3 or v4)")
    pack.seek(0, os.SEEK_END)
    pack_size = pack.tell()
    if not 40 <= data_offset <= directory <= pack_size - 4:
        raise ValueError("invalid PCK directory or data offset")
    pack.seek(directory)
    count, = struct.unpack("<I", pack.read(4))
    config = None
    for _ in range(count):
        path_size, = struct.unpack("<I", pack.read(4))
        if path_size > pack_size - pack.tell() - 36:
            raise ValueError("invalid PCK directory entry")
        # Skip other paths without reading them into memory.
        if path_size > len(CONFIG_PATH) + len("res://") + 3:
            pack.seek(path_size + 36, os.SEEK_CUR)
            continue
        path = pack.read(path_size).rstrip(b"\0").removeprefix(b"res://")
        offset, size, _, file_flags = struct.unpack("<QQ16sI", pack.read(36))
        if path == CONFIG_PATH.encode():
            if config is not None or file_flags or size > CONFIG_MAX_SIZE or offset + size > directory - data_offset:
                raise ValueError("invalid packed telemetry config entry")
            config = (data_offset + offset, size)
    if config is None:
        raise ValueError(f"missing {CONFIG_PATH} in the PCK")
    offset, size = config
    pack.seek(offset)
    return pack.read(size)


def read_config(artifact):
    if artifact.suffix == ".apk":
        with zipfile.ZipFile(artifact) as archive:
            entry = archive.getinfo(f"assets/{CONFIG_PATH}")
            if entry.file_size > CONFIG_MAX_SIZE:
                raise ValueError("invalid APK telemetry config size")
            return archive.read(entry)
    if artifact.suffix == ".ipa":
        with zipfile.ZipFile(artifact) as archive:
            with archive.open("Payload/Aether.app/Aether.pck") as pack:
                return read_pck_config(pack)
    if artifact.suffix == ".pck":
        with artifact.open("rb") as pack:
            return read_pck_config(pack)
    raise ValueError("expected an .apk, .ipa, or .pck file")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path, nargs="?", help="omit for a configuration preflight")
    args = parser.parse_args()

    raw_endpoint = os.environ.get("AETHER_TELEMETRY_ENDPOINT", "")
    if not raw_endpoint:
        parser.exit(1, "::error::AETHER_TELEMETRY_ENDPOINT is required for telemetry test builds. Set the Actions repository variable.\n")
    endpoint = normalize_endpoint(raw_endpoint)
    if not endpoint:
        parser.exit(1, "::error::AETHER_TELEMETRY_ENDPOINT must be a public HTTPS origin or /v1/events URL, without credentials, a query, or a fragment.\n")
    channel = os.environ.get("AETHER_TELEMETRY_CHANNEL", "")
    if not CHANNEL.fullmatch(channel):
        parser.exit(1, "::error::AETHER_TELEMETRY_CHANNEL is missing or invalid.\n")
    if args.artifact is None:
        return

    try:
        actual = json.loads(read_config(args.artifact))
    except (OSError, ValueError, KeyError, struct.error, zipfile.BadZipFile) as error:
        parser.exit(1, f"::error::{args.artifact}: could not read exported telemetry config ({error}).\n")
    if actual != {"endpoint": endpoint, "channel": channel}:
        parser.exit(1, f"::error::{args.artifact}: exported telemetry endpoint or channel does not match the test build configuration.\n")
    print(f"Verified telemetry endpoint and channel {channel} in {args.artifact}.")


if __name__ == "__main__":
    main()
