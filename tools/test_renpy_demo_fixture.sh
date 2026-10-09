#!/usr/bin/env bash
# Structural and optional SDK smoke test for the real Ren'Py demo project.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="${AETHERKIRI_RENPY_DEMO_FIXTURE:-$repo_root/demos/aetherkiri-renpy}"
[[ -d "$fixture/game" ]] || { echo "missing Ren'Py demo game directory: $fixture" >&2; exit 1; }
for file in options.rpy script.rpy scene.svg; do
    [[ -s "$fixture/game/$file" ]] || { echo "missing Ren'Py demo asset: game/$file" >&2; exit 1; }
done
for marker in \
    'renpy.input' \
    'renpy.pause' \
    'renpy.quit' \
    'textbutton "Start"' \
    'textbutton "Pause / resume"'; do
    grep -Fq "$marker" "$fixture/game/script.rpy" || {
        echo "Ren'Py demo is missing required interaction: $marker" >&2
        exit 1
    }
done
grep -Fq 'image bg fixture = "scene.svg"' "$fixture/game/script.rpy"
grep -Fq 'config.screen_width' "$fixture/game/options.rpy"

if [[ "${RENPY_DEMO_RUN_SMOKE:-0}" != 1 ]]; then
    echo "Ren'Py demo fixture metadata and interaction checks passed"
    exit 0
fi
AETHERKIRI_RENPY_FIXTURE="$fixture" bash "$repo_root/tools/run_renpy_smoke.sh"
