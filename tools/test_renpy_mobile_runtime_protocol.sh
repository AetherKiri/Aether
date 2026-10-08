#!/usr/bin/env bash
# Native/provider boundary tests with controlled Python/launcher modules.
# These tests do not build an APK/IPA or prove Ren'Py gameplay.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/aether-renpy-protocol.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cc="${CC:-cc}"
cxx="${CXX:-c++}"
python_config="${PYTHON_CONFIG:-python3-config}"
command -v "$python_config" >/dev/null || { echo 'CPython development headers/python3-config are required' >&2; exit 1; }
read -r -a python_includes <<<"$("$python_config" --includes)"
read -r -a python_libs <<<"$("$python_config" --embed --ldflags)"
includes=(-I"$repo_root/bridge/renpy_runtime/include" -I"$repo_root/bridge/renpy_runtime/mobile_launcher/include" -I"$repo_root/abi/include")
"$cc" -std=c11 -Wall -Wextra -Werror "${python_includes[@]}" "${includes[@]}" \
    -c "$repo_root/bridge/renpy_runtime/mobile_launcher/patches/native/renpy_mobile_lifecycle.c" -o "$work/lifecycle.o"
"$cxx" -std=c++17 -Wall -Wextra -Werror "${python_includes[@]}" "${includes[@]}" \
    "$repo_root/bridge/renpy_runtime/tests/mobile_lifecycle.cpp" "$work/lifecycle.o" "${python_libs[@]}" \
    -o "$work/lifecycle-test"
python_lib_dir="$("$python_config" --prefix)/lib"
LD_LIBRARY_PATH="$python_lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$work/lifecycle-test"
"$cxx" -std=c++17 -Wall -Wextra -Werror -DAETHERKIRI_RENPY_PROTOCOL_TEST -Wl,-export-dynamic "${includes[@]}" \
    "$repo_root/bridge/renpy_runtime/tests/mobile_provider_protocol.cpp" \
    "$repo_root/bridge/renpy_runtime/src/renpy_runtime_mobile_provider.cpp" \
    "$repo_root/bridge/renpy_runtime/mobile_launcher/src/renpy_mobile_loader.cpp" \
    -ldl -pthread -o "$work/provider-test"
"$work/provider-test"
printf '%s\n' 'RenPy native/provider protocol tests passed (not gameplay acceptance)'
