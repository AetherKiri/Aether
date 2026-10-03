#!/usr/bin/env bash
# Metadata/source-only test for the host-owned Ren'Py launcher scaffold.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scaffold="$repo_root/bridge/renpy_runtime/mobile_launcher"
script="$scaffold/build.sh"
header="$scaffold/include/renpy_mobile_launcher.h"
renpy_build="${RENPY_BUILD_TEST_ROOT:-/tmp/renpy-build-src}"

[[ -x "$script" ]] || { echo "missing launcher scaffold script" >&2; exit 1; }
[[ -f "$header" ]] || { echo "missing launcher lifecycle header" >&2; exit 1; }
bash -n "$script"

for symbol in \
    renpy_mobile_init renpy_mobile_tick renpy_mobile_frame renpy_mobile_input \
    renpy_mobile_pause renpy_mobile_resume renpy_mobile_shutdown; do
    grep -Fq "$symbol" "$header"
done

grep -Fq 'Py_RunMain' "$scaffold/README.md"
grep -Fq 'SDL_main' "$scaffold/README.md"
grep -Fq 'renpy-build' "$scaffold/patches/README.md"

if [[ ! -d "$renpy_build" ]]; then
    echo "Ren'Py build checkout not present; metadata-only scaffold test ok"
    exit 0
fi

output="$($script --check --renpy-build "$renpy_build")"
grep -Fq 'source check ok' <<<"$output"
grep -Fq 'no artifact was built or installed' <<<"$output"

if "$script" --check --renpy-build "$renpy_build" | grep -Fq 'SDL_main'; then
    :
else
    echo "source check did not report the blocking Android launcher" >&2
    exit 1
fi

echo "Ren'Py mobile launcher scaffold/source smoke ok"
