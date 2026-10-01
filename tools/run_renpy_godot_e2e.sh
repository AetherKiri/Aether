#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT_BIN:-}"
renpy_sdk="${RENPY_SDK:-${AETHERKIRI_RENPY_SDK_ROOT:-}}"
fixture_root="${AETHERKIRI_RENPY_FIXTURE:-$repo_root/tests/fixtures/renpy_smoke}"
timeout_seconds="${RENPY_GODOT_E2E_TIMEOUT:-90}"

usage() {
    cat <<'USAGE'
Usage: tools/run_renpy_godot_e2e.sh

Launch the built Aether Godot host, open the source-only Ren'Py fixture,
assert a presented frame, advance the dialogue, and choose the first menu
item through the real runtime input bridge. Set GODOT_BIN to the built Godot
binary and RENPY_SDK (or AETHERKIRI_RENPY_SDK_ROOT) to the official SDK.
USAGE
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi
if [[ $# -ne 0 ]]; then
    printf 'unexpected argument: %s\n' "$1" >&2
    usage >&2
    exit 2
fi
if [[ -z "$godot_bin" || ! -x "$godot_bin" ]]; then
    printf 'GODOT_BIN must point to the built Godot executable.\n' >&2
    exit 1
fi
if [[ -z "$renpy_sdk" || ! -d "$renpy_sdk" ]]; then
    printf "RENPY_SDK or AETHERKIRI_RENPY_SDK_ROOT must point to the official SDK.\n" >&2
    exit 1
fi
if [[ ! -d "$fixture_root/game" ]]; then
    printf "Ren'Py fixture is missing game/: %s\n" "$fixture_root" >&2
    exit 1
fi

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/aetherkiri-renpy-godot-e2e.XXXXXX")"
cleanup() {
    rm -rf "$tmp_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fixture="$tmp_root/fixture"
cp -a "$fixture_root/." "$fixture"
rm -f "$fixture/game/aetherkiri-choice"

config="$tmp_root/config.json"
cat > "$config" <<JSON
{
  "game_path": "$fixture",
  "surface_size": [640, 360],
  "window_size": [640, 360],
  "warmup_frames": 120,
  "measure_frames": 30,
  "capture_startup": false,
  "actions": [
    {"type": "key", "key_code": 13, "unicode": 13, "label": "advance-dialogue", "after_frames": 120},
    {"type": "key", "key_code": 13, "unicode": 13, "label": "open-menu", "after_frames": 120},
    {"type": "click", "x": 320, "y": 140, "label": "choose-continue", "after_frames": 120}
  ]
}
JSON

log="$tmp_root/godot.log"
set +e
SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-dummy}" \
SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-dummy}" \
AETHERKIRI_RENPY_SDK_ROOT="$renpy_sdk" \
AETHERKIRI_CLI_PROBE_SCRIPT="res://scripts/step_render_probe.gd" \
AETHERKIRI_TEST_CONFIG="$config" \
timeout -k 5s "${timeout_seconds}s" \
    "$godot_bin" --headless --path "$repo_root/apps/godot_app" --verbose \
    >"$log" 2>&1
godot_rc=$?
set -e

cat "$log"
if [[ "$godot_rc" -ne 0 ]]; then
    printf 'Godot Ren\x27Py E2E exited with status %s\n' "$godot_rc" >&2
    exit "$godot_rc"
fi

grep -F 'step probe fps=' "$log" >/dev/null || {
    printf 'Godot probe did not report a completed frame probe.\n' >&2
    exit 1
}
grep -F 'AKRF1 RGBA bridge' "$log" >/dev/null || {
    printf 'Godot probe did not use the Ren\x27Py RGBA bridge.\n' >&2
    exit 1
}
grep -F 'step 03 label=choose-continue' "$log" >/dev/null || {
    printf 'Godot probe did not finish the dialogue/choice action sequence.\n' >&2
    exit 1
}

marker="$fixture/game/aetherkiri-choice"
if [[ ! -f "$marker" ]]; then
    printf 'Ren\x27Py fixture did not record a menu choice.\n' >&2
    exit 1
fi
choice="$(<"$marker")"
if [[ "$choice" != "continue" ]]; then
    printf 'Unexpected Ren\x27Py menu choice: %q\n' "$choice" >&2
    exit 1
fi

printf 'Ren\x27Py Godot E2E ok: frame=640x360, renderer=AKRF1 RGBA bridge, choice=%s\n' "$choice"
