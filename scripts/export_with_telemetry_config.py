#!/usr/bin/env python3
"""Stage telemetry settings for a Godot export that requires recovery mode."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


# Match the Godot export plugin's accepted endpoint and channel syntax.
DNS_LABEL = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
ENDPOINT = re.compile(rf"https://({DNS_LABEL}(?:\.{DNS_LABEL})*)(?::([0-9]{{1,5}}))?(?:/v1/events|/)?")
CHANNEL = re.compile(r"[a-z0-9][a-z0-9_-]{0,39}")


def normalize_endpoint(value):
    match = ENDPOINT.fullmatch(value) if len(value) <= 512 else None
    if match:
        host, port_text = match.groups()
        port = int(port_text) if port_text else 443
        if len(host) <= 253 and 1 <= port <= 65535:
            authority = host.lower() if port == 443 else f"{host.lower()}:{port}"
            return f"https://{authority}/v1/events"
    return ""


def get_endpoint():
    value = os.environ.get("AETHER_TELEMETRY_ENDPOINT", "")
    endpoint = normalize_endpoint(value)
    if value and not endpoint:
        print("AETHER_TELEMETRY_ENDPOINT is invalid. This export cannot send telemetry.", file=sys.stderr)
    return endpoint


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("default_channel", choices=("debug", "apple_release"))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    channel = os.environ.get("AETHER_TELEMETRY_CHANNEL", "")
    if not CHANNEL.fullmatch(channel):
        if channel:
            print("AETHER_TELEMETRY_CHANNEL is invalid. Using the default export channel.", file=sys.stderr)
        channel = args.default_channel

    # Recovery mode skips editor plugins. Use the same path and content that
    # the normal export plugin would add. Refuse to clobber a concurrent export.
    path = args.project / "config/telemetry_export.json"
    path.parent.mkdir(exist_ok=True)
    try:
        config = path.open("x", encoding="utf-8")
    except FileExistsError:
        parser.exit(1, f"Telemetry export config already exists at {path}. Check for an active export.\n")
    try:
        with config:
            json.dump({"channel": channel, "endpoint": get_endpoint()}, config, separators=(",", ":"))
        return subprocess.call(args.command)
    finally:
        path.unlink()


if __name__ == "__main__":
    sys.exit(main())
