#!/usr/bin/env python3
"""Reject a successful CTest discovery that silently omitted required suites."""

import argparse
from collections import Counter
import json
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory", type=Path)
    parser.add_argument("--require-executable", action="append", required=True)
    args = parser.parse_args()
    inventory = json.loads(args.inventory.read_text())
    tests = inventory["tests"]
    executables = Counter()
    for test in tests:
        command = test.get("command", [])
        if command:
            executables[Path(command[0]).name] += 1
    missing = []
    print(f"CTest inventory: {len(tests)} tests in {len(executables)} executables")
    for executable in sorted(set(args.require_executable)):
        count = executables[executable]
        print(f"  {executable}: {count}")
        if not count:
            missing.append(executable)
    if missing:
        print("Missing required CTest suites: " + ", ".join(missing), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
